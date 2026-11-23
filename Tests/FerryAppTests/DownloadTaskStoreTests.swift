import FerryCore
import Foundation
import XCTest

@testable import FerryApp

private final class RecoveryStoreRunner: EngineRunning, @unchecked Sendable {
  @ThreadSafeTestValue var requests: [EngineRequest] = []
  @ThreadSafeTestValue var pending: AsyncThrowingStream<EngineEvent, Error>.Continuation? = nil
  let sessionIdentifier: UUID? = UUID()
  let recoveryPath: String
  private let lock = NSRecursiveLock()
  init(recoveryPath: String) { self.recoveryPath = recoveryPath }
  private func event(_ value: [String: Any]) -> EngineEvent {
    try! JSONDecoder().decode(EngineEvent.self, from: JSONSerialization.data(withJSONObject: value))
  }
  func events(for request: EngineRequest, demo: Bool) -> AsyncThrowingStream<EngineEvent, Error> {
    lock.lock()
    defer { lock.unlock() }
    requests.append(request)
    return AsyncThrowingStream { continuation in
      if request.operation == "connect" {
        continuation.yield(
          event([
            "type": "connected", "deviceKey": "phone", "recoveryIdentity": "stable-phone",
            "storages": [["id": 9, "name": "Storage", "capacity": 100000, "free": 40000]],
          ]))
        continuation.finish()
      } else if request.operation == "list" {
        continuation.yield(event(["type": "listed", "entries": []]))
        continuation.finish()
      } else if request.downloadAction == "next" {
        pending = continuation
      } else {
        continuation.yield(
          event(["type": "yielded", "state": "running", "recoveryPath": recoveryPath]))
        continuation.finish()
      }
    }
  }
  func finish() {
    lock.lock()
    defer { lock.unlock() }
    pending?.yield(event(["type": "completed", "state": "completed"]))
    pending?.finish()
    pending = nil
  }
  func cancel() { XCTFail("Persistent recovery must not interrupt a helper") }
  func disconnect() { finish() }
  func shutdown() { finish() }
}

@MainActor
final class DownloadTaskStoreTests: XCTestCase {
  func testMovedUSBRouteCanQueueRecoveryBehindCurrentPhoneTask() async throws {
    let root = try directory()
    let archive = root.appendingPathComponent("tasks.json")
    let manifest = root.appendingPathComponent("恢复记录.json").path
    let oldRoute = try XCTUnwrap(
      USBDeviceTarget(
        locationID: 0x0110_0000, vendorID: 1, productID: 2, serialNumber: "same-phone"))
    let currentRoute = try XCTUnwrap(
      USBDeviceTarget(
        locationID: 0x0120_0000, vendorID: 1, productID: 2, serialNumber: "same-phone"))
    var savedRequest = try request(root)
    savedRequest.usbTarget = oldRoute
    var saved = DownloadTask(
      id: UUID(), title: "old", state: .cancelled, request: savedRequest, demo: true)
    saved.started = true
    saved.recoveryPath = manifest
    try DownloadTaskStore(url: archive).save([saved])
    let runner = RecoveryStoreRunner(recoveryPath: manifest)
    let controller = DownloadQueueController(
      runner: runner, uptime: { 1 }, destinationIsAvailable: { _ in true }, storeURL: archive)
    defer {
      controller.shutdown()
      runner.shutdown()
    }
    var currentRequest = try request(root)
    currentRequest.usbTarget = currentRoute
    XCTAssertTrue(controller.enqueue(title: "current", request: currentRequest, demo: true))
    try await waitUntil { runner.pending != nil }
    let active = controller.activeTaskID
    controller.recoveryRequest = { request, _ in
      var rebound = request
      rebound.usbTarget = currentRoute
      return rebound
    }
    controller.continueTask(saved.id)
    XCTAssertEqual(controller.tasks[0].state, .queued)
    XCTAssertEqual(controller.tasks[0].request.usbTarget, currentRoute)
    XCTAssertEqual(controller.activeTaskID, active)
    XCTAssertFalse(runner.requests.contains { $0.downloadAction == "recover" })
    runner.finish()
    try await waitUntil { runner.requests.contains { $0.downloadAction == "recover" } }
  }

