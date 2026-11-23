import Foundation

/// Pure policy; no USB access. Attempts belong to a single physical attachment.
public struct AutoConnectPolicy {
  public private(set) var devices: Set<UInt64> = []
  private var attempts: [UInt64: Int] = [:]
  public let maximumAttempts: Int

  public init(maximumAttempts: Int = 3) {
    self.maximumAttempts = max(1, maximumAttempts)
  }

  public mutating func update(devices: Set<UInt64>) {
    self.devices = devices
    attempts = attempts.filter { devices.contains($0.key) }
  }

  public func candidate(isBusy: Bool, hasConnection: Bool, isDemo: Bool) -> UInt64? {
    guard !isBusy, !hasConnection, !isDemo, devices.count == 1,
      let id = devices.first, attemptCount(for: id) < maximumAttempts
    else { return nil }
    return id
  }

  @discardableResult
  public mutating func claim(_ id: UInt64) -> Bool {
    guard devices.count == 1, devices.contains(id), attemptCount(for: id) < maximumAttempts else {
      return false
    }
    attempts[id, default: 0] += 1
    return true
  }

  public func attemptCount(for id: UInt64) -> Int { attempts[id, default: 0] }

  /// Manual attempts and user cancellation suppress background retries until a new attachment.
  public mutating func suppressCurrentAttachment() {
    for id in devices { attempts[id] = maximumAttempts }
  }
}

public struct USBInterfaceDescriptor {
  public let classCode: Int
  public let subclassCode: Int
  public let name: String

  public init(classCode: Int, subclassCode: Int, name: String) {
    self.classCode = classCode
    self.subclassCode = subclassCode
    self.name = name
  }

  public var isMTPCandidate: Bool {
    // Standard still-image/PTP interfaces, plus explicitly named vendor MTP interfaces.
    (classCode == 6 && subclassCode == 1)
      || (classCode == 255 && name.uppercased().hasPrefix("MTP"))
  }
}
