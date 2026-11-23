import Combine
import FerryCore
import Foundation

enum DownloadTaskState: String, Sendable {
  case queued, running, waiting, cancelling, completed, cancelled, failed, paused, interrupted
  var isTerminal: Bool {
    self == .completed || self == .cancelled || self == .failed || self == .interrupted
  }
}

struct DownloadTask: Identifiable, Sendable {
  let id: UUID
  let title: String
  var filterSummary = ""
  var state: DownloadTaskState = .queued
  var completed = 0
  var total = 0
  var transferred: Int64 = 0
  var totalBytes: Int64 = 0
  var currentFile = ""
  var skipped = 0
  var reusedBytes: Int64 = 0
  var resumeToken: String?
  var resumeAvailable = false
  var continuing = false
  var sessionID: UUID?
  var recoveryPath: String?
  var started = false
  var hasDurableRecovery: Bool {
    request.durableRecovery == true
      && (recoveryPath != nil
        || !started && !(request.recoveryIdentity ?? "").isEmpty && request.sourceStorage != nil)
  }
  var conflict: DownloadConflict?
  var decision: DownloadConflictDecision?
  var output: URL?
  var reportURL: URL?
  var error: String?
  var timing = TransferTiming()
  var request: EngineRequest
  let demo: Bool
}

/// Main-actor presentation only. File handoff never awaits a UI publication.
@MainActor
final class DownloadQueueController: ObservableObject {
  @Published private(set) var tasks: [DownloadTask] = []
  @Published private(set) var recoveryError: String?
  let presentation = DownloadQueuePresentation()
  let conflicts = DownloadConflictState()
  var onChange: (() -> Void)?
  var beforeRequests: (() async -> Void)?
  var canResume: ((EngineRequest, Bool) -> Bool)?
  var recoveryRequest: ((EngineRequest, Bool) -> EngineRequest?)?
  private let driver: DownloadQueueDriver
  private let delivery = DownloadSnapshotDelivery()
  private let uptime: () -> TimeInterval
  private let destinationIsAvailable: (URL) -> Bool
  private var revision: UInt64 = 0
  private var activeID: UUID?

  init(
    runner: any EngineRunning, uptime: @escaping () -> TimeInterval,
    destinationIsAvailable: @escaping (URL) -> Bool = DownloadDestination.isAvailable,
    storeURL: URL? = nil
  ) {
    self.uptime = uptime
    self.destinationIsAvailable = destinationIsAvailable
    driver = DownloadQueueDriver(
      runner: runner, uptime: uptime, store: storeURL.map { DownloadTaskStore(url: $0) })
    delivery.receive = { [weak self] in self?.apply($0) }
    driver.configure(
      prepare: { [weak self] in await self?.prepareSession() },
      publish: { [delivery] snapshot in delivery.offer(snapshot) })
    apply(driver.snapshot())
  }

  var hasPendingTasks: Bool { tasks.contains { !$0.state.isTerminal } }
  var pendingTaskCount: Int { tasks.filter { !$0.state.isTerminal }.count }
  var currentPendingTaskCount: Int { driver.snapshot().tasks.filter { !$0.state.isTerminal }.count }
  var isTransferring: Bool { tasks.contains { $0.state == .running || $0.state == .cancelling } }
  var hasScheduledWork: Bool {
    tasks.contains { [.queued, .running, .waiting, .cancelling].contains($0.state) }
  }
  var waitingTask: DownloadTask? { tasks.first { $0.state == .waiting && $0.conflict != nil } }
  var focusedTask: DownloadTask? { tasks.first { $0.id == activeID } ?? tasks.last }
  var activeTaskID: UUID? { driver.snapshot().activeID }
  func elapsed(for task: DownloadTask) -> TimeInterval? { task.timing.elapsed(at: uptime()) }
  func remaining(for task: DownloadTask) -> TimeInterval? {
    task.state == .running ? task.timing.estimatedRemaining(at: uptime()) : nil
  }
  func averageSpeed(for task: DownloadTask) -> Double? {
    guard task.state.isTerminal, task.reusedBytes >= 0, task.transferred > task.reusedBytes,
      let elapsed = elapsed(for: task), elapsed.isFinite, elapsed > 0
    else { return nil }
    let rate = Double(task.transferred - task.reusedBytes) / elapsed
    return rate.isFinite && rate > 0 ? rate : nil
  }

