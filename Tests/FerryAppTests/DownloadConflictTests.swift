import FerryCore
import Foundation
import XCTest

@testable import FerryApp

private final class ConflictEngine: EngineRunning, @unchecked Sendable {
  private let lock = NSRecursiveLock()
  @ThreadSafeTestValue var requests: [EngineRequest] = []
  @ThreadSafeTestValue var cancels = 0
  let kind: String
  init(kind: String = "file") { self.kind = kind }

  private func event(_ object: [String: Any]) -> EngineEvent {
    try! JSONDecoder().decode(
      EngineEvent.self, from: JSONSerialization.data(withJSONObject: object))
  }
  func events(for request: EngineRequest, demo: Bool) -> AsyncThrowingStream<EngineEvent, Error> {
    lock.lock()
    defer { lock.unlock() }
    requests.append(request)
    return AsyncThrowingStream { continuation in
      switch request.downloadAction {
      case "begin": continuation.yield(event(["type": "yielded", "state": "running"]))
      case "next":
        continuation.yield(
          event([
            "type": "yielded", "state": "waiting",
            "conflict": [
              "id": "conflict-\(request.downloadID!)", "kind": kind,
              "targetPath": "/tmp/target/photo.jpg", "name": "photo.jpg",
              "existingSize": 3, "existingModified": 100, "incomingSize": 4,
              "incomingModified": 200,
              "canReplace": kind == "file",
              "candidates": kind == "file" ? [] : ["2017/01月", "2017/1月"],
            ],
          ]))
      case "resolve":
        XCTAssertNotNil(request.conflictDecision)
        continuation.yield(
          event([
            "type": "progress", "completed": 1, "total": 1,
            "bytes": 4, "totalBytes": 4,
            "reusedBytes": request.conflictDecision?.choice == "skip" ? 4 : 0,
            "skipped": request.conflictDecision?.choice == "skip" ? 1 : 0,
          ]))
        continuation.yield(event(["type": "completed", "state": "completed"]))
      case "cancel": continuation.yield(event(["type": "completed", "state": "cancelled"]))
      default: XCTFail("Unexpected conflict test request")
      }
      continuation.finish()
    }
  }
  func cancel() { cancels += 1 }
  func shutdown() {}
}

