import CryptoKit
import FerryCore
import Foundation
import XCTest

@testable import FerryApp

private final class CancelRecordingRunner: EngineRunning, @unchecked Sendable {
  private let lock = NSLock()
  private let engine: EngineRunner
  @ThreadSafeTestValue var requests: [EngineRequest] = []
  @ThreadSafeTestValue var cancels = 0
  @ThreadSafeTestValue var disconnects = 0
  init(executable: URL) { engine = EngineRunner(executable: executable) }
  var sessionIdentifier: UUID? { engine.sessionIdentifier }
  func events(for request: EngineRequest, demo: Bool) -> AsyncThrowingStream<EngineEvent, Error> {
    lock.lock()
    requests.append(request)
    lock.unlock()
    return engine.events(for: request, demo: demo)
  }
  func cancel() {
    cancels += 1
    engine.cancel()
  }
  func disconnect() {
    disconnects += 1
    engine.disconnect()
  }
  func shutdown() { engine.shutdown() }
}

@MainActor
final class DownloadCancelIntegrationTests: XCTestCase {
  func testNewHelperAndRestoredQueueContinueTheOriginalDownload() async throws {
    guard let path = ProcessInfo.processInfo.environment["FERRY_TEST_ENGINE"] else {
      throw XCTSkip("Run scripts/test.sh to provide the synthetic-device helper")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ferry-durable-integration-\(UUID())")
    let destination = directory.appendingPathComponent("output")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = directory.appendingPathComponent("tasks.json")
    let executable = URL(fileURLWithPath: path)
    let oldRunner = CancelRecordingRunner(executable: executable)
    let oldQueue = DownloadQueueController(
      runner: oldRunner, uptime: { ProcessInfo.processInfo.systemUptime }, storeURL: archive)
    var oldClosed = false
    defer {
      if !oldClosed {
        oldQueue.shutdown()
        oldRunner.shutdown()
      }
    }
    var connection: EngineEvent?
    for try await event in oldRunner.events(for: EngineRequest(operation: "connect"), demo: true) {
      if event.type == "connected" { connection = event }
    }
    let key = try XCTUnwrap(connection?.deviceKey)
    var selection: [RemoteEntry] = []
    for try await event in oldRunner.events(
      for: EngineRequest(operation: "list", deviceKey: key, storageID: 1, parentID: 10), demo: true)
    {
      if event.type == "listed" {
        selection = (event.entries ?? []).filter { [101, 102].contains($0.id) }
      }
    }
    var request = EngineRequest(
      operation: "download", deviceKey: key, storageID: 1, parentID: 10, objectIDs: [101, 102],
      destination: destination.path, downloadLayout: "direct",
      reportDirectory: directory.appendingPathComponent("reports").path)
    request.durableRecovery = true
    request.recoveryIdentity = connection?.recoveryIdentity
    request.sourceDirectory = ["旅行记录"]
    request.sourceSelection = selection
    request.sourceStorage = connection?.storages?.first
    XCTAssertTrue(
      oldQueue.enqueue(
        title: "recovery", request: request, demo: true, filterSummary: "frozen filters"))
    try await waitUntil { oldRunner.requests.contains { $0.downloadAction == "next" } }
    let id = try XCTUnwrap(oldQueue.tasks.first).id
    oldQueue.cancel(id)
    try await waitUntil { oldQueue.tasks.first?.state == .cancelled }
    XCTAssertEqual(oldQueue.tasks[0].completed, 1)
    XCTAssertNotNil(oldQueue.tasks[0].recoveryPath)
    let completedFile = destination.appendingPathComponent(selection[0].name)
    let bytes = try Data(contentsOf: completedFile)
    let attributes = try FileManager.default.attributesOfItem(atPath: completedFile.path)
    let oldSession = oldRunner.sessionIdentifier
    oldQueue.shutdown()
    oldRunner.shutdown()
    // Drain the serial runner queue after shutdown, so the previous helper
    // has exited before the new helper is launched. This request cannot start.
    do {
      for try await _ in oldRunner.events(for: EngineRequest(operation: "list"), demo: true) {}
    } catch {}
    oldClosed = true

    let nextRunner = CancelRecordingRunner(executable: executable)
    let nextQueue = DownloadQueueController(
      runner: nextRunner, uptime: { ProcessInfo.processInfo.systemUptime }, storeURL: archive)
    defer {
      nextQueue.shutdown()
      nextRunner.shutdown()
    }
    XCTAssertEqual(nextQueue.tasks.map(\.id), [id])
    XCTAssertEqual(nextQueue.tasks[0].state, .interrupted)
    XCTAssertEqual(nextQueue.tasks[0].filterSummary, "frozen filters")
    XCTAssertTrue(nextRunner.requests.isEmpty, "Loading a queue must never connect or transfer")
    for try await _ in nextRunner.events(for: EngineRequest(operation: "connect"), demo: true) {}
    XCTAssertNotEqual(nextRunner.sessionIdentifier, oldSession)
    nextQueue.continueTask(id)
    try await waitUntil {
      nextQueue.tasks[0].state == .completed || nextQueue.tasks[0].state == .failed
    }
    XCTAssertEqual(nextQueue.tasks[0].state, .completed, nextQueue.tasks[0].error ?? "")
    XCTAssertEqual(nextQueue.tasks[0].reusedBytes, Int64(bytes.count))
    XCTAssertEqual(nextRunner.requests.filter { $0.downloadAction == "recover" }.count, 1)
    XCTAssertEqual(nextRunner.requests.filter { $0.operation == "connect" }.count, 1)
    XCTAssertEqual(try Data(contentsOf: completedFile), bytes)
    let after = try FileManager.default.attributesOfItem(atPath: completedFile.path)
    XCTAssertEqual(
      attributes[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
    XCTAssertEqual(attributes[.modificationDate] as? Date, after[.modificationDate] as? Date)
    XCTAssertTrue(try DownloadTaskStore(url: archive).load().isEmpty)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted(),
      selection.map(\.name).sorted())
  }

  func testCancelFinishesCurrentDemoFileThenRunsNewTaskOnHealthyEngine() async throws {
    guard let path = ProcessInfo.processInfo.environment["FERRY_TEST_ENGINE"] else {
      throw XCTSkip("Run scripts/test.sh to provide the synthetic-device helper")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ferry-graceful-cancel-\(UUID().uuidString)")
    let first = directory.appendingPathComponent("first")
    let second = directory.appendingPathComponent("second")
    for folder in [first, second] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(at: directory) }
    let runner = CancelRecordingRunner(executable: URL(fileURLWithPath: path))
    let controller = DownloadQueueController(
      runner: runner, uptime: { ProcessInfo.processInfo.systemUptime })
    defer {
      controller.shutdown()
      runner.shutdown()
    }
    var deviceKey: String?
    for try await event in runner.events(for: EngineRequest(operation: "connect"), demo: true) {
      if event.type == "connected" { deviceKey = event.deviceKey }
    }
    let key = try XCTUnwrap(deviceKey)
    let reports = directory.appendingPathComponent("reports").path
    XCTAssertTrue(
      controller.enqueue(
        title: "first",
        request: EngineRequest(
          operation: "download", deviceKey: key, storageID: 1, objectIDs: [101, 102],
          destination: first.path,
          downloadLayout: "direct", reportDirectory: reports), demo: true))
    try await waitUntil { runner.requests.contains { $0.downloadAction == "next" } }
    let firstID = controller.tasks[0].id
    controller.cancel(firstID)
    XCTAssertTrue(
      controller.enqueue(
        title: "second",
        request: EngineRequest(
          operation: "download", deviceKey: key, storageID: 1, objectIDs: [103],
          destination: second.path,
          downloadLayout: "direct", reportDirectory: reports), demo: true))
    try await waitUntil {
      controller.tasks.count == 2 && controller.tasks.allSatisfy { $0.state.isTerminal }
    }
    XCTAssertEqual(controller.tasks.map(\.state), [.cancelled, .completed])
    XCTAssertEqual(controller.tasks[0].completed, 1)
    XCTAssertEqual(runner.cancels, 0)
    XCTAssertEqual(runner.disconnects, 0)
    XCTAssertEqual(runner.requests.filter { $0.operation == "connect" }.count, 1)
    XCTAssertEqual(
      runner.requests.filter { $0.downloadID == firstID.uuidString && $0.downloadAction == "next" }
        .count, 1)
    XCTAssertTrue(
      runner.requests.contains {
        $0.downloadID == firstID.uuidString && $0.downloadAction == "cancel"
      })
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: first.appendingPathComponent("记录-101.txt").path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: first.appendingPathComponent("记录-102.txt").path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: second.appendingPathComponent("记录-103.txt").path))
    let originalOutput = try XCTUnwrap(controller.tasks[0].output)
    let originalReport = controller.tasks[0].reportURL
    let completedFile = first.appendingPathComponent("记录-101.txt")
    let originalBytes = try Data(contentsOf: completedFile)
    let originalAttributes = try FileManager.default.attributesOfItem(atPath: completedFile.path)
    let sessionID = runner.sessionIdentifier
    XCTAssertTrue(controller.tasks[0].resumeAvailable)
    controller.continueTask(firstID)
    try await waitUntil { controller.tasks[0].state.isTerminal }
    XCTAssertEqual(controller.tasks[0].state, .completed, controller.tasks[0].error ?? "")
    XCTAssertEqual(controller.tasks[0].output, originalOutput)
    XCTAssertEqual(controller.tasks[0].reportURL, originalReport)
    XCTAssertEqual(controller.tasks[0].completed, 2)
    XCTAssertEqual(controller.tasks[0].reusedBytes, Int64(originalBytes.count))
    XCTAssertEqual(runner.sessionIdentifier, sessionID)
    XCTAssertEqual(runner.cancels, 0)
    XCTAssertEqual(runner.disconnects, 0)
    XCTAssertEqual(try Data(contentsOf: completedFile), originalBytes)
    let finalAttributes = try FileManager.default.attributesOfItem(atPath: completedFile.path)
    XCTAssertEqual(
      originalAttributes[.systemFileNumber] as? NSNumber,
      finalAttributes[.systemFileNumber] as? NSNumber)
    XCTAssertEqual(
      originalAttributes[.modificationDate] as? Date, finalAttributes[.modificationDate] as? Date)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: first.path).sorted(),
      ["记录-101.txt", "记录-102.txt"])
    XCTAssertEqual(runner.requests.filter { $0.downloadAction == "resume" }.count, 1)
    XCTAssertEqual(runner.requests.filter { $0.operation == "connect" }.count, 1)
    for task in controller.tasks {
      let reportURL = try XCTUnwrap(task.reportURL)
      let report = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(contentsOf: reportURL)) as? [String: Any])
      let items = try XCTUnwrap(report["items"] as? [[String: Any]])
      for item in items where item["state"] as? String == "completed" {
        let relative = try XCTUnwrap(item["path"] as? String)
        let data = try Data(contentsOf: XCTUnwrap(task.output).appendingPathComponent(relative))
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, item["sha256"] as? String)
      }
      let output = try XCTUnwrap(task.output)
      let leftovers = try FileManager.default.contentsOfDirectory(atPath: output.path).filter {
        $0.hasPrefix(".ferry-")
      }
      XCTAssertTrue(leftovers.isEmpty)
    }
  }

  private func waitUntil(_ predicate: () -> Bool) async throws {
    for _ in 0..<1000 {
      if predicate() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Synthetic cancellation integration timed out")
    throw EngineFailure("test timeout")
  }
}
