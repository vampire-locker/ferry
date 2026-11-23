import Foundation

/// Uses monotonic uptime supplied by the caller, so system clock changes do
/// not alter elapsed time. Preparation counts toward elapsed time, but is
/// excluded from the transfer-phase sampling used to estimate remaining time.
public struct TransferTiming: Sendable, Equatable {
  private var startedAt: TimeInterval?
  private var endedAt: TimeInterval?
  private var samplingStartedAt: TimeInterval?
  private var initialBytes: Int64 = 0
  private var transferred: Int64 = 0
  private var total: Int64 = 0

  public init() {}

  public mutating func start(at uptime: TimeInterval) {
    self = Self()
    startedAt = uptime
  }

  public mutating func recordProgress(bytes: Int64, totalBytes: Int64, at uptime: TimeInterval) {
    guard startedAt != nil, endedAt == nil, totalBytes > 0,
      bytes >= 0, bytes <= totalBytes
    else { return }
    if samplingStartedAt == nil || bytes < transferred || totalBytes != total {
      samplingStartedAt = uptime
      initialBytes = bytes
    }
    transferred = bytes
    total = totalBytes
  }

  public mutating func finish(at uptime: TimeInterval) {
    guard startedAt != nil, endedAt == nil else { return }
    endedAt = uptime
  }

  public func elapsed(at uptime: TimeInterval) -> TimeInterval? {
    guard let startedAt else { return nil }
    return max(0, (endedAt ?? uptime) - startedAt)
  }

  public var hasTransferredAllBytes: Bool { total > 0 && transferred >= total }

  public func estimatedRemaining(at uptime: TimeInterval) -> TimeInterval? {
    guard endedAt == nil, let samplingStartedAt,
      uptime - samplingStartedAt >= 1, transferred > initialBytes,
      transferred < total
    else { return nil }
    // Average over the transfer phase keeps file boundaries from resetting
    // the estimate and includes stalls even when no new event arrives.
    let rate = Double(transferred - initialBytes) / (uptime - samplingStartedAt)
    let remaining = Double(total - transferred) / rate
    return remaining.isFinite ? max(1, ceil(remaining)) : nil
  }
}
