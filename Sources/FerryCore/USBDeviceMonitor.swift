import CryptoKit
import Foundation
import IOKit

public protocol USBMonitoring: AnyObject {
  var onChange: ((Set<UInt64>) -> Void)? { get set }
  var devices: Set<UInt64> { get }
  var choices: [USBDeviceChoice] { get }
  func start() throws
  func stop()
}

extension USBMonitoring {
  public var choices: [USBDeviceChoice] {
    devices.sorted().map { USBDeviceChoice(id: $0, name: L10n.text("Android 手机"), target: nil) }
  }
}

/// Watches registry metadata only: never opens a USB interface or MTP session.
/// start, stop and callbacks run on the main run loop.
public final class USBDeviceMonitor: USBMonitoring {
  public var onChange: ((Set<UInt64>) -> Void)?
  public private(set) var devices: Set<UInt64> = []
  public private(set) var choices: [USBDeviceChoice] = []
  private var notificationPort: IONotificationPortRef?
  private var runLoopSource: CFRunLoopSource?
  private var arrivalIterator: io_iterator_t = 0
  private var removalIterator: io_iterator_t = 0
  private var initializing = false
  private var interfaceTokens: [UInt64: UInt64] = [:]
  private var interfaceChoices: [UInt64: USBDeviceChoice] = [:]
  private var detectedChoices: [USBDeviceChoice] = []
  private var removalTask: Task<Void, Never>?

  public init() {}

