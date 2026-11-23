import FerryCore
import Foundation
import XCTest

@testable import FerryApp

private final class QueueUSB: USBMonitoring {
  var onChange: ((Set<UInt64>) -> Void)?
  var devices: Set<UInt64> = [42]
  func start() throws { onChange?(devices) }
  func stop() {}
  func emit(_ ids: Set<UInt64>) {
    devices = ids
    onChange?(ids)
  }
}

private final class QueueEngine: EngineRunning, @unchecked Sendable {
  private let callsLock = NSRecursiveLock()
  @ThreadSafeTestValue var requests: [EngineRequest] = []
  @ThreadSafeTestValue var pending:
    (EngineRequest, AsyncThrowingStream<EngineEvent, Error>.Continuation)? = nil
  @ThreadSafeTestValue var steps: [String: Int] = [:]
  @ThreadSafeTestValue var active = 0
  @ThreadSafeTestValue var maximumActive = 0
  @ThreadSafeTestValue var cancels = 0
  @ThreadSafeTestValue var disconnects = 0
  @ThreadSafeTestValue var holdLists = false
  @ThreadSafeTestValue var fastListing = false
  @ThreadSafeTestValue var holdBegins = false
  @ThreadSafeTestValue var waitingOnNext = false
  @ThreadSafeTestValue var key = "queue-phone"
  @ThreadSafeTestValue var sessionIdentifier: UUID? = UUID()
  @ThreadSafeTestValue var recoveries: [String: Int] = [:]

  func event(_ object: [String: Any]) -> EngineEvent {
    try! JSONDecoder().decode(
      EngineEvent.self, from: JSONSerialization.data(withJSONObject: object))
  }
  func events(for request: EngineRequest, demo: Bool) -> AsyncThrowingStream<EngineEvent, Error> {
    callsLock.lock()
    defer { callsLock.unlock() }
    requests.append(request)
    active += 1
    maximumActive = max(maximumActive, active)
    return AsyncThrowingStream { continuation in
      if request.downloadAction == "next" || (request.downloadAction == "begin" && holdBegins)
        || (request.operation == "list" && holdLists)
      {
        XCTAssertNil(pending)
        pending = (request, continuation)
      } else {
        deliver(request, continuation)
      }
    }
  }
  func deliver(
    _ request: EngineRequest, _ continuation: AsyncThrowingStream<EngineEvent, Error>.Continuation
  ) {
    callsLock.lock()
    defer { callsLock.unlock() }
    switch request.operation {
    case "connect":
      continuation.yield(
        event([
          "type": "connected", "deviceName": "Queue phone", "deviceKey": key,
          "storages": [["id": 1, "name": "Storage", "capacity": 100000, "free": 50000]],
        ]))
    case "list":
      let parent = request.parentID
      let entries: [[String: Any]] =
        parent == 0
        ? [
          [
            "id": 1, "storageID": 1, "name": "one.jpg", "size": 500, "isDirectory": false,
            "modified": 0,
          ],
          [
            "id": 2, "storageID": 1, "name": "two.jpg", "size": 500, "isDirectory": false,
            "modified": 0,
          ],
          [
            "id": 10, "storageID": 1, "name": "Folder", "size": 0, "isDirectory": true,
            "modified": 0,
          ],
        ]
        : [
          [
            "id": 11, "storageID": 1, "name": "child.jpg", "size": 500, "isDirectory": false,
            "modified": 0,
          ]
        ]
      let listed =
        fastListing
        ? entries.map { row in
          var row = row
          if row["isDirectory"] as? Bool == false { row["size"] = -1 }
          return row
        } : entries
      continuation.yield(event(["type": "listed", "entries": listed]))
    case "sizes":
      continuation.yield(event(["type": "sized", "sizes": [["id": 1, "size": 500]]]))
    case "download":
      let id = request.downloadID!
      switch request.downloadAction {
      case "begin", "restart":
        XCTAssertTrue(steps.isEmpty)
        steps[id] = 0
        continuation.yield(event(["type": "progress", "bytes": 0, "totalBytes": 1000, "total": 2]))
        continuation.yield(
          event(["type": "yielded", "state": "running", "reportPath": "/tmp/reports/\(id).json"]))
      case "next":
        if waitingOnNext {
          continuation.yield(
            event([
              "type": "yielded", "state": "waiting",
              "conflict": [
                "id": "conflict-\(id)", "kind": "file", "targetPath": "/tmp/photo.jpg",
                "name": "photo.jpg",
                "existingSize": 3, "existingModified": 100, "incomingSize": 500,
                "incomingModified": 200, "canReplace": true,
              ],
            ]))
          active -= 1
          continuation.finish()
          return
        }
        let count = (steps[id] ?? 0) + 1
        steps[id] = count
        continuation.yield(
          event([
            "type": "progress", "bytes": count * 500, "totalBytes": 1000,
            "completed": count, "total": 2, "currentFile": "file\(count).jpg",
          ]))
        continuation.yield(
          event([
            "type": count == 2 ? "completed" : "yielded",
            "state": count == 2 ? "completed" : "running",
          ]))
        if count == 2 { steps[id] = nil }
      case "cancel":
        recoveries[id] = steps[id] ?? 0
        steps[id] = nil
        continuation.yield(
          event(["type": "completed", "state": "cancelled", "resumeToken": "resume-\(id)"]))
      case "resume":
        XCTAssertEqual(request.resumeToken, "resume-\(id)")
        let count = recoveries[id] ?? 0
        steps[id] = count
        continuation.yield(
          event([
            "type": "progress", "bytes": count * 500, "reusedBytes": count * 500,
            "completed": count, "totalBytes": 1000, "total": 2,
          ]))
        continuation.yield(event(["type": "yielded", "state": "running"]))
      default: XCTFail("unexpected download action")
      }
    default: XCTFail("unexpected request")
    }
    active -= 1
    continuation.finish()
  }
  func finishHeld(failure: Bool = false) {
    callsLock.lock()
    defer { callsLock.unlock() }
    guard let (request, continuation) = pending else { return }
    pending = nil
    if failure {
      steps.removeAll()
      active -= 1
      continuation.yield(event(["type": "error", "state": "failed", "message": "USB unavailable"]))
      continuation.finish()
    } else {
      deliver(request, continuation)
    }
  }
  func cancel() {
    callsLock.lock()
    defer { callsLock.unlock() }
    cancels += 1
    steps.removeAll()
    if let (_, continuation) = pending {
      pending = nil
      active -= 1
      continuation.yield(event(["type": "error", "state": "cancelled"]))
      continuation.finish()
    }
  }
  func disconnect() {
    callsLock.lock()
    defer { callsLock.unlock() }
    disconnects += 1
    if pending != nil { cancel() } else { steps.removeAll() }
  }
  func shutdown() {
    callsLock.lock()
    defer { callsLock.unlock() }
    pending?.1.finish()
    pending = nil
    steps.removeAll()
  }
}

