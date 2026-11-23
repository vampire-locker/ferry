import Darwin
import Foundation
import OSLog
import Security

/// Implementations must be thread-safe: the download scheduler creates streams
/// and cancels requests off MainActor. Creating a stream must not block on I/O.
public protocol EngineRunning: AnyObject {
  var usbCaptureSupported: Bool { get }
  var usbCaptureRequiresAdministrator: Bool { get }
  var sessionIdentifier: UUID? { get }
  func events(for request: EngineRequest, demo: Bool) -> AsyncThrowingStream<EngineEvent, Error>
  func cancel()
  func disconnect()
  func shutdown()
}

extension EngineRunning {
  public var usbCaptureSupported: Bool { false }
  public var usbCaptureRequiresAdministrator: Bool { false }
  public var sessionIdentifier: UUID? { nil }
  public func disconnect() {}
}

/// Owns one serial helper for a connection. No USB code runs in the UI process.
public final class EngineRunner: EngineRunning, @unchecked Sendable {
  public static let usbCapturePreferenceKey = "allowUSBCapture"
  private static let diagnostics = Logger(subsystem: "local.ferry", category: "engine")
  private final class Session: @unchecked Sendable {
    let id = UUID()
    let child = Process()
    let input = Pipe()
    let output = Pipe()
    let demo: Bool
    let capture: Bool
    let usbTarget: USBDeviceTarget?
    var framer = EventFramer()
    var pending: [EngineEvent] = []
    var stopping = false  // Protected by EngineRunner.lock.
    init(demo: Bool, capture: Bool, usbTarget: USBDeviceTarget?) {
      self.demo = demo
      self.capture = capture
      self.usbTarget = usbTarget
    }

    func nextEvent() throws -> EngineEvent? {
      var buffer = [UInt8](repeating: 0, count: 64 * 1024)
      while pending.isEmpty {
        let count = buffer.withUnsafeMutableBytes {
          Darwin.read(output.fileHandleForReading.fileDescriptor, $0.baseAddress, $0.count)
        }
        if count == 0 {
          try framer.finish()
          return nil
        }
        if count < 0 {
          if errno == EINTR { continue }
          throw EngineFailure(L10n.text("读取传输引擎失败：\(String(cString: strerror(errno)))"))
        }
        pending = try framer.append(Data(buffer.prefix(count)))
      }
      return pending.removeFirst()
    }

    func requestStop() {
      try? input.fileHandleForWriting.close()
      if child.isRunning { child.terminate() }
    }
  }

  private let lock = NSLock()
  private let queue = DispatchQueue(label: "local.ferry.engine.requests", qos: .userInitiated)
  private var session: Session?
  private var epoch = 0
  private var stopped = false
  public var sessionIdentifier: UUID? {
    lock.lock()
    defer { lock.unlock() }
    return session.flatMap { $0.stopping ? nil : $0.id }
  }
  public let executable: URL
  public let usbCaptureSupported: Bool
  public let usbCaptureRequiresAdministrator: Bool

  public init(executable: URL) {
    self.executable = executable
    let mode = Self.captureMode(executable)
    usbCaptureSupported = mode != .unavailable
    usbCaptureRequiresAdministrator = mode == .administrator
  }

