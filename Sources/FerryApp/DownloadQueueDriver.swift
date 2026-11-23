import FerryCore
import Foundation

private struct DownloadAvailability: Equatable {
  let pending: Int
  let hasTasks: Bool
  let transferring: Bool
  let scheduled: Bool
}

struct DownloadQueueSnapshot: Sendable {
  let revision: UInt64
  let tasks: [DownloadTask]
  let activeID: UUID?
  let immediate: Bool
  var recoveryError: String? = nil
}

/// The lock protects commands, request ownership and snapshots only. Native
/// reads and stream consumption execute outside it on the cooperative pool.
final class DownloadQueueDriver: @unchecked Sendable {
  private let lock = NSLock()
  private let runner: any EngineRunning
  private let uptime: () -> TimeInterval
  private var tasks: [DownloadTask] = []
  private var activeID: UUID?
  private var prepared = false
  private var foreground = Set<UUID>()
  private var paused = false
  private var stopped = false
  private var generation = 0
  private var revision: UInt64 = 0
  private var availability: DownloadAvailability?
  private var worker: Task<Void, Never>?
  private var prepare: (@Sendable () async -> Void)?
  private var publish: (@Sendable (DownloadQueueSnapshot) -> Void)?
  private let store: DownloadTaskStore?
  private var recoveryError: String?
  private var persistenceBlocked = false

  init(
    runner: any EngineRunning, uptime: @escaping () -> TimeInterval, store: DownloadTaskStore? = nil
  ) {
    self.runner = runner
    self.uptime = uptime
    self.store = store
    do { tasks = try store?.load() ?? [] } catch {
      recoveryError = L10n.text("无法读取恢复任务：\(error.localizedDescription)")
      persistenceBlocked = true
    }
    if !tasks.isEmpty || recoveryError != nil { revision = 1 }
  }

  // Persist lifecycle changes only; byte progress and per-file handoff never
  // rewrite the UI index. The helper journals individual file completions.
  @discardableResult private func persistLocked() -> Bool {
    guard !persistenceBlocked else { return false }
    do {
      try store?.save(tasks)
      recoveryError = nil
      return true
    } catch {
      recoveryError = L10n.text("无法保存恢复任务：\(error.localizedDescription)")
      return false
    }
  }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  func configure(
    prepare: @escaping @Sendable () async -> Void,
    publish: @escaping @Sendable (DownloadQueueSnapshot) -> Void
  ) {
    locked {
      self.prepare = prepare
      self.publish = publish
    }
  }

  private func snapshotLocked(changed: Bool) -> DownloadQueueSnapshot {
    let next = DownloadAvailability(
      pending: tasks.filter { !$0.state.isTerminal }.count,
      hasTasks: !tasks.isEmpty,
      transferring: tasks.contains { [.running, .cancelling].contains($0.state) },
      scheduled: tasks.contains { [.queued, .running, .waiting, .cancelling].contains($0.state) })
    let immediate = next != availability
    if changed {
      revision &+= 1
      availability = next
    }
    return DownloadQueueSnapshot(
      revision: revision, tasks: tasks, activeID: activeID,
      immediate: immediate, recoveryError: recoveryError)
  }

  func snapshot() -> DownloadQueueSnapshot { locked { snapshotLocked(changed: false) } }
  private func offer(_ value: DownloadQueueSnapshot) {
    let send = locked { publish }
    send?(value)
  }

  private func startNextLocked() {
    guard activeID == nil, !paused, !stopped, foreground.isEmpty,
      let index = tasks.firstIndex(where: { $0.state == .queued })
    else { return }
    activeID = tasks[index].id
    prepared = false
    tasks[index].state = .running
    tasks[index].timing.start(at: uptime())
  }

  private func scheduleLocked() {
    guard !stopped, !paused, foreground.isEmpty, worker == nil else { return }
    startNextLocked()
    guard let id = activeID, let task = tasks.first(where: { $0.id == id }), task.state != .waiting
    else { return }
    let token = generation
    worker = Task.detached(priority: .userInitiated) { [self] in await drive(token: token) }
  }

