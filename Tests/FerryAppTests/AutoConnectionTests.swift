import FerryCore
import Foundation
import XCTest

@testable import FerryApp

private final class FakeUSBMonitor: USBMonitoring {
  var onChange: ((Set<UInt64>) -> Void)?
  var devices: Set<UInt64>
  var starts = 0
  var choices: [USBDeviceChoice] {
    devices.sorted().map { id in
      USBDeviceChoice(
        id: id, name: "Phone \(id)",
        target: USBDeviceTarget(
          locationID: 0x0200_0000 | (UInt32(id % 14 + 1) << 20), vendorID: 10,
          productID: 20, serialNumber: "\(id)"))
    }
  }
  init(_ devices: Set<UInt64> = []) { self.devices = devices }
  func start() throws {
    starts += 1
    onChange?(devices)
  }
  func stop() {}
  func emit(_ devices: Set<UInt64>) {
    self.devices = devices
    onChange?(devices)
  }
}

private final class FakeEngine: EngineRunning, @unchecked Sendable {
  private let callsLock = NSRecursiveLock()
  @ThreadSafeTestValue var requests: [String] = []
  @ThreadSafeTestValue var fullRequests: [EngineRequest] = []
  @ThreadSafeTestValue var cancelCount = 0
  @ThreadSafeTestValue var failConnections = false
  @ThreadSafeTestValue var holdOperation: String? = nil
  @ThreadSafeTestValue var pending: AsyncThrowingStream<EngineEvent, Error>.Continuation? = nil

  private func event(_ object: [String: Any]) -> EngineEvent {
    try! JSONDecoder().decode(
      EngineEvent.self, from: JSONSerialization.data(withJSONObject: object))
  }
  func success(_ operation: String) -> EngineEvent {
    if operation == "connect" {
      return event([
        "type": "connected", "deviceName": "测试手机", "deviceKey": "test",
        "storages": [["id": 1, "name": "内部存储", "capacity": 100, "free": 50]],
      ])
    }
    return event([
      "type": "listed",
      "entries": [
        [
          "id": 10, "storageID": 1, "name": "DCIM",
          "isDirectory": true, "size": 0, "modified": 0,
        ]
      ],
    ])
  }
  func events(for request: EngineRequest, demo: Bool) -> AsyncThrowingStream<EngineEvent, Error> {
    callsLock.lock()
    defer { callsLock.unlock() }
    requests.append(request.operation)
    fullRequests.append(request)
    return AsyncThrowingStream { continuation in
      if holdOperation == request.operation {
        pending = continuation
        return
      }
      if request.operation == "connect" && failConnections {
        continuation.yield(event(["type": "error", "message": "等待手机授权", "state": "failed"]))
      } else {
        continuation.yield(success(request.operation))
      }
      continuation.finish()
    }
  }
  func finishHeld(_ operation: String) {
    callsLock.lock()
    defer { callsLock.unlock() }
    pending?.yield(success(operation))
    pending?.finish()
    pending = nil
  }
  func cancel() {
    callsLock.lock()
    defer { callsLock.unlock() }
    cancelCount += 1
  }
  func shutdown() {
    callsLock.lock()
    defer { callsLock.unlock() }
    pending?.finish()
    pending = nil
  }
}

@MainActor
final class AutoConnectionTests: XCTestCase {
  func testMultiplePhonesRequireSelectionAndRouteAllRequests() async throws {
    let usb = FakeUSBMonitor([42, 43])
    let engine = FakeEngine()
    let model = AppModel(
      runner: engine, usbMonitor: usb, destinationIsAvailable: { _ in true })
    defer { model.shutdown() }
    model.activate()
    XCTAssertEqual(model.usbDevices.count, 2)
    XCTAssertNil(model.selectedUSBDeviceID)
    model.connect()
    XCTAssertTrue(engine.requests.isEmpty)
    model.selectUSBDevice(43)
    model.connect()
    try await waitUntil { !model.entries.isEmpty && !model.busy }
    let target = try XCTUnwrap(usb.choices.first { $0.id == 43 }?.target)
    XCTAssertEqual(engine.requests, ["connect", "list"])
    XCTAssertTrue(engine.fullRequests.allSatisfy { $0.usbTarget == target })
    model.selection = [10]
    model.download()
    try await waitUntil { !model.busy && engine.requests.count == 3 }
    XCTAssertEqual(engine.fullRequests.last?.usbTarget, target)
  }

