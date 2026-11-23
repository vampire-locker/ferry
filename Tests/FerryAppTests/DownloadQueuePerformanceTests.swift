import AppKit
import Combine
import Darwin
import FerryCore
import Foundation
import XCTest

@testable import FerryApp

/// Continuations and counters are shared with MainActor tests, but the fake
/// performs all simulated file work on its own serial queue. It never hops to
/// MainActor to manufacture a response or to advance the next file.
private final class ThroughputEngine: EngineRunning, @unchecked Sendable {
  typealias Continuation = AsyncThrowingStream<EngineEvent, Error>.Continuation

  private let lock = NSLock()
  private let responses = DispatchQueue(label: "ferry.test.download.responses")
  private let files: Int
  private let progressPerFile: Int
  private let fileDelay: TimeInterval
  private let heldFile: Int?
  private var nextRequests = 0
  private var finishedFiles = 0
  private var mainThreadRequests = 0
  private var active = 0
  private var maximumActive = 0
  private var held: (EngineRequest, Int, Continuation)?
  private var starts: [TimeInterval] = []
  private var finishes: [TimeInterval] = []

  init(files: Int, progressPerFile: Int = 1, fileDelay: TimeInterval = 0.003, heldFile: Int? = nil)
  {
    self.files = files
    self.progressPerFile = progressPerFile
    self.fileDelay = fileDelay
    self.heldFile = heldFile
  }

  private func read<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  var nextCount: Int { read { nextRequests } }
  var completedFiles: Int { read { finishedFiles } }
  var callsOnMainThread: Int { read { mainThreadRequests } }
  var maximumConcurrentRequests: Int { read { maximumActive } }
  var hasHeldFile: Bool { read { held != nil } }
  var handoffIntervals: [TimeInterval] {
    read {
      guard starts.count > 1 else { return [] }
      return (1..<min(starts.count, finishes.count + 1)).map { starts[$0] - finishes[$0 - 1] }
    }
  }

  private func event(_ object: [String: Any]) -> EngineEvent {
    try! JSONDecoder().decode(
      EngineEvent.self,
      from: JSONSerialization.data(withJSONObject: object))
  }

  func events(for request: EngineRequest, demo: Bool) -> AsyncThrowingStream<EngineEvent, Error> {
    let number: Int = read {
      if Thread.isMainThread { mainThreadRequests += 1 }
      active += 1
      maximumActive = max(maximumActive, active)
      if request.downloadAction == "next" {
        nextRequests += 1
        starts.append(ProcessInfo.processInfo.systemUptime)
        return nextRequests
      }
      return 0
    }
    return AsyncThrowingStream { continuation in
      if request.downloadAction == "next", number == heldFile {
        read { held = (request, number, continuation) }
      } else {
        responses.asyncAfter(deadline: .now() + (number == 0 ? 0 : fileDelay)) { [self] in
          deliver(request, number: number, to: continuation)
        }
      }
    }
  }

  private func deliver(_ request: EngineRequest, number: Int, to continuation: Continuation) {
    switch request.downloadAction {
    case "begin":
      continuation.yield(
        event([
          "type": "progress", "bytes": 0,
          "totalBytes": files * 1000, "completed": 0, "total": files,
        ]))
      continuation.yield(event(["type": "yielded", "state": "running"]))
    case "next":
      for sample in 1...progressPerFile {
        let bytes = (number - 1) * 1000 + (sample * 1000 / progressPerFile)
        continuation.yield(
          event([
            "type": "progress", "bytes": bytes,
            "totalBytes": files * 1000,
            "completed": sample == progressPerFile ? number : number - 1,
            "total": files, "currentFile": "file-\(number).jpg",
          ]))
      }
      read {
        finishedFiles += 1
        finishes.append(ProcessInfo.processInfo.systemUptime)
      }
      continuation.yield(
        event([
          "type": number == files ? "completed" : "yielded",
          "state": number == files ? "completed" : "running",
        ]))
    case "cancel": continuation.yield(event(["type": "completed", "state": "cancelled"]))
    default:
      continuation.yield(
        event(["type": "error", "state": "failed", "message": "Unexpected fake request"]))
    }
    read { active -= 1 }
    continuation.finish()
  }

  func finishHeldFile() {
    let pending = read { () -> (EngineRequest, Int, Continuation)? in
      defer { held = nil }
      return held
    }
    guard let (request, number, continuation) = pending else { return }
    responses.async { [self] in deliver(request, number: number, to: continuation) }
  }