  // Inspect metadata only; never launch the helper or initialize USB here.
  // An entitlement in an ad-hoc signature is not permission to use it.
  private enum CaptureMode { case unavailable, system, administrator }
  private static func captureMode(_ executable: URL) -> CaptureMode {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess,
      let code,
      SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil)
        == errSecSuccess
    else { return .unavailable }
    var info: CFDictionary?
    guard
      SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        == errSecSuccess,
      let values = info as? [String: Any],
      let flags = values[kSecCodeInfoFlags as String] as? NSNumber
    else { return .unavailable }
    let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
    let restricted = entitlements["com.apple.vm.device-access"] as? Bool == true
    let adhoc = SecCodeSignatureFlags(rawValue: flags.uint32Value).contains(.adhoc)
    if restricted { return adhoc ? .unavailable : .system }
    return .administrator
  }

  public func events(for request: EngineRequest, demo: Bool) -> AsyncThrowingStream<
    EngineEvent, Error
  > {
    lock.lock()
    let ticket = epoch
    lock.unlock()
    return AsyncThrowingStream { continuation in
      queue.async { [self] in
        var current: Session?
        do {
          lock.lock()
          let invalid = stopped || ticket != epoch
          lock.unlock()
          if invalid { throw CancellationError() }
          let capture =
            !demo
            && usbCaptureSupported
            && (UserDefaults.standard.object(forKey: Self.usbCapturePreferenceKey) as? Bool ?? true)
          lock.lock()
          let previous = session
          lock.unlock()
          if let previous {
            lock.lock()
            let closing = previous.stopping
            lock.unlock()
            if request.operation == "connect" || previous.demo != demo
              || previous.capture != capture || previous.usbTarget != request.usbTarget
              || closing || !previous.child.isRunning
            {
              retire(previous)
            }
          }
          lock.lock()
          current = session
          lock.unlock()
          if current == nil {
            guard !["resume", "restart", "recover"].contains(request.downloadAction ?? "") else {
              throw EngineFailure(L10n.text("恢复信息已失效，请在本次手机连接内继续，或重新选择未完成文件。"))
            }
            current = try launch(
              demo: demo, capture: capture, usbTarget: request.usbTarget, ticket: ticket)
          }
          guard let active = current else { throw CancellationError() }
          lock.lock()
          let cancelled = stopped || ticket != epoch || active.stopping
          lock.unlock()
          if cancelled { throw CancellationError() }
          try active.input.fileHandleForWriting.write(
            contentsOf: JSONEncoder().encode(request) + Data([10]))
          var terminal: String?
          var reusable = false
          while let event = try active.nextEvent() {
            if event.type == "diagnostic" {
              if let message = event.message {
                if message.hasPrefix("directory ") {
                  // These stage timings contain counts/property codes, not filenames.
                  Self.diagnostics.info("\(message, privacy: .public)")
                } else if message.hasPrefix("connection ") {
                  // Fixed phase/result tags and durations only; no device
                  // identity, file names, paths or user-supplied error text.
                  Self.diagnostics.notice("\(message, privacy: .public)")
                } else {
                  Self.diagnostics.error("\(message, privacy: .private)")
                }
              }
              continue
            }
            if event.type == "ready" {
              guard let terminal, terminal != "error" else {
                throw EngineFailure(L10n.text("引擎响应意外中断，请重新连接手机"))
              }
              reusable = true
              break
            }
            if ["connected", "listed", "sized", "yielded", "completed", "error"].contains(
              event.type)
            {
              terminal = event.type
            }
            continuation.yield(event)
          }
          if !reusable {
            active.child.waitUntilExit()
            let code = active.child.terminationStatus
            let killed = active.child.terminationReason == .uncaughtSignal && code == SIGKILL
            retire(active)
            if terminal == nil || (terminal != "error" && code != 0) {
              if killed {
                throw EngineFailure(L10n.text("传输引擎被 macOS 强制终止（SIGKILL），请检查应用签名和系统日志。"))
              }
              throw EngineFailure(L10n.text("传输引擎意外退出（\(code)），请重新连接手机。"))
            }
          }
          continuation.finish()
        } catch {
          if let current { retire(current) }
          continuation.finish(throwing: error)
        }
      }
    }
  }

  private func launch(demo: Bool, capture: Bool, usbTarget: USBDeviceTarget?, ticket: Int) throws
    -> Session
  {
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw EngineFailure(L10n.text("找不到传输引擎，请运行 scripts/build-app.sh 重新构建应用。"))
    }
    let fresh = Session(demo: demo, capture: capture, usbTarget: usbTarget)
    fresh.child.executableURL = executable
    fresh.child.arguments =
      ["--serve"] + (demo ? ["--demo"] : [])
      + (capture ? [usbCaptureRequiresAdministrator ? "--authorize" : "--usb-capture"] : [])
    fresh.child.environment = ProcessInfo.processInfo.environment.merging([
      "FERRY_LANGUAGE": L10n.languageIdentifier
    ]) { _, language in language }
    fresh.child.standardInput = fresh.input
    fresh.child.standardOutput = fresh.output
    fresh.child.standardError = FileHandle.standardError
    lock.lock()
    defer { lock.unlock() }
    guard !stopped, ticket == epoch else { throw CancellationError() }
    try fresh.child.run()
    session = fresh
    return fresh
  }

  // Queue-only teardown waits for driver restoration before starting a new
  // helper. Its cancellation watchdog bounds stalled native cleanup.
  private func retire(_ old: Session) {
    lock.lock()
    old.stopping = true
    if session === old { session = nil }
    lock.unlock()
    old.requestStop()
    old.child.waitUntilExit()
    try? old.output.fileHandleForReading.close()
  }

  public func cancel() { disconnect() }

  public func disconnect() {
    lock.lock()
    epoch += 1
    let old = session
    old?.stopping = true
    lock.unlock()
    old?.requestStop()
    if let old { queue.async { [self] in retire(old) } }
  }

  public func shutdown() {
    lock.lock()
    stopped = true
    lock.unlock()
    disconnect()
  }

  deinit { session?.requestStop() }
}