  @discardableResult
  func enqueue(title: String, request: EngineRequest, demo: Bool, filterSummary: String = "")
    -> Bool
  {
    let result = driver.enqueue(
      title: title, request: request, demo: demo, filterSummary: filterSummary)
    apply(result.snapshot)
    return result.accepted
  }

  func cancel(_ id: UUID) { apply(driver.cancel(id)) }
  func continueTask(_ id: UUID) {
    guard let task = driver.snapshot().tasks.first(where: { $0.id == id }),
      task.state.isTerminal, task.state != .completed, task.resumeAvailable
    else { return }
    let request =
      task.hasDurableRecovery
      ? (recoveryRequest?(task.request, task.demo) ?? (recoveryRequest == nil ? task.request : nil))
      : task.request
    let message: String?
    if request == nil || !(canResume?(request ?? task.request, task.demo) ?? true) {
      message = L10n.text("请保持原手机及存储连接后继续此任务。")
    } else if !destinationIsAvailable(task.output ?? URL(fileURLWithPath: task.request.destination))
    {
      message = L10n.text("原保存位置不可用或无法写入，请连接对应硬盘后再继续此任务。")
    } else {
      message = nil
    }
    apply(driver.continueTask(id, rejection: message, reboundRequest: request))
  }
  func removeTask(_ id: UUID) { apply(driver.removeTask(id)) }
  func resolve(_ id: UUID, decision: DownloadConflictDecision) {
    apply(driver.resolve(id, decision: decision))
  }
  func dismissFinished() { apply(driver.dismissFinished()) }

  func resume() {
    let snapshot = driver.snapshot()
    guard !snapshot.tasks.contains(where: { [.running, .waiting, .cancelling].contains($0.state) })
    else {
      return
    }
    var rebound: [UUID: EngineRequest] = [:]
    let allowed = snapshot.tasks.filter { $0.state == .paused }.allSatisfy { task in
      let request =
        task.hasDurableRecovery
        ? (recoveryRequest?(task.request, task.demo)
          ?? (recoveryRequest == nil ? task.request : nil))
        : task.request
      guard let request, canResume?(request, task.demo) ?? true else { return false }
      rebound[task.id] = request
      return true
    }
    apply(driver.resume(allowed: allowed, reboundRequests: rebound))
  }

  func reserveForeground() -> UUID { driver.reserveForeground() }
  func waitUntilIdle() async {
    await driver.waitUntilIdle()
    // A foreground command needs current ownership even if a coalesced UI
    // publication is still queued behind other main-actor work.
    apply(driver.snapshot())
  }
  func releaseForeground(_ token: UUID, connectionUsable: Bool) {
    apply(driver.releaseForeground(token, connectionUsable: connectionUsable))
  }
  func invalidateConnection(_ message: String) { apply(driver.invalidateConnection(message)) }
  func shutdown() { apply(driver.shutdown()) }

  private func prepareSession() async { await beforeRequests?() }
  private func apply(_ snapshot: DownloadQueueSnapshot) {
    guard snapshot.revision > revision else { return }
    revision = snapshot.revision
    activeID = snapshot.activeID
    recoveryError = snapshot.recoveryError
    tasks = snapshot.tasks
    presentation.update(
      snapshot.tasks, activeID: snapshot.activeID, recoveryError: snapshot.recoveryError)
    conflicts.update(snapshot.tasks.first { $0.state == .waiting && $0.conflict != nil })
    onChange?()
  }
}