  func testAppRequiresTheOriginalConnectedPhoneAndRebindsItsStorage() async throws {
    let root = try directory()
    let archive = root.appendingPathComponent("tasks.json")
    let manifest = root.appendingPathComponent("恢复记录.json").path
    var task = DownloadTask(
      id: UUID(), title: "saved", state: .cancelled, request: try request(root), demo: false)
    task.started = true
    task.recoveryPath = manifest
    try DownloadTaskStore(url: archive).save([task])
    let runner = RecoveryStoreRunner(recoveryPath: manifest)
    let domain = "ferry-app-recovery-\(UUID())"
    let preferences = try XCTUnwrap(UserDefaults(suiteName: domain))
    preferences.set(false, forKey: "demo")
    defer { preferences.removePersistentDomain(forName: domain) }
    let model = AppModel(
      runner: runner, preferences: preferences, destinationIsAvailable: { _ in true },
      downloadStoreURL: archive)
    defer { model.shutdown() }
    model.demo = false
    model.downloadQueue.continueTask(task.id)
    XCTAssertTrue(runner.requests.isEmpty, "Offline recovery must not implicitly connect")
    XCTAssertTrue(model.downloadQueue.tasks[0].resumeAvailable)
    model.connect()
    try await waitUntil { !model.busy }
    model.downloadQueue.continueTask(task.id)
    try await waitUntil { runner.pending != nil }
    let recovery = try XCTUnwrap(runner.requests.first { $0.downloadAction == "recover" })
    XCTAssertEqual(recovery.storageID, 9)
    XCTAssertEqual(recovery.sourceStorage?.id, 1, "The original storage fingerprint stays frozen")
    XCTAssertEqual(recovery.recoveryIdentity, "stable-phone")
    XCTAssertEqual(recovery.recoveryPath, manifest)
  }

