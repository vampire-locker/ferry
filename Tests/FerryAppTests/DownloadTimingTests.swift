import FerryCore
import Foundation
import XCTest

@testable import FerryApp

private final class TimingEngine: EngineRunning, @unchecked Sendable {
  private let callsLock = NSRecursiveLock()
  @ThreadSafeTestValue var pending: AsyncThrowingStream<EngineEvent, Error>.Continuation? = nil
  func events(for request: EngineRequest, demo: Bool) -> AsyncThrowingStream<EngineEvent, Error> {
    callsLock.lock()
    defer { callsLock.unlock() }
    return AsyncThrowingStream { pending = $0 }
  }
  func emit(_ event: [String: Any]) throws {
    callsLock.lock()
    defer { callsLock.unlock() }
    pending?.yield(
      try JSONDecoder().decode(
        EngineEvent.self,
        from: JSONSerialization.data(withJSONObject: event)))
  }
  func cancel() {}
  func shutdown() {
    callsLock.lock()
    defer { callsLock.unlock() }
    pending?.finish()
  }
}

private final class TimingUSBMonitor: USBMonitoring {
  var onChange: ((Set<UInt64>) -> Void)?
  var devices: Set<UInt64> = []
  func start() throws { XCTFail("Timing tests must not start USB monitoring") }
  func stop() {}
}

@MainActor
final class DownloadTimingTests: XCTestCase {
  private func waitUntil(_ predicate: () -> Bool) async throws {
    for _ in 0..<200 {
      if predicate() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for synthetic download")
    throw EngineFailure("test timeout")
  }

  func testDownloadTimingFreezesAfterSuccessFailureAndCancellation() async throws {
    for result in ["completed", "failed", "cancelled", "throw"] {
      let clock = ThreadSafeTestValue(wrappedValue: TimeInterval(100))
      let engine = TimingEngine()
      let domain = "ferry-timing-test-\(UUID().uuidString)"
      let preferences = UserDefaults(suiteName: domain)!
      defer { preferences.removePersistentDomain(forName: domain) }
      let model = AppModel(
        runner: engine, usbMonitor: TimingUSBMonitor(),
        preferences: preferences, uptime: { clock.wrappedValue },
        destinationIsAvailable: { _ in true })
      defer { model.shutdown() }
      model.demo = true
      model.entries = try JSONDecoder().decode(
        [RemoteEntry].self,
        from: Data(
          """
          [{"id":1,"storageID":1,"name":"file.txt","isDirectory":false,"size":1000,"modified":0}]
          """.utf8))
      model.storageID = 1
      model.selection = [1]
      model.download()
      XCTAssertEqual(model.downloadElapsed, 0)
      try await waitUntil { engine.pending != nil }
      clock.wrappedValue = 110
      try engine.emit(["type": "progress", "bytes": 0, "totalBytes": 1000])
      try await waitUntil { model.totalBytes == 1000 }
      clock.wrappedValue = 115
      try engine.emit(["type": "progress", "bytes": 250, "totalBytes": 1000])
      try await waitUntil { model.transferred == 250 }
      XCTAssertEqual(model.downloadElapsed, 15)
      XCTAssertEqual(model.downloadRemaining, 15)
      XCTAssertNil(
        model.downloadQueue.averageSpeed(for: try XCTUnwrap(model.downloadQueue.focusedTask)))
      if result == "cancelled" { model.cancel() }
      clock.wrappedValue = 120
      if result == "throw" {
        engine.pending?.finish(throwing: EngineFailure("synthetic failure"))
      } else {
        try engine.emit(["type": result == "completed" ? "completed" : "error", "state": result])
        engine.pending?.finish()
      }
      try await waitUntil { !model.downloading && !model.busy }
      let finished = try XCTUnwrap(model.downloadQueue.focusedTask)
      XCTAssertEqual(model.downloadQueue.averageSpeed(for: finished), 12.5, result)
      clock.wrappedValue = 150
      XCTAssertEqual(model.downloadElapsed, 20, result)
      XCTAssertEqual(model.downloadQueue.averageSpeed(for: finished), 12.5, result)
      XCTAssertNil(model.downloadRemaining, result)
      XCTAssertEqual(model.taskState, result == "throw" ? "failed" : result)
      engine.pending = nil
      model.download()
      XCTAssertEqual(model.downloadElapsed, 0)
      XCTAssertNil(model.downloadRemaining)
      try await waitUntil { engine.pending != nil }
      engine.pending?.finish()
      try await waitUntil { !model.downloading }
    }
  }

  func testAverageSpeedRequiresTerminalStateAndValidTransferData() {
    let controller = DownloadQueueController(runner: TimingEngine(), uptime: { 1000 })
    var task = DownloadTask(
      id: UUID(), title: "Synthetic", request: EngineRequest(operation: "download"), demo: true)
    task.timing.start(at: 100)
    task.timing.finish(at: 120)
    task.transferred = 250
    for state in [DownloadTaskState.queued, .running, .waiting, .cancelling, .paused] {
      task.state = state
      XCTAssertNil(controller.averageSpeed(for: task))
    }
    task.state = .completed
    task.reusedBytes = 250
    XCTAssertNil(controller.averageSpeed(for: task), "Unread skips have no transfer speed")
    task.reusedBytes = 150
    XCTAssertEqual(controller.averageSpeed(for: task), 5, "Unread skips must not inflate speed")
    task.reusedBytes = 0
    for bytes: Int64 in [0, -1] {
      task.transferred = bytes
      XCTAssertNil(controller.averageSpeed(for: task))
    }
    task.transferred = 250
    task.timing = TransferTiming()
    XCTAssertNil(controller.averageSpeed(for: task))
    for end in [100.0, 99, .infinity, .nan] {
      task.timing.start(at: 100)
      task.timing.finish(at: end)
      XCTAssertNil(controller.averageSpeed(for: task))
    }
  }
}
