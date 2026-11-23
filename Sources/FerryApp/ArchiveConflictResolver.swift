import FerryCore
import Foundation

// The archive worker waits off the main actor. Cancellation also wakes a pending question.
final class ArchiveConflictResolver: @unchecked Sendable {
  private let condition = NSCondition()
  private var pendingID: String?
  private var decision: DownloadConflictDecision?
  private var stopped = false

  func request(
    _ conflict: MediaArchiveConflict, cancellation: PhotoRepairCancellation,
    publish: @Sendable (MediaArchiveConflict) -> Void
  ) throws -> DownloadConflictDecision {
    condition.lock()
    guard !stopped, !cancellation.isCancelled else {
      condition.unlock()
      throw CancellationError()
    }
    pendingID = conflict.id
    decision = nil
    condition.unlock()
    publish(conflict)
    condition.lock()
    defer {
      pendingID = nil
      decision = nil
      condition.unlock()
    }
    while decision == nil && !stopped && !cancellation.isCancelled {
      _ = condition.wait(until: Date(timeIntervalSinceNow: 0.1))
    }
    guard !stopped, !cancellation.isCancelled, let decision else { throw CancellationError() }
    return decision
  }

  @discardableResult
  func resolve(_ value: DownloadConflictDecision) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    guard !stopped, pendingID == value.id, decision == nil else { return false }
    decision = value
    condition.signal()
    return true
  }
  func cancel() {
    condition.lock()
    stopped = true
    condition.broadcast()
    condition.unlock()
  }
}