@MainActor
final class DownloadQueueTests: XCTestCase {
  func testContinuationRechecksSessionAfterWaitingForPreparation() async throws {
    let engine = QueueEngine()
    let queue = DownloadQueueController(
      runner: engine, uptime: { ProcessInfo.processInfo.systemUptime },
      destinationIsAvailable: { _ in true })
    var release = false
    defer {
      release = true
      queue.shutdown()
      engine.shutdown()
    }
    queue.enqueue(
      title: "task", request: EngineRequest(operation: "download", storageID: 1), demo: true)
    try await waitUntil { engine.pending != nil }
    let id = try XCTUnwrap(queue.tasks.first?.id)
    queue.cancel(id)
    engine.finishHeld()
    try await waitUntil { queue.tasks.first?.state == .cancelled }
    var preparing = false
    queue.beforeRequests = {
      preparing = true
      while !release { try? await Task.sleep(nanoseconds: 1_000_000) }
    }
    let calls = engine.requests.count
    queue.continueTask(id)
    try await waitUntil { preparing }
    engine.sessionIdentifier = UUID()
    release = true
    try await waitUntil { queue.tasks.first?.state == .failed }
    XCTAssertEqual(engine.requests.count, calls, "A changed helper must not receive old handles")
  }
  func testContinueCancelledTaskUsesOriginalRequestAndExcludesReusedBytesFromAverage() async throws
  {
    let clock = ThreadSafeTestValue(wrappedValue: TimeInterval(100))
    let engine = QueueEngine()
    let queue = DownloadQueueController(
      runner: engine, uptime: { clock.wrappedValue }, destinationIsAvailable: { _ in true })
    defer {
      queue.shutdown()
      engine.shutdown()
    }
    let request = EngineRequest(
      operation: "download", deviceKey: "queue-phone", storageID: 1, objectIDs: [1, 2],
      destination: "/original-folder", downloadLayout: "folder", archivePhotosByMonth: true)
    XCTAssertTrue(queue.enqueue(title: "original", request: request, demo: true))
    try await waitUntil { engine.pending != nil }
    let id = try XCTUnwrap(queue.tasks.first?.id)
    queue.cancel(id)
    engine.finishHeld()
    try await waitUntil { queue.tasks.first?.state == .cancelled }
    XCTAssertTrue(try XCTUnwrap(queue.tasks.first).resumeAvailable)
    clock.wrappedValue = 200
    queue.continueTask(id)
    try await waitUntil {
      engine.requests.contains { $0.downloadAction == "resume" } && engine.pending != nil
    }
    let resumed = try XCTUnwrap(engine.requests.first { $0.downloadAction == "resume" })
    XCTAssertEqual(resumed.downloadID, id.uuidString)
    XCTAssertEqual(resumed.destination, request.destination)
    XCTAssertEqual(resumed.objectIDs, request.objectIDs)
    XCTAssertEqual(resumed.downloadLayout, "folder")
    XCTAssertTrue(resumed.archivePhotosByMonth)
    clock.wrappedValue = 220
    engine.finishHeld()
    try await waitUntil { queue.tasks.first?.state == .completed }
    let task = try XCTUnwrap(queue.tasks.first)
    XCTAssertEqual(queue.tasks.count, 1)
    XCTAssertEqual(task.reusedBytes, 500)
    XCTAssertEqual(task.transferred, 1000)
    XCTAssertEqual(queue.elapsed(for: task), 20)
    XCTAssertEqual(queue.averageSpeed(for: task), 25)
    XCTAssertEqual(engine.cancels, 0)
    XCTAssertEqual(engine.maximumActive, 1)
  }