  public func start() throws {
    precondition(Thread.isMainThread)
    guard notificationPort == nil else { return }
    guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
      throw EngineFailure(L10n.text("USB 自动检测暂不可用，请使用手动连接。"))
    }
    notificationPort = port
    guard let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() else {
      stop()
      throw EngineFailure(L10n.text("无法监听 USB 设备，请使用手动连接。"))
    }
    runLoopSource = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    initializing = true
    let context = Unmanaged.passUnretained(self).toOpaque()
    let arrived: IOServiceMatchingCallback = { context, iterator in
      guard let context else { return }
      Unmanaged<USBDeviceMonitor>.fromOpaque(context).takeUnretainedValue().consume(
        iterator, arriving: true)
    }
    let removed: IOServiceMatchingCallback = { context, iterator in
      guard let context else { return }
      Unmanaged<USBDeviceMonitor>.fromOpaque(context).takeUnretainedValue().consume(
        iterator, arriving: false)
    }
    let arrivalResult = IOServiceAddMatchingNotification(
      port, kIOFirstMatchNotification, IOServiceMatching("IOUSBHostInterface"),
      arrived, context, &arrivalIterator)
    guard arrivalResult == KERN_SUCCESS else {
      stop()
      throw EngineFailure(L10n.text("无法订阅 USB 接入通知，请使用手动连接。"))
    }
    // Draining the initial iterator both enumerates already-attached devices and arms notifications.
    consume(arrivalIterator, arriving: true)
    let removalResult = IOServiceAddMatchingNotification(
      port, kIOTerminatedNotification, IOServiceMatching("IOUSBHostInterface"),
      removed, context, &removalIterator)
    guard removalResult == KERN_SUCCESS else {
      stop()
      throw EngineFailure(L10n.text("无法订阅 USB 移除通知，请使用手动连接。"))
    }
    consume(removalIterator, arriving: false)
    initializing = false
    onChange?(devices)
  }

  public func stop() {
    precondition(Thread.isMainThread)
    removalTask?.cancel()
    removalTask = nil
    if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
    if arrivalIterator != 0 {
      IOObjectRelease(arrivalIterator)
      arrivalIterator = 0
    }
    if removalIterator != 0 {
      IOObjectRelease(removalIterator)
      removalIterator = 0
    }
    if let notificationPort { IONotificationPortDestroy(notificationPort) }
    notificationPort = nil
    runLoopSource = nil
    initializing = false
    devices = []
    choices = []
    interfaceTokens = [:]
    interfaceChoices = [:]
    detectedChoices = []
  }

  private func consume(_ iterator: io_iterator_t, arriving: Bool) {
    precondition(Thread.isMainThread)
    while true {
      let service = IOIteratorNext(iterator)
      if service == 0 { break }
      defer { IOObjectRelease(service) }
      var id: UInt64 = 0
      guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS else { continue }
      if arriving {
        if Self.isCandidate(service) {
          let choice = Self.deviceChoice(service, fallback: id)
          interfaceTokens[id] = choice.id
          interfaceChoices[id] = choice
        }
      } else {
        interfaceTokens[id] = nil
        interfaceChoices[id] = nil
      }
    }
    let next = Set(interfaceTokens.values)
    let byID: [UInt64: USBDeviceChoice] = Dictionary(
      interfaceChoices.values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
    )
    let nextChoices = byID.values.sorted(by: Self.choicePrecedes)
    if initializing {
      devices = next
      choices = nextChoices
      detectedChoices = nextChoices
      return
    }
    updateChoices(nextChoices)
  }

  // Delay each missing phone, including when other phones remain attached:
  // macOS capture can temporarily remove just the selected USB interface.
  func updateChoices(_ next: [USBDeviceChoice]) {
    detectedChoices = next
    removalTask?.cancel()
    removalTask = nil
    let nextIDs = Set(next.map(\.id))
    if !devices.subtracting(nextIDs).isEmpty {
      publishChoices(next + choices.filter { !nextIDs.contains($0.id) })
      removalTask = Task { @MainActor [weak self] in
        do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
        guard let self else { return }
        self.publishChoices(self.detectedChoices)
        self.removalTask = nil
      }
    } else {
      publishChoices(next)
    }
  }

  private func publishChoices(_ next: [USBDeviceChoice]) {
    let sorted = next.sorted(by: Self.choicePrecedes)
    guard choices != sorted else { return }
    choices = sorted
    devices = Set(sorted.map(\.id))
    onChange?(devices)
  }

  private static func choicePrecedes(_ first: USBDeviceChoice, _ second: USBDeviceChoice) -> Bool {
    if first.label == second.label { return first.id < second.id }
    return first.label < second.label
  }

  private static func deviceChoice(_ service: io_service_t, fallback: UInt64) -> USBDeviceChoice {
    func property(_ key: String) -> Any? {
      IORegistryEntrySearchCFProperty(
        service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
        IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
    }
    guard let location = property("locationID") as? NSNumber,
      let vendor = property("idVendor") as? NSNumber,
      let product = property("idProduct") as? NSNumber
    else { return USBDeviceChoice(id: fallback, name: L10n.text("Android 手机"), target: nil) }
    let serial = property("USB Serial Number") as? String ?? ""
    let name = property("USB Product Name") as? String ?? L10n.text("Android 手机")
    let identity =
      "\(location.uint64Value)\u{0}\(vendor.uint64Value)\u{0}\(product.uint64Value)\u{0}\(serial)"
    let token = SHA256.hash(data: Data(identity.utf8)).prefix(8).reduce(UInt64(0)) {
      ($0 << 8) | UInt64($1)
    }
    return USBDeviceChoice(
      id: token, name: name,
      target: USBDeviceTarget(
        locationID: location.uint32Value, vendorID: vendor.uint16Value,
        productID: product.uint16Value, serialNumber: serial))
  }

  private static func isCandidate(_ service: io_service_t) -> Bool {
    func property(_ key: String) -> Any? {
      IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue()
    }
    var registryName = [CChar](repeating: 0, count: 128)
    let nameResult = registryName.withUnsafeMutableBufferPointer {
      IORegistryEntryGetName(service, $0.baseAddress!)
    }
    let name =
      property("USB Interface Name") as? String
      ?? (nameResult == KERN_SUCCESS ? String(cString: registryName) : "")
    let descriptor = USBInterfaceDescriptor(
      classCode: (property("bInterfaceClass") as? NSNumber)?.intValue ?? -1,
      subclassCode: (property("bInterfaceSubClass") as? NSNumber)?.intValue ?? -1,
      name: name)
    return descriptor.isMTPCandidate
  }
}