  func enqueue(title: String, request: EngineRequest, demo: Bool, filterSummary: String = "")
    -> (accepted: Bool, snapshot: DownloadQueueSnapshot)
  {
    let result = locked { () -> (Bool, DownloadQueueSnapshot) in
      guard !stopped else { return (false, snapshotLocked(changed: false)) }
      if let existing = tasks.first(where: { !$0.state.isTerminal }),
        existing.demo != demo || existing.request.deviceKey != request.deviceKey
          || existing.request.usbTarget != request.usbTarget
      {
        return (false, snapshotLocked(changed: false))
      }
      if !tasks.contains(where: { !$0.state.isTerminal }) { paused = false }
      var task = DownloadTask(
        id: UUID(), title: title, filterSummary: filterSummary, request: request, demo: demo)
      task.sessionID = runner.sessionIdentifier
      if paused { task.state = .paused }
      tasks.append(task)
      guard persistLocked() else {
        tasks.removeLast()
        return (false, snapshotLocked(changed: true))
      }
      scheduleLocked()
      return (true, snapshotLocked(changed: true))
    }
    if result.0 { offer(result.1) }
    return (result.0, result.1)
  }

  func cancel(_ id: UUID) -> DownloadQueueSnapshot {
    let value = locked { () -> DownloadQueueSnapshot in
      guard let index = tasks.firstIndex(where: { $0.id == id }), !tasks[index].state.isTerminal
      else { return snapshotLocked(changed: false) }
      if id == activeID {
        tasks[index].state = .cancelling
        tasks[index].conflict = nil
        tasks[index].decision = nil
        // Let the in-flight command finish and consume ready. Interrupting
        // GetObject mid-stream can leave the phone's MTP endpoints blocked.
        // The next command cancels the job at this complete-file boundary.
        scheduleLocked()
      } else {
        tasks[index].state = .cancelled
        tasks[index].resumeAvailable = true
      }
      return snapshotLocked(changed: true)
    }
    offer(value)
    return value
  }