  func testCancelledQueuedTaskCanRejoinWithoutInterruptingActiveTask() async throws {
    let engine = QueueEngine()
    let queue = DownloadQueueController(
      runner: engine, uptime: { ProcessInfo.processInfo.systemUptime },
      destinationIsAvailable: { _ in true })
    defer {
      queue.shutdown()
      engine.shutdown()
    }
    let request = EngineRequest(operation: "download", storageID: 1, destination: "/synthetic")
    queue.enqueue(title: "active", request: request, demo: true)
    try await waitUntil { engine.pending != nil }
    queue.enqueue(title: "pending", request: request, demo: true)
    let id = queue.tasks[1].id
    queue.cancel(id)
    XCTAssertTrue(queue.tasks[1].resumeAvailable)
    let calls = engine.requests.count
    queue.continueTask(id)
    XCTAssertEqual(engine.requests.count, calls)
    XCTAssertEqual(queue.tasks[1].state, .queued)
    for _ in 0..<4 {
      try await waitUntil { engine.pending != nil }
      engine.finishHeld()
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    try await waitUntil { queue.tasks.allSatisfy { $0.state == .completed } }
    XCTAssertEqual(
      engine.requests.filter { $0.downloadID == id.uuidString }.first?.downloadAction, "restart")
    XCTAssertEqual(engine.maximumActive, 1)
    XCTAssertEqual(engine.cancels, 0)
  }

  func testContinuationPreservesCheckpointWhenDiskIsUnavailableAndRejectsNewSession() async throws {
    let engine = QueueEngine()
    var writable = false
    let queue = DownloadQueueController(
      runner: engine, uptime: { ProcessInfo.processInfo.systemUptime },
      destinationIsAvailable: { _ in writable })
    defer {
      queue.shutdown()
      engine.shutdown()
    }
    queue.enqueue(
      title: "task", request: EngineRequest(operation: "download", storageID: 1), demo: true)
    try await waitUntil { engine.pending != nil }
    let id = try XCTUnwrap(queue.tasks.first?.id)
    queue.cancel(id)
    engine.finishHeld()
    try await waitUntil { queue.tasks.first?.state == .cancelled }
    let calls = engine.requests.count
    queue.continueTask(id)
    XCTAssertEqual(queue.tasks.first?.state, .cancelled)
    XCTAssertTrue(try XCTUnwrap(queue.tasks.first).resumeAvailable)
    XCTAssertNotNil(queue.tasks.first?.error)
    writable = true
    engine.sessionIdentifier = UUID()
    queue.continueTask(id)
    XCTAssertFalse(try XCTUnwrap(queue.tasks.first).resumeAvailable)
    XCTAssertNil(queue.tasks.first?.resumeToken)
    XCTAssertEqual(engine.requests.count, calls)
  }

  func testConnectionInvalidationClearsRecoveryEvenWhenAllTasksEnded() async throws {
    let engine = QueueEngine()
    let queue = DownloadQueueController(
      runner: engine, uptime: { ProcessInfo.processInfo.systemUptime },
      destinationIsAvailable: { _ in true })
    defer {
      queue.shutdown()
      engine.shutdown()
    }
    queue.enqueue(
      title: "task", request: EngineRequest(operation: "download", storageID: 1), demo: true)
    try await waitUntil { engine.pending != nil }
    let id = try XCTUnwrap(queue.tasks.first?.id)
    queue.cancel(id)
    engine.finishHeld()
    try await waitUntil { queue.tasks.first?.state == .cancelled }
    XCTAssertTrue(try XCTUnwrap(queue.tasks.first).resumeAvailable)
    queue.invalidateConnection("synthetic disconnect")
    XCTAssertFalse(try XCTUnwrap(queue.tasks.first).resumeAvailable)
    XCTAssertFalse(queue.presentation.rows[0].task.resumeAvailable)
  }
  private func waitUntil(_ predicate: () -> Bool) async throws {
    for _ in 0..<400 {
      if predicate() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("queue did not reach expected state")
    throw EngineFailure("test timeout")
  }
  private func model(_ engine: QueueEngine, usb: QueueUSB = QueueUSB()) -> AppModel {
    let domain = "ferry-queue-\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: domain)!
    addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: domain) }
    return AppModel(
      runner: engine, usbMonitor: usb, preferences: preferences,
      destinationIsAvailable: { _ in true })
  }
  private func connect(_ model: AppModel) async throws {
    model.demo = true
    model.connect()
    try await waitUntil { !model.busy && model.entries.count == 3 }
  }