  func testSwitchingPhonesClearsBrowserAndKeepsOnlySelectedAttachment() async throws {
    let usb = FakeUSBMonitor([42, 43])
    let engine = FakeEngine()
    let model = AppModel(runner: engine, usbMonitor: usb)
    defer { model.shutdown() }
    model.activate()
    model.selectUSBDevice(42)
    model.connect()
    try await waitUntil { !model.entries.isEmpty && !model.busy }
    model.selection = [10]
    model.selectUSBDevice(43)
    model.connect()
    XCTAssertTrue(model.entries.isEmpty)
    XCTAssertTrue(model.selection.isEmpty)
    try await waitUntil { engine.requests.count == 4 && !model.busy }
    XCTAssertEqual(engine.fullRequests.last?.usbTarget, usb.choices.first { $0.id == 43 }?.target)
    usb.emit([42])
    XCTAssertTrue(
      model.storages.isEmpty,
      "Removing selected phone must clear browser even when another phone remains")
    try await Task.sleep(nanoseconds: 1_000_000_000)
    XCTAssertEqual(engine.requests.count, 4, "Must not automatically capture the remaining phone")
  }

  func testRemovingUnselectedPhonePreservesConnection() async throws {
    let usb = FakeUSBMonitor([42, 43])
    let engine = FakeEngine()
    let model = AppModel(runner: engine, usbMonitor: usb)
    defer { model.shutdown() }
    model.activate()
    model.selectUSBDevice(42)
    model.connect()
    try await waitUntil { !model.entries.isEmpty && !model.busy }
    usb.emit([42])
    XCTAssertFalse(model.storages.isEmpty)
    XCTAssertEqual(engine.requests, ["connect", "list"])
  }