  func resolve(_ id: UUID, decision: DownloadConflictDecision) -> DownloadQueueSnapshot {
    let value = locked { () -> DownloadQueueSnapshot in
      guard !stopped, activeID == id,
        let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].state == .waiting,
        tasks[index].conflict?.id == decision.id
      else { return snapshotLocked(changed: false) }
      tasks[index].decision = decision
      tasks[index].conflict = nil
      tasks[index].state = .running
      scheduleLocked()
      return snapshotLocked(changed: true)
    }
    offer(value)
    return value
  }

  func continueTask(_ id: UUID, rejection: String?, reboundRequest: EngineRequest? = nil)
    -> DownloadQueueSnapshot
  {
    let value = locked { () -> DownloadQueueSnapshot in
      guard !stopped, let index = tasks.firstIndex(where: { $0.id == id }),
        tasks[index].state.isTerminal, tasks[index].state != .completed,
        tasks[index].resumeAvailable
      else { return snapshotLocked(changed: false) }
      let candidate = reboundRequest ?? tasks[index].request
      if !tasks[index].hasDurableRecovery && runner.sessionIdentifier != tasks[index].sessionID {
        tasks[index].resumeAvailable = false
        tasks[index].resumeToken = nil
        tasks[index].error = L10n.text("恢复信息已失效，请在本次手机连接内继续，或重新选择未完成文件。")
      } else if let rejection {
        tasks[index].error = rejection
      } else if tasks.contains(where: {
        !$0.state.isTerminal
          && ($0.demo != tasks[index].demo
            || $0.request.deviceKey != candidate.deviceKey
            || $0.request.usbTarget != candidate.usbTarget)
      }) {
        tasks[index].error = L10n.text("请保持原手机及存储连接后继续此任务。")
      } else {
        if let reboundRequest { tasks[index].request = reboundRequest }
        if tasks[index].sessionID != runner.sessionIdentifier {
          tasks[index].resumeToken = nil
        }
        if !tasks.contains(where: { !$0.state.isTerminal }) { paused = false }
        tasks[index].state = paused ? .paused : .queued
        tasks[index].resumeAvailable = false
        tasks[index].continuing = true
        tasks[index].error = nil
        tasks[index].reusedBytes = 0
        tasks[index].completed = 0
        tasks[index].transferred = 0
        tasks[index].skipped = 0
        tasks[index].timing = TransferTiming()
        tasks[index].currentFile = ""
        persistLocked()
        scheduleLocked()
      }
      return snapshotLocked(changed: true)
    }
    offer(value)
    return value
  }

  func dismissFinished() -> DownloadQueueSnapshot {
    let value = locked { () -> DownloadQueueSnapshot in
      tasks.removeAll { $0.state.isTerminal && !$0.resumeAvailable }
      persistLocked()
      return snapshotLocked(changed: true)
    }
    offer(value)
    return value
  }

  func removeTask(_ id: UUID) -> DownloadQueueSnapshot {
    let value = locked { () -> DownloadQueueSnapshot in
      tasks.removeAll { $0.id == id && $0.state.isTerminal }
      persistLocked()
      return snapshotLocked(changed: true)
    }
    offer(value)
    return value
  }

  func resume(allowed: Bool, reboundRequests: [UUID: EngineRequest] = [:]) -> DownloadQueueSnapshot
  {
    let value = locked { () -> DownloadQueueSnapshot in
      guard !stopped,
        !tasks.contains(where: { [.running, .waiting, .cancelling].contains($0.state) })
      else { return snapshotLocked(changed: false) }
      for index in tasks.indices where tasks[index].state == .paused {
        if allowed {
          if let request = reboundRequests[tasks[index].id] { tasks[index].request = request }
          if tasks[index].hasDurableRecovery && tasks[index].sessionID != runner.sessionIdentifier {
            tasks[index].continuing = true
            tasks[index].resumeToken = nil
          }
          tasks[index].state = .queued
          tasks[index].error = nil
        } else {
          tasks[index].error = L10n.text("请重新连接原手机后继续队列，或取消这些等待任务。")
        }
      }
      if allowed {
        persistLocked()
        paused = false
        scheduleLocked()
      }
      return snapshotLocked(changed: true)
    }
    offer(value)
    return value
  }

  func reserveForeground() -> UUID {
    locked {
      let token = UUID()
      foreground.insert(token)
      return token
    }
  }

  func waitUntilIdle() async {
    let current = locked { worker }
    await current?.value
  }

  func releaseForeground(_ token: UUID, connectionUsable: Bool) -> DownloadQueueSnapshot {
    let value = locked { () -> DownloadQueueSnapshot in
      foreground.remove(token)
      if !connectionUsable {
        invalidateLocked(L10n.text("读取手机时连接中断，当前下载已停止，请检查连接后继续队列。"))
      }
      scheduleLocked()
      return snapshotLocked(changed: true)
    }
    offer(value)
    return value
  }

  private func invalidateLocked(_ message: String) {
    clearRecoveryLocked()
    guard tasks.contains(where: { !$0.state.isTerminal }) || activeID != nil else { return }
    generation += 1
    paused = true
    if let id = activeID, let index = tasks.firstIndex(where: { $0.id == id }) {
      tasks[index].state = tasks[index].state == .cancelling ? .cancelled : .failed
      tasks[index].error = message
      tasks[index].conflict = nil
      tasks[index].decision = nil
      tasks[index].timing.finish(at: uptime())
    }
    activeID = nil
    prepared = false
    for index in tasks.indices where tasks[index].state == .queued {
      tasks[index].state = .paused
      tasks[index].error = message
    }
  }

  private func clearRecoveryLocked() {
    for index in tasks.indices {
      tasks[index].resumeAvailable =
        tasks[index].state != .completed && tasks[index].hasDurableRecovery
      tasks[index].resumeToken = nil
    }
    persistLocked()
  }

  func invalidateConnection(_ message: String) -> DownloadQueueSnapshot {
    let value = locked { () -> DownloadQueueSnapshot in
      invalidateLocked(message)
      return snapshotLocked(changed: true)
    }
    offer(value)
    return value
  }

  func shutdown() -> DownloadQueueSnapshot {
    let value = locked { () -> DownloadQueueSnapshot in
      stopped = true
      clearRecoveryLocked()
      generation += 1
      for index in tasks.indices where !tasks[index].state.isTerminal {
        tasks[index].state = .cancelled
        tasks[index].conflict = nil
        tasks[index].decision = nil
        tasks[index].timing.finish(at: uptime())
      }
      persistLocked()
      return snapshotLocked(changed: true)
    }
    offer(value)
    return value
  }

  private struct Request {
    let id: UUID
    let stream: AsyncThrowingStream<EngineEvent, Error>
  }

  private func nextRequest(token: Int) -> (Request?, DownloadQueueSnapshot?) {
    locked {
      guard !stopped, generation == token, !paused, foreground.isEmpty else { return (nil, nil) }
      startNextLocked()
      guard let id = activeID, let index = tasks.firstIndex(where: { $0.id == id }) else {
        return (nil, nil)
      }
      if tasks[index].state == .waiting { return (nil, nil) }
      if tasks[index].state == .cancelling && !prepared {
        let token = tasks[index].resumeToken
        finishLocked(id, state: .cancelled, resumeToken: token, resumeAvailable: true)
        startNextLocked()
        return (nil, snapshotLocked(changed: true))
      }
      var request = tasks[index].request
      if tasks[index].continuing && !tasks[index].hasDurableRecovery
        && tasks[index].sessionID != runner.sessionIdentifier
      {
        invalidateLocked(L10n.text("恢复信息已失效，请在本次手机连接内继续，或重新选择未完成文件。"))
        return (nil, snapshotLocked(changed: true))
      }
      request.downloadID = id.uuidString
      request.downloadAction =
        tasks[index].state == .cancelling
        ? "cancel"
        : tasks[index].decision != nil
          ? "resolve"
          : prepared
            ? "next"
            : tasks[index].resumeToken != nil
              ? "resume"
              : tasks[index].continuing && tasks[index].hasDurableRecovery
                ? "recover" : tasks[index].continuing ? "restart" : "begin"
      request.resumeToken = request.downloadAction == "resume" ? tasks[index].resumeToken : nil
      request.recoveryPath = request.downloadAction == "recover" ? tasks[index].recoveryPath : nil
      if request.downloadAction == "resolve" {
        request.conflictDecision = tasks[index].decision
        tasks[index].decision = nil
      }
      // Capture the runner's cancellation epoch while holding ownership. A
      // cancel between claim and stream creation must not launch a fresh helper.
      let stream = runner.events(for: request, demo: tasks[index].demo)
      return (Request(id: id, stream: stream), nil)
    }
  }

  private func applyLocked(_ event: EngineEvent, to id: UUID) -> Bool {
    guard let index = tasks.firstIndex(where: { $0.id == id }) else { return false }
    var task = tasks[index]
    var changed = false
    if event.type == "status", event.state == "session_only", let message = event.message {
      task.error = message
      changed = true
    }
    if let path = event.recoveryPath, task.recoveryPath != path {
      task.recoveryPath = path
      changed = true
    }
    if let conflict = event.conflict, task.state != .cancelling {
      task.conflict = conflict
      changed = true
    }
    if let path = event.reportPath {
      let report = URL(fileURLWithPath: path)
      if task.reportURL != report {
        task.reportURL = report
        changed = true
      }
    }
    if let path = event.output {
      let output = URL(fileURLWithPath: path)
      if task.output != output {
        task.output = output
        changed = true
      }
    }
    if event.type == "progress" {
      let completed = event.completed ?? task.completed
      let total = event.total ?? task.total
      let bytes = event.bytes ?? task.transferred
      let totalBytes = event.totalBytes ?? task.totalBytes
      let currentFile = event.currentFile ?? task.currentFile
      let skipped = event.skipped ?? task.skipped
      let reused = min(max(0, event.reusedBytes ?? task.reusedBytes), max(0, bytes))
      changed =
        changed || completed != task.completed || total != task.total
        || bytes != task.transferred || totalBytes != task.totalBytes
        || currentFile != task.currentFile || skipped != task.skipped || reused != task.reusedBytes
      task.completed = completed
      task.total = total
      task.transferred = bytes
      task.totalBytes = totalBytes
      task.currentFile = currentFile
      task.skipped = skipped
      task.reusedBytes = reused
      if changed {
        task.timing.recordProgress(
          bytes: bytes - reused, totalBytes: totalBytes - reused, at: uptime())
      }
    }
    if changed {
      let newRecovery = tasks[index].recoveryPath != task.recoveryPath
      tasks[index] = task
      if newRecovery { persistLocked() }
    }
    return changed
  }

  private func finishLocked(
    _ id: UUID, state: DownloadTaskState, error: String? = nil,
    resumeToken: String? = nil, resumeAvailable: Bool = false
  ) {
    guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
    tasks[index].state = state
    tasks[index].error =
      error
      ?? (tasks[index].request.durableRecovery == true && tasks[index].recoveryPath == nil
        ? tasks[index].error : nil)
    tasks[index].conflict = nil
    tasks[index].decision = nil
    tasks[index].resumeToken = resumeToken
    tasks[index].resumeAvailable =
      state != .completed
      && (resumeAvailable || resumeToken != nil || tasks[index].hasDurableRecovery)
    tasks[index].timing.finish(at: uptime())
    activeID = nil
    prepared = false
    persistLocked()
  }

  private func drive(token: Int) async {
    let preparation = locked { prepare }
    await preparation?()
    while true {
      let (request, commandUpdate) = nextRequest(token: token)
      if let commandUpdate {
        offer(commandUpdate)
        continue
      }
      guard let request else { break }
      var terminal: EngineEvent?
      var failure: String?
      do {
        for try await event in request.stream {
          if ["yielded", "completed", "error"].contains(event.type) { terminal = event }
          let update = locked { () -> DownloadQueueSnapshot? in
            guard generation == token, !stopped, activeID == request.id,
              applyLocked(event, to: request.id)
            else { return nil }
            return snapshotLocked(changed: true)
          }
          if let update { offer(update) }
        }
      } catch { failure = error.localizedDescription }
      let update = locked { () -> DownloadQueueSnapshot? in
        guard generation == token, !stopped,
          let task = tasks.first(where: { $0.id == request.id })
        else { return nil }
        if terminal?.type == "completed", failure == nil {
          let cancelled = terminal?.state == "cancelled"
          finishLocked(
            request.id, state: cancelled ? .cancelled : .completed,
            error: cancelled ? terminal?.message : nil,
            resumeToken: cancelled ? terminal?.resumeToken : nil)
        } else if terminal?.type == "yielded", failure == nil {
          if let index = tasks.firstIndex(where: { $0.id == request.id }) {
            if !prepared {
              tasks[index].started = true
              tasks[index].sessionID = runner.sessionIdentifier
              persistLocked()
            }
            tasks[index].resumeToken = nil
          }
          prepared = true
          if task.state != .cancelling && terminal?.conflict != nil,
            let index = tasks.firstIndex(where: { $0.id == request.id })
          {
            tasks[index].state = .waiting
          }
        } else {
          let wasCancelled =
            task.state == .cancelling && terminal?.state == "cancelled" && failure == nil
          finishLocked(
            request.id, state: wasCancelled ? .cancelled : .failed,
            error: wasCancelled ? nil : failure ?? terminal?.message ?? L10n.text("下载响应不完整，队列已暂停。"))
          // A failed command may have retired its helper. Do not turn a real
          // transport failure during cancellation into automatic reconnects.
          paused = true
          clearRecoveryLocked()
          for index in tasks.indices where tasks[index].state == .queued {
            tasks[index].state = .paused
          }
        }
        startNextLocked()
        return snapshotLocked(changed: true)
      }
      if let update { offer(update) }
      await Task.yield()
    }
    let update = locked { () -> DownloadQueueSnapshot in
      worker = nil
      scheduleLocked()
      return snapshotLocked(changed: true)
    }
    offer(update)
  }
}