  func testEveryAcceptedTaskPublishesImmediateFeedbackAndOldDismissCannotClearNewFeedback()
    async throws
  {
    let engine = QueueEngine()
    let model = model(engine)
    defer { model.shutdown() }
    try await connect(model)
    model.download()
    XCTAssertNil(model.enqueueFeedback)
    XCTAssertEqual(model.enqueueRevision, 0)
    model.selection = [1]
    model.download()
    let first = try XCTUnwrap(model.enqueueFeedback)
    XCTAssertEqual(first.itemCount, 1)
    XCTAssertEqual(first.id, model.enqueueRevision)
    model.selection = [2, 10]
    model.download()
    let second = try XCTUnwrap(model.enqueueFeedback)
    XCTAssertEqual(second.itemCount, 2)
    XCTAssertNotEqual(first.id, second.id)
    XCTAssertEqual(model.downloadQueue.tasks.count, 2)
    XCTAssertEqual(model.enqueueRevision, 2)
    model.dismissEnqueueFeedback(id: first.id)
    XCTAssertEqual(model.enqueueFeedback?.id, second.id)
    model.dismissEnqueueFeedback(id: second.id)
    XCTAssertNil(model.enqueueFeedback)
    XCTAssertEqual(
      model.enqueueRevision, 2, "Expiring the confirmation must not replay the badge animation")
    try await waitUntil { engine.pending != nil }
    XCTAssertEqual(engine.cancels, 0)
    XCTAssertEqual(engine.maximumActive, 1)
  }

  func testPageSwitchPreservesBrowserStateAndDownloadsContinue() async throws {
    let engine = QueueEngine()
    let model = model(engine)
    defer { model.shutdown() }
    try await connect(model)
    model.open(try XCTUnwrap(model.entries.first { $0.id == 10 }))
    try await waitUntil { !model.busy && model.entries.first?.id == 11 }
    model.setMediaFilter(.images)
    try await waitUntil { !model.filtering }
    model.query = "child"
    model.selection = [11]
    let path = model.path
    let entries = model.visibleEntries.map(\.id)
    let folders = model.folders.map(\.id)
    model.download()
    try await waitUntil { engine.pending?.0.downloadAction == "next" }
    try await waitUntil { model.downloadQueue.tasks.first?.reportURL != nil }
    model.download()
    XCTAssertEqual(model.downloadQueue.pendingTaskCount, 2)
    let requests = engine.requests.count
    model.selectPage(.downloads)
    XCTAssertEqual(model.selectedPage, .downloads)
    XCTAssertTrue(model.fileActionsBlocked)
    model.download()
    XCTAssertEqual(
      model.downloadQueue.tasks.count, 2,
      "Hidden browser selection must not enqueue from the task page")
    model.selectPage(.browser)
    XCTAssertEqual(model.path, path)
    XCTAssertEqual(model.visibleEntries.map(\.id), entries)
    XCTAssertEqual(model.folders.map(\.id), folders)
    XCTAssertEqual(model.query, "child")
    XCTAssertEqual(model.mediaFilter, .images)
    XCTAssertEqual(model.selection, [11])
    XCTAssertEqual(engine.requests.count, requests)
    XCTAssertEqual(engine.cancels, 0)
    XCTAssertFalse(model.fileActionsBlocked)
    engine.finishHeld()
    try await waitUntil { engine.pending?.0.downloadAction == "next" }
    model.selectPage(.downloads)
    engine.finishHeld()
    try await waitUntil {
      model.downloadQueue.tasks[0].state == .completed && engine.pending != nil
    }
    XCTAssertEqual(model.downloadQueue.pendingTaskCount, 1)
    XCTAssertEqual(model.downloadQueue.tasks[1].state, .running)
    XCTAssertEqual(model.selectedPage, .downloads)
    XCTAssertEqual(engine.maximumActive, 1)
  }

