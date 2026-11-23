import Combine
import FerryCore
import Foundation
import XCTest

@testable import FerryApp

@MainActor
final class DownloadPresentationTests: XCTestCase {
  func testProgressNotifiesOnlyActiveRowAndNeverListHistoryOrConflictPresenter() {
    let presentation = DownloadQueuePresentation()
    let conflicts = DownloadConflictState()
    var history = DownloadTask(
      id: UUID(), title: "history", state: .completed,
      request: EngineRequest(operation: "download"), demo: true)
    history.timing.start(at: 0)
    history.timing.finish(at: 1)
    var active = DownloadTask(
      id: UUID(), title: "active", state: .running, total: 1, totalBytes: 1000,
      request: EngineRequest(operation: "download"), demo: true)
    active.timing.start(at: 1)
    presentation.update([history, active], activeID: active.id)
    let first = presentation.rows[1]
    let second = presentation.rows[0]
    var lists = 0
    var oldRows = 0
    var activeRows = 0
    var modals = 0
    let subscriptions = [
      presentation.objectWillChange.sink { lists += 1 },
      first.objectWillChange.sink { oldRows += 1 },
      second.objectWillChange.sink { activeRows += 1 },
      conflicts.objectWillChange.sink { modals += 1 },
    ]
    defer { for subscription in subscriptions { subscription.cancel() } }
    for bytes in 1...1000 {
      active.transferred = Int64(bytes)
      active.timing.recordProgress(bytes: Int64(bytes), totalBytes: 1000, at: Double(bytes) + 1)
      presentation.update([history, active], activeID: active.id)
      conflicts.update(nil)
    }
    XCTAssertEqual(lists, 0)
    XCTAssertEqual(oldRows, 0)
    XCTAssertEqual(modals, 0)
    XCTAssertEqual(activeRows, 1000)
    XCTAssertTrue(presentation.rows[1] === first)
    XCTAssertTrue(presentation.rows[0] === second)
    XCTAssertEqual(second.task.transferred, 1000)
    active.state = .completed
    active.timing.finish(at: 1002)
    presentation.update([history, active], activeID: nil)
    XCTAssertEqual(presentation.pendingTaskCount, 0)
    XCTAssertTrue(presentation.hasFinished)
    XCTAssertTrue(presentation.focusedRow === second)
    presentation.update([active], activeID: nil)
    XCTAssertTrue(presentation.rows[0] === second)
  }

  func testNewestTasksAppearFirstAndStateChangesKeepTheirPositions() {
    let presentation = DownloadQueuePresentation()
    var oldest = DownloadTask(
      id: UUID(), title: "oldest", state: .running,
      request: EngineRequest(operation: "download"), demo: true)
    var newest = DownloadTask(
      id: UUID(), title: "newest", state: .queued,
      request: EngineRequest(operation: "download"), demo: true)
    presentation.update([oldest, newest], activeID: oldest.id)
    XCTAssertEqual(presentation.rows.map(\.id), [newest.id, oldest.id])
    XCTAssertEqual(presentation.focusedRow?.id, oldest.id)
    let newestRow = presentation.rows[0]
    let oldestRow = presentation.rows[1]

    oldest.state = .completed
    newest.state = .running
    presentation.update([oldest, newest], activeID: newest.id)
    XCTAssertTrue(presentation.rows[0] === newestRow)
    XCTAssertTrue(presentation.rows[1] === oldestRow)
    XCTAssertTrue(presentation.focusedRow === newestRow)

    newest.state = .failed
    presentation.update([oldest, newest], activeID: nil)
    XCTAssertEqual(presentation.rows.map(\.id), [newest.id, oldest.id])
    XCTAssertTrue(presentation.focusedRow === newestRow)

    let added = DownloadTask(
      id: UUID(), title: "added", state: .queued,
      request: EngineRequest(operation: "download"), demo: true)
    presentation.update([oldest, newest, added], activeID: nil)
    XCTAssertEqual(presentation.rows.map(\.id), [added.id, newest.id, oldest.id])
    XCTAssertTrue(presentation.rows[1] === newestRow)
    XCTAssertTrue(presentation.rows[2] === oldestRow)

    presentation.update([oldest, newest], activeID: nil)
    XCTAssertTrue(presentation.focusedRow === newestRow)
    presentation.update([], activeID: nil)
    XCTAssertTrue(presentation.rows.isEmpty)
    XCTAssertNil(presentation.focusedRow)
  }

  func testConflictPresenterOnlyPublishesQuestionChangesAndClearing() throws {
    let state = DownloadConflictState()
    let conflict = try JSONDecoder().decode(
      DownloadConflict.self,
      from: Data(
        """
        {"id":"question","kind":"file","targetPath":"/tmp/photo.jpg","name":"photo.jpg","existingSize":3,"existingModified":100,"incomingSize":4,"incomingModified":200,"canReplace":true}
        """.utf8))
    var task = DownloadTask(
      id: UUID(), title: "photo", state: .waiting, conflict: conflict,
      request: EngineRequest(operation: "download"), demo: true)
    var changes = 0
    let subscription = state.objectWillChange.sink { changes += 1 }
    defer { subscription.cancel() }
    state.update(task)
    XCTAssertEqual(changes, 1)
    for bytes in 0..<1000 {
      task.transferred = Int64(bytes)
      state.update(task)
    }
    XCTAssertEqual(changes, 1)
    XCTAssertEqual(state.prompt?.taskID, task.id)
    state.update(nil)
    state.update(nil)
    XCTAssertEqual(changes, 2)
    XCTAssertNil(state.prompt)
  }
}