  private func waitUntil(timeout: TimeInterval = 3, _ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate() {
      if Date() > deadline {
        XCTFail("等待状态超时")
        throw EngineFailure("test timeout")
      }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
  }

  func testStartupDetectsAlreadyAttachedPhoneAndLoadsRoot() async throws {
    let usb = FakeUSBMonitor([42])
    let engine = FakeEngine()
    let model = AppModel(runner: engine, usbMonitor: usb)
    defer { model.shutdown() }
    model.activate()
    model.activate()
    try await waitUntil { model.entries.count == 1 && !model.busy }
    XCTAssertEqual(usb.starts, 1)
    XCTAssertEqual(engine.requests, ["connect", "list"])
    XCTAssertEqual(model.deviceName, "测试手机")
  }

  func testArrivalAndRemovalUpdateBrowser() async throws {
    let usb = FakeUSBMonitor()
    let engine = FakeEngine()
    let model = AppModel(runner: engine, usbMonitor: usb)
    defer { model.shutdown() }
    model.activate()
    XCTAssertTrue(engine.requests.isEmpty)
    usb.emit([42])
    try await waitUntil { !model.entries.isEmpty && !model.busy }
    usb.emit([])
    XCTAssertTrue(model.entries.isEmpty)
    XCTAssertTrue(model.storages.isEmpty)
    XCTAssertEqual(model.storageID, 0)
    usb.emit([43])
    try await waitUntil { engine.requests.count == 4 && !model.busy }
    XCTAssertEqual(engine.requests, ["connect", "list", "connect", "list"])
  }

  func testUnplugBeforeTaskStartsDoesNotOpenDevice() async throws {
    let usb = FakeUSBMonitor([42])
    let engine = FakeEngine()
    let model = AppModel(runner: engine, usbMonitor: usb)
    defer { model.shutdown() }
    model.activate()
    model.connect()
    usb.emit([])
    try await waitUntil { !model.busy }
    XCTAssertTrue(engine.requests.isEmpty)
    XCTAssertTrue(model.storages.isEmpty)
  }

  func testManualConnectCancelsPendingAutoAttempt() async throws {
    let usb = FakeUSBMonitor([42])
    let engine = FakeEngine()
    let model = AppModel(runner: engine, usbMonitor: usb)
    defer { model.shutdown() }
    model.activate()
    model.connect()
    try await waitUntil { !model.entries.isEmpty && !model.busy }
    try await Task.sleep(nanoseconds: 1_000_000_000)
    XCTAssertEqual(engine.requests, ["connect", "list"])
  }

  func testDetachDuringConnectRejectsStaleSuccessAndDefersNewConnection() async throws {
    let usb = FakeUSBMonitor([42])
    let engine = FakeEngine()
    engine.holdOperation = "connect"
    let model = AppModel(runner: engine, usbMonitor: usb)
    defer { model.shutdown() }
    model.activate()
    try await waitUntil { engine.pending != nil }
    usb.emit([])
    usb.emit([43])
    try await Task.sleep(nanoseconds: 900_000_000)
    XCTAssertEqual(engine.requests, ["connect"])
    XCTAssertEqual(engine.cancelCount, 1)
    engine.holdOperation = nil
    engine.finishHeld("connect")
    try await waitUntil { engine.requests.count == 3 && !model.busy }
    XCTAssertEqual(engine.requests, ["connect", "connect", "list"])
  }

  func testUserCancelStopsRetries() async throws {
    let usb = FakeUSBMonitor([42])
    let engine = FakeEngine()
    engine.holdOperation = "connect"
    let model = AppModel(runner: engine, usbMonitor: usb)
    defer { model.shutdown() }
    model.activate()
    try await waitUntil { engine.pending != nil }
    model.cancel()
    engine.finishHeld("connect")
    try await waitUntil { !model.busy }
    try await Task.sleep(nanoseconds: 1_000_000_000)
    XCTAssertEqual(engine.requests, ["connect"])
    XCTAssertTrue(model.storages.isEmpty)
    XCTAssertEqual(model.status, L10n.text("操作已停止"))
  }

  func testAnotherDeviceDoesNotInterruptDownload() async throws {
    let usb = FakeUSBMonitor([42])
    let engine = FakeEngine()
    let model = AppModel(
      runner: engine, usbMonitor: usb, destinationIsAvailable: { _ in true })
    defer { model.shutdown() }
    model.activate()
    try await waitUntil { !model.entries.isEmpty && !model.busy }
    engine.holdOperation = "download"
    model.selection = [10]
    model.download()
    try await waitUntil { engine.pending != nil }
    usb.emit([42, 43])
    try await Task.sleep(nanoseconds: 1_000_000_000)
    XCTAssertEqual(engine.requests, ["connect", "list", "download"])
    XCTAssertEqual(engine.cancelCount, 0)
    XCTAssertTrue(model.downloading)
  }

  func testShutdownCancelsScheduledRetry() async throws {
    let usb = FakeUSBMonitor([42])
    let engine = FakeEngine()
    engine.failConnections = true
    let model = AppModel(runner: engine, usbMonitor: usb)
    model.activate()
    try await waitUntil { engine.requests.count == 1 && !model.busy }
    model.shutdown()
    try await Task.sleep(nanoseconds: 2_200_000_000)
    XCTAssertEqual(engine.requests, ["connect"])
  }

  func testFailedAutoConnectStopsAfterThreeAttempts() async throws {
    let usb = FakeUSBMonitor([42])
    let engine = FakeEngine()
    engine.failConnections = true
    let model = AppModel(runner: engine, usbMonitor: usb)
    defer { model.shutdown() }
    model.activate()
    try await waitUntil(timeout: 10) { engine.requests.count == 3 && !model.busy }
    try await Task.sleep(nanoseconds: 900_000_000)
    XCTAssertEqual(engine.requests, ["connect", "connect", "connect"])
    XCTAssertEqual(model.status, L10n.text("自动连接未成功，请解锁手机并允许文件访问后手动重试"))
  }

  func testDemoDoesNotStartUSBMonitoring() async throws {
    let usb = FakeUSBMonitor([42])
    let engine = FakeEngine()
    let model = AppModel(runner: engine, usbMonitor: usb)
    defer { model.shutdown() }
    model.demo = true
    model.activate()
    try await waitUntil { !model.entries.isEmpty && !model.busy }
    XCTAssertEqual(usb.starts, 0)
    XCTAssertEqual(engine.requests, ["connect", "list"])
    model.changeMode(false)
    try await waitUntil { engine.requests.count == 4 && !model.busy }
    XCTAssertEqual(usb.starts, 1)
  }
}