  func testTasksPageIsAvailableWithoutDeviceAndStorageReturnsToBrowser() async throws {
    let engine = QueueEngine()
    let model = model(engine)
    defer { model.shutdown() }
    model.selectPage(.downloads)
    XCTAssertEqual(model.selectedPage, .downloads)
    XCTAssertTrue(engine.requests.isEmpty)
    XCTAssertEqual(model.downloadQueue.pendingTaskCount, 0)
    try await connect(model)
    XCTAssertEqual(model.selectedPage, .downloads)
    let requests = engine.requests.count
    model.selectStorage(1)
    XCTAssertEqual(model.selectedPage, .browser)
    XCTAssertEqual(model.entries.count, 3)
    XCTAssertEqual(engine.requests.count, requests)
  }

  func testAddingTasksSnapshotsSelectionDestinationAndHiddenSettingWithoutInterrupting()
    async throws
  {
    let engine = QueueEngine()
    let model = model(engine)
    defer { model.shutdown() }
    try await connect(model)
    model.selection = [1]
    model.setDestination(URL(fileURLWithPath: "/tmp/first-destination"))
    model.download()
    try await waitUntil { engine.pending?.0.downloadAction == "next" }
    XCTAssertFalse(model.fileActionsBlocked)
    model.setSelected(1, selected: false)
    model.setSelected(2, selected: true)
    model.setDestination(URL(fileURLWithPath: "/tmp/second-destination"))
    model.setShowHiddenFiles(true)
    model.download()
    model.setDestination(URL(fileURLWithPath: "/tmp/later-destination"))
    model.selection = [10]
    XCTAssertEqual(model.downloadQueue.tasks.count, 2)
    XCTAssertTrue(model.downloadQueue.tasks[0].filterSummary.contains(L10n.text("不含隐藏文件")))
    XCTAssertTrue(model.downloadQueue.tasks[1].filterSummary.contains(L10n.text("包含隐藏文件")))
    XCTAssertEqual(model.downloadQueue.tasks[1].state, .queued)
    XCTAssertNil(model.downloadQueue.elapsed(for: model.downloadQueue.tasks[1]))
    XCTAssertEqual(engine.cancels, 0)
    engine.finishHeld()
    try await waitUntil { engine.pending?.0.downloadAction == "next" }
    engine.finishHeld()
    try await waitUntil {
      engine.requests.filter { $0.downloadAction == "begin" }.count == 2 && engine.pending != nil
    }
    let begins = engine.requests.filter { $0.downloadAction == "begin" }
    XCTAssertEqual(begins[0].objectIDs, [1])
    XCTAssertEqual(begins[0].destination, "/tmp/first-destination")
    XCTAssertFalse(begins[0].showHiddenFiles)
    XCTAssertEqual(begins[1].objectIDs, [2])
    XCTAssertEqual(begins[1].destination, "/tmp/second-destination")
    XCTAssertTrue(begins[1].showHiddenFiles)
    XCTAssertEqual(engine.maximumActive, 1)
  }

  func testNewDirectoryWaitsForFileBoundaryAndCachedParentNeedsNoUSB() async throws {
    let engine = QueueEngine()
    let model = model(engine)
    defer { model.shutdown() }
    try await connect(model)
    let folder = try XCTUnwrap(model.entries.first { $0.id == 10 })
    model.selection = [1]
    model.download()
    try await waitUntil { engine.pending?.0.downloadAction == "next" }
    model.open(folder)
    XCTAssertTrue(model.busy)
    XCTAssertEqual(engine.requests.filter { $0.operation == "list" }.count, 1)
    engine.finishHeld()
    try await waitUntil { !model.busy && model.entries.first?.id == 11 && engine.pending != nil }
    XCTAssertEqual(
      engine.requests.suffix(3).map { $0.downloadAction ?? $0.operation }, ["next", "list", "next"])
    let requestCount = engine.requests.count
    model.up()
    XCTAssertEqual(model.entries.count, 3)
    XCTAssertEqual(engine.requests.count, requestCount)
    XCTAssertEqual(engine.cancels, 0)
    XCTAssertEqual(engine.maximumActive, 1)
  }

