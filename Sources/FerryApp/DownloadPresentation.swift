import Combine
import FerryCore
import Foundation

/// A stable identity for one visible task. Only presentation changes notify
/// this row; immutable request arrays never participate in progress diffing.
@MainActor
final class DownloadTaskRowModel: ObservableObject, Identifiable {
  let objectWillChange = ObservableObjectPublisher()
  let id: UUID
  private(set) var task: DownloadTask

  init(_ task: DownloadTask) {
    self.id = task.id
    self.task = task
  }

  func update(_ value: DownloadTask) {
    let old = task
    let changed =
      old.title != value.title || old.filterSummary != value.filterSummary
      || old.state != value.state
      || old.completed != value.completed || old.total != value.total
      || old.transferred != value.transferred || old.totalBytes != value.totalBytes
      || old.currentFile != value.currentFile || old.skipped != value.skipped
      || old.output != value.output || old.reportURL != value.reportURL
      || old.error != value.error || old.timing != value.timing
      || old.resumeAvailable != value.resumeAvailable || old.reusedBytes != value.reusedBytes
    if changed { objectWillChange.send() }
    task = value
  }
}

/// List membership, toolbar controls and focus change infrequently. Progress
/// is delivered to the existing row object, not to every list subscriber.
@MainActor
final class DownloadQueuePresentation: ObservableObject {
  @Published private(set) var rows: [DownloadTaskRowModel] = []
  @Published private(set) var hasPaused = false
  @Published private(set) var hasFinished = false
  @Published private(set) var pendingTaskCount = 0
  @Published private(set) var focusedRow: DownloadTaskRowModel?
  @Published private(set) var recoveryError: String?
  private var byID: [UUID: DownloadTaskRowModel] = [:]

  func update(_ tasks: [DownloadTask], activeID: UUID?, recoveryError: String? = nil) {
    let ids = tasks.reversed().map(\.id)
    for task in tasks {
      if let row = byID[task.id] {
        row.update(task)
      } else {
        byID[task.id] = DownloadTaskRowModel(task)
      }
    }
    if rows.map(\.id) != ids {
      rows = ids.compactMap { byID[$0] }
      let retained = Set(ids)
      byID = byID.filter { retained.contains($0.key) }
    }
    let paused = tasks.contains { $0.state == .paused }
    let finished = tasks.contains { $0.state.isTerminal && !$0.resumeAvailable }
    let pending = tasks.filter { !$0.state.isTerminal }.count
    let focus = activeID.flatMap { byID[$0] } ?? rows.first
    if hasPaused != paused { hasPaused = paused }
    if hasFinished != finished { hasFinished = finished }
    if pendingTaskCount != pending { pendingTaskCount = pending }
    if focusedRow?.id != focus?.id { focusedRow = focus }
    if self.recoveryError != recoveryError { self.recoveryError = recoveryError }
  }
}

struct DownloadConflictPrompt: Identifiable {
  let taskID: UUID
  let conflict: DownloadConflict
  var id: String { conflict.id }
}

/// The main window observes this model only. A byte/file progress update
/// cannot invalidate the sheet's presenter when the question is unchanged.
@MainActor
final class DownloadConflictState: ObservableObject {
  @Published private(set) var prompt: DownloadConflictPrompt?
  func update(_ task: DownloadTask?) {
    let next = task.flatMap { value in
      value.conflict.map { DownloadConflictPrompt(taskID: value.id, conflict: $0) }
    }
    guard prompt?.id != next?.id || prompt?.taskID != next?.taskID else { return }
    prompt = next
  }
}