  private func directory() throws -> URL {
    let result = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ferry-recovery-\(UUID())")
    try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: result) }
    return result
  }

  private func request(_ root: URL) throws -> EngineRequest {
    var value = EngineRequest(
      operation: "download", deviceKey: "phone", storageID: 1, objectIDs: [42],
      destination: root.path, downloadLayout: "direct")
    value.durableRecovery = true
    value.recoveryIdentity = "stable-phone"
    value.sourceDirectory = ["Camera"]
    value.sourceSelection = try JSONDecoder().decode(
      [RemoteEntry].self,
      from: Data(
        """
        [{"id":42,"storageID":1,"name":"photo.jpg","isDirectory":false,"size":1000,"modified":123}]
        """.utf8))
    value.sourceStorage = try JSONDecoder().decode(
      DeviceStorage.self,
      from: Data(
        """
        {"id":1,"name":"Storage","capacity":100000,"free":50000}
        """.utf8))
    return value
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<300 {
      if condition() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Recovery test timed out")
    throw EngineFailure("timeout")
  }

  func testRestartRestoresUnfinishedTasksWithoutStartingAndRequiresManualContinue() async throws {
    let root = try directory()
    let storeURL = root.appendingPathComponent("tasks.json")
    let manifest = root.appendingPathComponent("恢复记录.json").path
    let firstRunner = RecoveryStoreRunner(recoveryPath: manifest)
    let first = DownloadQueueController(runner: firstRunner, uptime: { 1 }, storeURL: storeURL)
    XCTAssertTrue(
      first.enqueue(
        title: "photos", request: try request(root), demo: true, filterSummary: "frozen filters"))
    try await waitUntil { firstRunner.pending != nil }
    let id = try XCTUnwrap(first.tasks.first).id
    first.shutdown()
    firstRunner.shutdown()

    let nextRunner = RecoveryStoreRunner(recoveryPath: manifest)
    let next = DownloadQueueController(
      runner: nextRunner, uptime: { 10 }, destinationIsAvailable: { _ in true }, storeURL: storeURL)
    defer {
      next.shutdown()
      nextRunner.shutdown()
    }
    XCTAssertEqual(next.tasks.map(\.id), [id])
    XCTAssertEqual(next.tasks[0].state, .interrupted)
    XCTAssertEqual(next.tasks[0].filterSummary, "frozen filters")
    XCTAssertTrue(next.tasks[0].resumeAvailable)
    XCTAssertNil(next.tasks[0].resumeToken)
    XCTAssertNil(next.tasks[0].sessionID)
    XCTAssertTrue(nextRunner.requests.isEmpty)
    next.canResume = { _, _ in false }
    next.continueTask(id)
    XCTAssertTrue(nextRunner.requests.isEmpty)
    XCTAssertNotNil(next.tasks[0].error)
    XCTAssertTrue(next.tasks[0].resumeAvailable)
    next.canResume = { _, _ in true }
    next.recoveryRequest = { request, _ in
      var rebound = request
      rebound.storageID = 9
      return rebound
    }
    next.continueTask(id)
    try await waitUntil { nextRunner.pending != nil }
    let recover = try XCTUnwrap(nextRunner.requests.first)
    XCTAssertEqual(recover.downloadAction, "recover")
    XCTAssertEqual(recover.recoveryPath, manifest)
    XCTAssertEqual(recover.storageID, 9)
    XCTAssertEqual(recover.sourceDirectory, ["Camera"])
    XCTAssertEqual(recover.sourceSelection?.first?.name, "photo.jpg")
    nextRunner.finish()
    try await waitUntil { next.tasks[0].state == .completed }
    XCTAssertTrue(try DownloadTaskStore(url: storeURL).load().isEmpty)
  }

  func testQueuedSelectionAndRemovalSurviveRestartWithoutTouchingDownloadedFiles() throws {
    let root = try directory()
    let storeURL = root.appendingPathComponent("tasks.json")
    let file = root.appendingPathComponent("downloaded.jpg")
    try Data("keep".utf8).write(to: file)
    let runner = RecoveryStoreRunner(recoveryPath: root.appendingPathComponent("恢复记录.json").path)
    let controller = DownloadQueueController(runner: runner, uptime: { 1 }, storeURL: storeURL)
    let foreground = controller.reserveForeground()
    var queuedRequest = try request(root)
    queuedRequest.resumeToken = "memory-only-token"
    queuedRequest.downloadAction = "next"
    XCTAssertTrue(controller.enqueue(title: "queued", request: queuedRequest, demo: true))
    XCTAssertEqual(controller.tasks[0].state, .queued)
    controller.shutdown()
    controller.releaseForeground(foreground, connectionUsable: false)
    let next = DownloadQueueController(runner: runner, uptime: { 10 }, storeURL: storeURL)
    defer {
      next.shutdown()
      runner.shutdown()
    }
    let task = try XCTUnwrap(next.tasks.first)
    XCTAssertEqual(task.state, .interrupted)
    XCTAssertFalse(task.started)
    XCTAssertNil(task.request.resumeToken)
    XCTAssertNil(task.request.downloadAction)
    XCTAssertNil(task.recoveryPath)
    XCTAssertTrue(task.hasDurableRecovery)
    XCTAssertTrue(runner.requests.isEmpty)
    next.dismissFinished()
    XCTAssertEqual(next.tasks.count, 1, "Clearing history must preserve unfinished recovery")
    next.removeTask(task.id)
    XCTAssertTrue(next.tasks.isEmpty)
    XCTAssertTrue(try DownloadTaskStore(url: storeURL).load().isEmpty)
    XCTAssertEqual(try Data(contentsOf: file), Data("keep".utf8))
  }

  func testCorruptIndexIsReportedAndNeverOverwrittenOrStarted() throws {
    let root = try directory()
    let url = root.appendingPathComponent("tasks.json")
    let invalid = Data("corrupt recovery index".utf8)
    try invalid.write(to: url)
    let runner = RecoveryStoreRunner(recoveryPath: "unused")
    let controller = DownloadQueueController(runner: runner, uptime: { 1 }, storeURL: url)
    defer {
      controller.shutdown()
      runner.shutdown()
    }
    XCTAssertNotNil(controller.recoveryError)
    XCTAssertFalse(controller.enqueue(title: "new", request: try request(root), demo: true))
    XCTAssertTrue(controller.tasks.isEmpty)
    XCTAssertTrue(runner.requests.isEmpty)
    XCTAssertEqual(try Data(contentsOf: url), invalid)
  }

  func testFailureToSaveDoesNotStartAnUnrecordedTask() throws {
    let root = try directory()
    let parent = root.appendingPathComponent("not-a-directory")
    try Data("keep".utf8).write(to: parent)
    let runner = RecoveryStoreRunner(recoveryPath: "unused")
    let controller = DownloadQueueController(
      runner: runner, uptime: { 1 }, storeURL: parent.appendingPathComponent("tasks.json"))
    defer {
      controller.shutdown()
      runner.shutdown()
    }
    XCTAssertFalse(controller.enqueue(title: "new", request: try request(root), demo: true))
    XCTAssertNotNil(controller.recoveryError)
    XCTAssertTrue(runner.requests.isEmpty)
    XCTAssertTrue(controller.tasks.isEmpty)
    XCTAssertEqual(try Data(contentsOf: parent), Data("keep".utf8))
  }
}