  func testCancellingWaitingTaskDoesNotCancelCurrentFileAndActiveCancelStartsNext() async throws {
    let engine = QueueEngine()
    let model = model(engine)
    defer { model.shutdown() }
    try await connect(model)
    let initialDisconnects = engine.disconnects
    model.selection = [1]
    model.download()
    try await waitUntil { engine.pending != nil }
    let first = model.downloadQueue.tasks[0].id
    model.selection = [2]
    model.download()
    let second = model.downloadQueue.tasks[1].id
    model.downloadQueue.cancel(second)
    XCTAssertEqual(engine.cancels, 0)
    XCTAssertEqual(model.downloadQueue.tasks[1].state, .cancelled)
    model.download()
    let third = model.downloadQueue.tasks[2].id
    model.downloadQueue.cancel(first)
    XCTAssertEqual(model.downloadQueue.tasks[0].state, .cancelling)
    XCTAssertEqual(engine.cancels, 0)
    XCTAssertEqual(engine.pending?.0.downloadID, first.uuidString)
    XCTAssertFalse(
      engine.requests.contains {
        $0.downloadID == first.uuidString && $0.downloadAction == "cancel"
      })
    engine.finishHeld()
    try await waitUntil {
      model.downloadQueue.tasks[0].state == .cancelled
        && engine.pending?.0.downloadID == third.uuidString
    }
    XCTAssertEqual(engine.cancels, 0)
    XCTAssertEqual(engine.disconnects, initialDisconnects)
    XCTAssertEqual(model.downloadQueue.tasks[0].completed, 1)
    XCTAssertEqual(engine.requests.filter { $0.operation == "connect" }.count, 1)
    XCTAssertEqual(
      engine.requests.filter { $0.downloadID == first.uuidString && $0.downloadAction == "next" }
        .count, 1)
    XCTAssertTrue(
      engine.requests.contains {
        $0.downloadID == first.uuidString && $0.downloadAction == "cancel"
      })
    XCTAssertEqual(engine.maximumActive, 1)
    model.downloadQueue.dismissFinished()
    XCTAssertEqual(model.downloadQueue.tasks.map(\.id), [first, second, third])
    model.downloadQueue.removeTask(first)
    model.downloadQueue.removeTask(second)
    XCTAssertEqual(model.downloadQueue.tasks.map(\.id), [third])
  }

  func testTransportFailureDuringGracefulCancelPausesLaterTasks() async throws {
    let engine = QueueEngine()
    let model = model(engine)
    defer { model.shutdown() }
    try await connect(model)
    model.selection = [1]
    model.download()
    try await waitUntil { engine.pending != nil }
    let first = model.downloadQueue.tasks[0].id
    model.download()
    model.downloadQueue.cancel(first)
    engine.finishHeld(failure: true)
    try await waitUntil { model.downloadQueue.tasks[0].state == .failed }
    XCTAssertEqual(model.downloadQueue.tasks[1].state, .paused)
    XCTAssertEqual(model.downloadQueue.tasks[0].error, "USB unavailable")
    XCTAssertEqual(engine.requests.filter { $0.downloadAction == "begin" }.count, 1)
    XCTAssertEqual(engine.cancels, 0)
  }

  func testCancelDuringPlanningWaitsForBeginThenCancelsWithoutReadingFile() async throws {
    let engine = QueueEngine()
    let model = model(engine)
    defer { model.shutdown() }
    try await connect(model)
    engine.holdBegins = true
    model.selection = [1]
    model.download()
    try await waitUntil { engine.pending?.0.downloadAction == "begin" }
    let id = model.downloadQueue.tasks[0].id
    model.downloadQueue.cancel(id)
    XCTAssertEqual(engine.cancels, 0)
    XCTAssertEqual(model.downloadQueue.tasks[0].state, .cancelling)
    engine.finishHeld()
    try await waitUntil { model.downloadQueue.tasks[0].state == .cancelled }
    XCTAssertFalse(engine.requests.contains { $0.downloadAction == "next" })
    XCTAssertTrue(engine.requests.contains { $0.downloadAction == "cancel" })
    XCTAssertTrue(engine.steps.isEmpty)
  }