@MainActor
final class DownloadConflictTests: XCTestCase {
  private func waitUntil(_ predicate: () -> Bool) async throws {
    for _ in 0..<400 {
      if predicate() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Conflict queue timed out")
    throw EngineFailure("test timeout")
  }
  private func enqueue(_ controller: DownloadQueueController) {
    XCTAssertTrue(
      controller.enqueue(
        title: "photo.jpg",
        request: EngineRequest(
          operation: "download", deviceKey: "phone", storageID: 1,
          objectIDs: [1], destination: "/tmp/target", promptConflicts: true), demo: true))
  }

  func testWaitingDoesNotSpinAndDecisionIsSentOnce() async throws {
    let engine = ConflictEngine()
    let controller = DownloadQueueController(runner: engine, uptime: { 1 })
    defer { controller.shutdown() }
    enqueue(controller)
    try await waitUntil { controller.waitingTask != nil }
    let task = try XCTUnwrap(controller.waitingTask)
    let conflict = try XCTUnwrap(task.conflict)
    XCTAssertTrue(controller.hasPendingTasks)
    XCTAssertTrue(controller.hasScheduledWork)
    XCTAssertFalse(controller.isTransferring)
    let count = engine.requests.count
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(
      engine.requests.count, count, "Waiting must not repeatedly request the same file")
    controller.resolve(task.id, decision: DownloadConflictDecision(id: "stale", choice: "replace"))
    XCTAssertEqual(engine.requests.count, count)
    controller.resolve(
      task.id, decision: DownloadConflictDecision(id: conflict.id, choice: "skip", applyToAll: true)
    )
    try await waitUntil { controller.tasks.first?.state == .completed }
    let decisions = engine.requests.filter { $0.downloadAction == "resolve" }
    XCTAssertEqual(decisions.count, 1)
    XCTAssertEqual(decisions.first?.conflictDecision?.id, conflict.id)
    XCTAssertEqual(decisions.first?.conflictDecision?.choice, "skip")
    XCTAssertEqual(decisions.first?.conflictDecision?.applyToAll, true)
    XCTAssertEqual(controller.tasks[0].skipped, 1)
    XCTAssertEqual(controller.tasks[0].transferred, 4)
    XCTAssertEqual(controller.tasks[0].reusedBytes, 4)
    XCTAssertNil(controller.tasks[0].conflict)
    enqueue(controller)
    try await waitUntil { controller.waitingTask != nil }
    XCTAssertNotEqual(controller.waitingTask?.id, task.id)
    XCTAssertNil(controller.waitingTask?.request.conflictDecision)
  }

  func testCancellingWaitingTaskUsesJobCancelAndRejectsLateDecision() async throws {
    let engine = ConflictEngine()
    let controller = DownloadQueueController(runner: engine, uptime: { 1 })
    defer { controller.shutdown() }
    enqueue(controller)
    try await waitUntil { controller.waitingTask != nil }
    let task = try XCTUnwrap(controller.waitingTask)
    let conflict = try XCTUnwrap(task.conflict)
    controller.cancel(task.id)
    try await waitUntil { controller.tasks.first?.state == .cancelled }
    controller.resolve(
      task.id, decision: DownloadConflictDecision(id: conflict.id, choice: "replace"))
    XCTAssertEqual(engine.cancels, 0, "An idle helper must receive cancel, not be interrupted")
    XCTAssertEqual(engine.requests.filter { $0.downloadAction == "cancel" }.count, 1)
    XCTAssertFalse(engine.requests.contains { $0.downloadAction == "resolve" })
    XCTAssertNil(controller.waitingTask)
  }

  func testForegroundReservationDelaysResolutionWithoutLosingDirectoryChoice() async throws {
    let engine = ConflictEngine(kind: "monthDirectory")
    let controller = DownloadQueueController(runner: engine, uptime: { 1 })
    defer { controller.shutdown() }
    enqueue(controller)
    try await waitUntil { controller.waitingTask != nil }
    let task = try XCTUnwrap(controller.waitingTask)
    let conflict = try XCTUnwrap(task.conflict)
    let token = controller.reserveForeground()
    await controller.waitUntilIdle()
    controller.resolve(
      task.id,
      decision: DownloadConflictDecision(id: conflict.id, choice: "directory", directory: "2017/1月")
    )
    XCTAssertFalse(engine.requests.contains { $0.downloadAction == "resolve" })
    controller.releaseForeground(token, connectionUsable: true)
    try await waitUntil { controller.tasks.first?.state == .completed }
    XCTAssertEqual(
      engine.requests.first { $0.downloadAction == "resolve" }?.conflictDecision?.directory,
      "2017/1月")
  }

  func testConnectionInvalidationClearsWaitingPromptAndPausesLaterTasks() async throws {
    let engine = ConflictEngine()
    let controller = DownloadQueueController(runner: engine, uptime: { 1 })
    defer { controller.shutdown() }
    enqueue(controller)
    try await waitUntil { controller.waitingTask != nil }
    let task = try XCTUnwrap(controller.waitingTask)
    let conflict = try XCTUnwrap(task.conflict)
    enqueue(controller)
    controller.invalidateConnection("disconnected")
    XCTAssertEqual(controller.tasks.map(\.state), [.failed, .paused])
    XCTAssertNil(controller.waitingTask)
    controller.resolve(
      task.id, decision: DownloadConflictDecision(id: conflict.id, choice: "replace"))
    XCTAssertFalse(engine.requests.contains { $0.downloadAction == "resolve" })
  }
}