  func cancel() {
    let pending = read { () -> Continuation? in
      guard let (_, _, continuation) = held else { return nil }
      held = nil
      active -= 1
      return continuation
    }
    pending?.yield(event(["type": "error", "state": "cancelled"]))
    pending?.finish()
  }

  func shutdown() { cancel() }
}

private final class PerformanceUSBMonitor: USBMonitoring {
  var onChange: ((Set<UInt64>) -> Void)?
  var devices = Set<UInt64>()
  func start() throws { XCTFail("Performance tests must not enumerate USB") }
  func stop() {}
}

@MainActor
final class DownloadQueuePerformanceTests: XCTestCase {
  func testSailingLayersDuringSyntheticTransfer() async throws {
    // A controlled offscreen native-layer comparison, without activating an
    // app or touching USB. It measures this process, not WindowServer/GPU energy.
    _ = NSApplication.shared
    var measurements: [[String: Double]] = []
    for animated in [false, true, true, false] {
      let engine = ThroughputEngine(files: 200, fileDelay: 0.01)
      let queue = DownloadQueueController(
        runner: engine, uptime: { ProcessInfo.processInfo.systemUptime })
      let layers = SailingProgressLayers()
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 60), styleMask: [.titled],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      let view = NSView(frame: window.contentView!.bounds)
      view.wantsLayer = true
      view.layer?.addSublayer(layers.root)
      window.contentView = view
      let bounds = CGRect(x: 0, y: 0, width: 600, height: 34)
      layers.layout(in: bounds, progress: 0, smooth: false)
      layers.setFloating(animated)
      var publications = 0
      let subscription = queue.$tasks.sink { tasks in
        guard let task = tasks.last else { return }
        publications += 1
        layers.layout(
          in: bounds, progress: Display.progress(bytes: task.transferred, total: task.totalBytes),
          smooth: animated)
      }
      defer {
        subscription.cancel()
        layers.setFloating(false)
        queue.shutdown()
        engine.shutdown()
        window.contentView = nil
        window.close()
      }
      let cpu = processCPUTime()
      let start = ProcessInfo.processInfo.systemUptime
      XCTAssertTrue(queue.enqueue(title: "sailing comparison", request: request(), demo: true))
      try await waitUntil { queue.tasks.last?.state == .completed }
      let intervals = engine.handoffIntervals.sorted()
      let result: [String: Double] = [
        "animated": animated ? 1 : 0,
        "cpu_seconds": processCPUTime() - cpu,
        "wall_seconds": ProcessInfo.processInfo.systemUptime - start,
        "handoff_p95_ms": intervals[Int(Double(intervals.count - 1) * 0.95)] * 1000,
        "publications": Double(publications),
      ]
      measurements.append(result)
      XCTAssertEqual(engine.completedFiles, 200)
      XCTAssertEqual(engine.maximumConcurrentRequests, 1)
      XCTAssertEqual(engine.callsOnMainThread, 0)
      XCTAssertLessThan(publications, 20)
      print("SAILING_OFFSCREEN \(result)")
    }
    if let output = ProcessInfo.processInfo.environment["FERRY_SAILING_PERF_OUTPUT"] {
      try JSONSerialization.data(withJSONObject: measurements).write(
        to: URL(fileURLWithPath: output))
    }
  }

  private func processCPUTime() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
      + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
  }

  private func waitUntil(timeout: TimeInterval = 6, _ predicate: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while !predicate() {
      guard ProcessInfo.processInfo.systemUptime < deadline else {
        XCTFail("Synthetic download did not reach expected state")
        throw EngineFailure("test timeout")
      }
      try await Task.sleep(nanoseconds: 2_000_000)
    }
  }

  // Keep the intentional main-thread stall in a synchronous method; the fake
  // response queue and the production download executor remain runnable.
  private func blockMainThread(for seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

  private func request() -> EngineRequest {
    EngineRequest(
      operation: "download", deviceKey: "performance-phone", storageID: 1,
      objectIDs: [1], destination: "/unused-synthetic-output")
  }

  func testFileLoopContinuesWhenMainThreadIsBlocked() async throws {
    let engine = ThroughputEngine(files: 100)
    let queue = DownloadQueueController(
      runner: engine, uptime: { ProcessInfo.processInfo.systemUptime })
    defer {
      queue.shutdown()
      engine.shutdown()
    }
    var preparations = 0
    queue.beforeRequests = { preparations += 1 }
    XCTAssertTrue(queue.enqueue(title: "100 synthetic files", request: request(), demo: true))
    try await waitUntil { engine.nextCount > 0 }
    let before = engine.nextCount
    XCTAssertTrue(Thread.isMainThread)
    blockMainThread(for: 0.3)
    let after = engine.nextCount
    XCTAssertGreaterThanOrEqual(
      after - before, 5,
      "Complete-file handoff must not wait for MainActor to run")
    try await waitUntil { queue.tasks.first?.state == .completed }
    XCTAssertEqual(engine.completedFiles, 100)
    XCTAssertEqual(
      engine.callsOnMainThread, 0, "The file loop must invoke the runner off MainActor")
    XCTAssertEqual(engine.maximumConcurrentRequests, 1)
    XCTAssertEqual(preparations, 1, "Preparing media/session must not run once per file")
    let intervals = engine.handoffIntervals.sorted()
    XCTAssertEqual(intervals.count, 99)
    if !intervals.isEmpty {
      let p50 = intervals[intervals.count / 2] * 1000
      let p95 = intervals[min(intervals.count - 1, Int(Double(intervals.count) * 0.95))] * 1000
      print(
        String(
          format:
            "SIMULATED 100-file handoff: p50=%.3f ms p95=%.3f ms; USB/device throughput was not measured",
          p50, p95))
    }
  }

  func testProgressFloodDoesNotInvalidateAppModelForEveryEvent() async throws {
    let engine = ThroughputEngine(files: 20, progressPerFile: 200, fileDelay: 0.001)
    let domain = "ferry-download-performance-\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: domain)!
    defer { preferences.removePersistentDomain(forName: domain) }
    let model = AppModel(
      runner: engine, usbMonitor: PerformanceUSBMonitor(), preferences: preferences,
      destinationIsAvailable: { _ in true })
    defer {
      model.shutdown()
      engine.shutdown()
    }
    model.demo = true
    model.storageID = 1
    model.entries = try JSONDecoder().decode(
      [RemoteEntry].self,
      from: Data(
        """
        [{"id":1,"storageID":1,"name":"Photos","isDirectory":true,"size":0,"modified":0}]
        """.utf8))
    model.selection = [1]
    var invalidations = 0
    var snapshots = 0
    let appChanges = model.objectWillChange.sink {
      XCTAssertTrue(Thread.isMainThread, "Browser publication belongs to MainActor")
      invalidations += 1
    }
    let queueChanges = model.downloadQueue.$tasks.sink { _ in
      XCTAssertTrue(Thread.isMainThread, "Task snapshot publication belongs to MainActor")
      snapshots += 1
    }
    defer {
      appChanges.cancel()
      queueChanges.cancel()
    }
    let started = ProcessInfo.processInfo.systemUptime
    model.download()
    try await waitUntil { model.downloadQueue.tasks.first?.state == .completed }
    let elapsed = ProcessInfo.processInfo.systemUptime - started
    XCTAssertEqual(model.transferred, 20_000)
    XCTAssertLessThanOrEqual(
      invalidations, 40,
      "4000 progress events must not invalidate the browser once per event")
    XCTAssertLessThanOrEqual(
      snapshots, Int(ceil(elapsed * 4)) + 10,
      "Progress snapshots should be coalesced to at most four per second, plus prompt command/terminal updates"
    )
    XCTAssertEqual(engine.maximumConcurrentRequests, 1)
    print(
      "SIMULATED progress flood: 4000 events, \(snapshots) task snapshots, \(invalidations) browser invalidations"
    )
  }

  func testForegroundReservationStopsAtCurrentCompleteFileBoundary() async throws {
    let engine = ThroughputEngine(files: 3, heldFile: 1)
    let queue = DownloadQueueController(
      runner: engine, uptime: { ProcessInfo.processInfo.systemUptime })
    defer {
      queue.shutdown()
      engine.shutdown()
    }
    var preparations = 0
    queue.beforeRequests = { preparations += 1 }
    XCTAssertTrue(queue.enqueue(title: "Reserved queue", request: request(), demo: true))
    try await waitUntil { engine.hasHeldFile }
    let reservation = queue.reserveForeground()
    engine.finishHeldFile()
    await queue.waitUntilIdle()
    blockMainThread(for: 0.05)
    XCTAssertEqual(engine.completedFiles, 1)
    XCTAssertEqual(engine.nextCount, 1, "A reserved browser must run before the second file")
    queue.releaseForeground(reservation, connectionUsable: true)
    try await waitUntil { queue.tasks.first?.state == .completed }
    XCTAssertEqual(engine.completedFiles, 3)
    XCTAssertEqual(engine.maximumConcurrentRequests, 1)
    XCTAssertEqual(preparations, 2, "Prepare only at session start and after foreground work")
  }
}