  func testCancelWhileFinalFileFinishesReportsCompleteWithoutReopeningSession() async throws {
    let engine = QueueEngine()
    let model = model(engine)
    defer { model.shutdown() }
    try await connect(model)
    model.selection = [1]
    model.download()
    try await waitUntil { engine.pending != nil }
    engine.finishHeld()
    try await waitUntil { engine.pending != nil }
    let id = model.downloadQueue.tasks[0].id
    model.downloadQueue.cancel(id)
    engine.finishHeld()
    try await waitUntil { model.downloadQueue.tasks[0].state == .completed }
    XCTAssertEqual(model.downloadQueue.tasks[0].completed, 2)
    XCTAssertEqual(engine.cancels, 0)
    XCTAssertEqual(engine.requests.filter { $0.operation == "connect" }.count, 1)
    XCTAssertFalse(engine.requests.contains { $0.downloadAction == "cancel" })
  }

  func testGracefulCancelIgnoresConflictArrivingFromCurrentFile() async throws {
    let engine = QueueEngine()
    let model = model(engine)
    defer { model.shutdown() }
    try await connect(model)
    model.selection = [1]
    model.download()
    try await waitUntil { engine.pending != nil }
    model.downloadQueue.cancel(model.downloadQueue.tasks[0].id)
    engine.waitingOnNext = true
    engine.finishHeld()
    try await waitUntil { model.downloadQueue.tasks[0].state == .cancelled }
    XCTAssertNil(model.downloadQueue.waitingTask)
    XCTAssertNil(model.downloadQueue.tasks[0].conflict)
    XCTAssertEqual(engine.cancels, 0)
    XCTAssertTrue(engine.requests.contains { $0.downloadAction == "cancel" })
  }

  func testCancelBrowsingWhileDownloadWaitsForChoiceDoesNotInterruptHelper() async throws {
    let engine = QueueEngine()
    let model = model(engine)
    defer { model.shutdown() }
    try await connect(model)
    let folder = try XCTUnwrap(model.entries.first { $0.id == 10 })
    model.selection = [1]
    model.download()
    try await waitUntil { engine.pending != nil }
    engine.waitingOnNext = true
    engine.finishHeld()
    try await waitUntil { model.downloadQueue.waitingTask != nil }
    engine.holdLists = true
    model.open(folder)
    try await waitUntil { engine.pending?.0.operation == "list" }
    model.cancel()
    XCTAssertEqual(engine.cancels, 0)
    XCTAssertEqual(engine.pending?.0.operation, "list")
    engine.finishHeld()
    try await waitUntil { !model.busy }
    XCTAssertNotNil(model.downloadQueue.waitingTask)
    model.downloadQueue.cancel(model.downloadQueue.tasks[0].id)
    try await waitUntil { model.downloadQueue.tasks[0].state == .cancelled }
    XCTAssertEqual(engine.cancels, 0)
  }

  func testStoppingBrowseBeforeBoundaryDoesNotCancelDownloadOrPublishOldListing() async throws {
    let engine = QueueEngine()
    let model = model(engine)
    defer { model.shutdown() }
    try await connect(model)
    let folder = try XCTUnwrap(model.entries.first { $0.id == 10 })
    model.selection = [1]
    model.download()
    try await waitUntil { engine.pending != nil }
    model.open(folder)
    model.cancel()
    XCTAssertEqual(engine.cancels, 0)
    engine.finishHeld()
    try await waitUntil { !model.busy && engine.pending != nil }
    XCTAssertEqual(engine.requests.filter { $0.operation == "list" }.count, 1)
    XCTAssertEqual(model.downloadQueue.tasks[0].state, .running)
    XCTAssertTrue(model.entries.isEmpty)
    XCTAssertEqual(engine.maximumActive, 1)
  }

  func testFailurePausesLaterTasksAndResumeDoesNotRestartFailedTask() async throws {
    let engine = QueueEngine()
    let model = model(engine)
    defer { model.shutdown() }
    try await connect(model)
    model.selection = [1]
    model.download()
    try await waitUntil { engine.pending != nil }
    model.selection = [2]
    model.download()
    engine.finishHeld(failure: true)
    try await waitUntil { model.downloadQueue.tasks[0].state == .failed }
    XCTAssertEqual(model.downloadQueue.pendingTaskCount, 1)
    XCTAssertEqual(model.downloadQueue.tasks[1].state, .paused)
    XCTAssertEqual(engine.requests.filter { $0.downloadAction == "begin" }.count, 1)
    model.downloadQueue.resume()
    try await waitUntil {
      engine.pending?.0.downloadID == model.downloadQueue.tasks[1].id.uuidString
    }
    XCTAssertEqual(engine.requests.filter { $0.downloadAction == "begin" }.count, 2)
    XCTAssertEqual(model.downloadQueue.tasks[0].state, .failed)
  }