/// A latest-value mailbox. Publishing can wait for MainActor; transferring
/// cannot. Pending progress is coalesced to at most four UI updates per second.
final class DownloadSnapshotDelivery: @unchecked Sendable {
  private let lock = NSLock()
  private var pending: DownloadQueueSnapshot?
  private var scheduled = false
  private var timer: DispatchWorkItem?
  private var timerGeneration: UInt64 = 0
  private var newestRevision: UInt64 = 0
  private var lastDelivery = -Double.infinity
  @MainActor var receive: ((DownloadQueueSnapshot) -> Void)?

  func offer(_ snapshot: DownloadQueueSnapshot) {
    lock.lock()
    if snapshot.revision <= newestRevision {
      lock.unlock()
      return
    }
    newestRevision = snapshot.revision
    pending = snapshot
    if snapshot.immediate {
      timer?.cancel()
      timer = nil
      timerGeneration &+= 1
      scheduleMainLocked()
    } else if !scheduled && timer == nil {
      let delay = max(0, lastDelivery + 0.25 - ProcessInfo.processInfo.systemUptime)
      timerGeneration &+= 1
      let token = timerGeneration
      let work = DispatchWorkItem { [weak self] in
        guard let self else { return }
        self.lock.lock()
        guard token == self.timerGeneration, self.timer != nil else {
          self.lock.unlock()
          return
        }
        self.timer = nil
        self.scheduleMainLocked()
        self.lock.unlock()
      }
      timer = work
      DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay, execute: work)
    }
    lock.unlock()
  }

  private func scheduleMainLocked() {
    guard !scheduled else { return }
    scheduled = true
    Task { @MainActor [weak self] in self?.deliver() }
  }

  @MainActor private func deliver() {
    lock.lock()
    let snapshot = pending
    pending = nil
    scheduled = false
    lastDelivery = ProcessInfo.processInfo.systemUptime
    lock.unlock()
    if let snapshot { receive?(snapshot) }
  }
}