  func testCancellingDownloadDuringBrowseUsesJobCancelAfterBrowsingWithoutKillingHelper()
    async throws
  {
    let engine = QueueEngine()
    let model = model(engine)
    defer { model.shutdown() }
    try await connect(model)
    let folder = try XCTUnwrap(model.entries.first { $0.id == 10 })
    model.selection = [1]
    model.download()
    try await waitUntil { engine.pending != nil }
    let first = model.downloadQueue.tasks[0].id
    model.selection = [2]
    model.download()
    engine.holdLists = true
    model.open(folder)
    engine.finishHeld()
    try await waitUntil { engine.pending?.0.operation == "list" }
    model.downloadQueue.cancel(first)
    XCTAssertEqual(engine.cancels, 0)
    XCTAssertEqual(engine.pending?.0.operation, "list")
    engine.finishHeld()
    try await waitUntil {
      !model.busy && model.downloadQueue.tasks[0].state == .cancelled
        && engine.pending?.0.downloadAction == "next"
    }
    XCTAssertTrue(
      engine.requests.contains {
        $0.downloadAction == "cancel" && $0.downloadID == first.uuidString
      })
    XCTAssertEqual(engine.cancels, 0)
    XCTAssertEqual(engine.maximumActive, 1)
  }

  func testInvalidSizeMergeRetiresStagedHelperBeforeResumingQueue() async throws {
    let engine = QueueEngine()
    engine.fastListing = true
    let model = model(engine)
    defer { model.shutdown() }
    try await connect(model)
    XCTAssertTrue(model.hasUnloadedSizes)
    model.selection = [1]
    model.download()
    try await waitUntil { engine.pending != nil }
    model.selection = [2]
    model.download()
    let disconnects = engine.disconnects
    model.loadDirectorySizes()
    engine.finishHeld()
    try await waitUntil { !model.busy && model.downloadQueue.tasks[0].state == .failed }
    XCTAssertGreaterThan(engine.disconnects, disconnects)
    XCTAssertTrue(engine.steps.isEmpty, "The helper must not retain the failed staged job")
    XCTAssertEqual(model.downloadQueue.tasks[1].state, .paused)
    model.downloadQueue.resume()
    try await waitUntil {
      engine.pending?.0.downloadID == model.downloadQueue.tasks[1].id.uuidString
    }
    XCTAssertEqual(engine.requests.filter { $0.downloadAction == "begin" }.count, 2)
    XCTAssertEqual(engine.maximumActive, 1)
  }

  func testDeviceRemovalInvalidatesCurrentTaskAndDifferentPhoneCannotResumeWaitingTask()
    async throws
  {
    let engine = QueueEngine()
    let usb = QueueUSB()
    let model = model(engine, usb: usb)
    defer { model.shutdown() }
    model.demo = false
    model.activate()
    model.connect()
    try await waitUntil { !model.busy && model.entries.count == 3 }
    model.selection = [1]
    model.download()
    try await waitUntil { engine.pending != nil }
    model.selection = [2]
    model.download()
    usb.emit([])
    try await waitUntil { engine.pending == nil }
    XCTAssertTrue(model.storages.isEmpty)
    XCTAssertEqual(model.downloadQueue.tasks[0].state, .failed)
    XCTAssertEqual(model.downloadQueue.tasks[1].state, .paused)
    engine.key = "other-phone"
    usb.emit([43])
    model.connect()
    try await waitUntil { !model.busy && !model.entries.isEmpty }
    let count = engine.requests.count
    model.downloadQueue.resume()
    XCTAssertEqual(model.downloadQueue.tasks[1].state, .paused)
    XCTAssertNotNil(model.downloadQueue.tasks[1].error)
    XCTAssertEqual(engine.requests.count, count)
    let revision = model.enqueueRevision
    model.selection = [1]
    model.download()
    XCTAssertEqual(
      model.enqueueRevision, revision, "Rejected tasks must not publish success feedback")
    XCTAssertNil(model.enqueueFeedback)
    XCTAssertNotNil(model.error)
    XCTAssertEqual(model.downloadQueue.tasks.count, 2)
  }
}
