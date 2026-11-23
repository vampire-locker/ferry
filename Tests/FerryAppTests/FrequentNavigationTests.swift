import FerryCore
import Foundation
import XCTest

@testable import FerryApp

private struct FrequentTestDirectory: Hashable {
  let storage: UInt32
  let parent: UInt32
}

private final class FrequentTestUSB: USBMonitoring {
  var onChange: ((Set<UInt64>) -> Void)?
  var devices: Set<UInt64> = [42]
  let serial: String
  let location: UInt32
  init(serial: String = "verified-phone", location: UInt32 = 0x0210_0000) {
    self.serial = serial
    self.location = location
  }
  var choices: [USBDeviceChoice] {
    devices.map {
      USBDeviceChoice(
        id: $0, name: "Phone",
        target: USBDeviceTarget(
          locationID: location, vendorID: 10, productID: 20, serialNumber: serial))
    }
  }
  func start() throws { onChange?(devices) }
  func stop() {}
  func emit(_ value: Set<UInt64>) {
    devices = value
    onChange?(value)
  }
}

private final class FrequentTestEngine: EngineRunning, @unchecked Sendable {
  typealias Pending = (EngineRequest, AsyncThrowingStream<EngineEvent, Error>.Continuation)
  private let lock = NSRecursiveLock()
  @ThreadSafeTestValue var requests: [EngineRequest] = []
  @ThreadSafeTestValue var directories: [FrequentTestDirectory: [RemoteEntry]] = [:]
  @ThreadSafeTestValue var key = "phone-A"
  @ThreadSafeTestValue var holdParents = Set<UInt32>()
  @ThreadSafeTestValue var pendingList: Pending? = nil
  @ThreadSafeTestValue var pendingDownload: Pending? = nil
  @ThreadSafeTestValue var ignoreCancellation = false
  @ThreadSafeTestValue var cancels = 0
  @ThreadSafeTestValue var disconnects = 0
  @ThreadSafeTestValue var active = 0
  @ThreadSafeTestValue var maximumActive = 0

  private func event(_ value: [String: Any]) -> EngineEvent {
    try! JSONDecoder().decode(EngineEvent.self, from: JSONSerialization.data(withJSONObject: value))
  }
  func events(for request: EngineRequest, demo: Bool) -> AsyncThrowingStream<EngineEvent, Error> {
    lock.lock()
    defer { lock.unlock() }
    requests.append(request)
    active += 1
    maximumActive = max(maximumActive, active)
    return AsyncThrowingStream { continuation in
      if request.operation == "list" && holdParents.contains(request.parentID) {
        pendingList = (request, continuation)
      } else if request.downloadAction == "next" {
        pendingDownload = (request, continuation)
      } else {
        deliver(request, continuation)
      }
    }
  }
  private func deliver(
    _ request: EngineRequest, _ continuation: AsyncThrowingStream<EngineEvent, Error>.Continuation
  ) {
    switch request.operation {
    case "connect":
      continuation.yield(
        event([
          "type": "connected", "deviceKey": key, "deviceName": "Phone",
          "storages": [
            ["id": 1, "name": "Internal", "capacity": 100000, "free": 50000],
            ["id": 2, "name": "SD", "capacity": 100000, "free": 50000],
          ],
        ]))
    case "list":
      let rows =
        directories[FrequentTestDirectory(storage: request.storageID, parent: request.parentID)]
        ?? []
      let encoded = try! JSONEncoder().encode(rows)
      continuation.yield(
        try! JSONDecoder().decode(
          EngineEvent.self,
          from: Data("{\"type\":\"listed\",\"entries\":".utf8) + encoded + Data("}".utf8)))
    case "download":
      if request.downloadAction == "cancel" {
        continuation.yield(event(["type": "completed", "state": "cancelled"]))
      } else {
        continuation.yield(
          event([
            "type": "progress", "bytes": request.downloadAction == "begin" ? 0 : 500,
            "totalBytes": 1000, "total": 2,
          ]))
        continuation.yield(event(["type": "yielded", "state": "running"]))
      }
    default: XCTFail("Unexpected synthetic request")
    }
    active -= 1
    continuation.finish()
  }
  func finishList(failure: Bool = false) {
    lock.lock()
    defer { lock.unlock() }
    guard let (request, continuation) = pendingList else { return }
    pendingList = nil
    if failure {
      active -= 1
      continuation.yield(
        event(["type": "error", "state": "failed", "message": "Synthetic read failure"]))
      continuation.finish()
    } else {
      deliver(request, continuation)
    }
  }
  func finishDownload() {
    lock.lock()
    defer { lock.unlock() }
    guard let (request, continuation) = pendingDownload else { return }
    pendingDownload = nil
    deliver(request, continuation)
  }
  func cancel() {
    lock.lock()
    defer { lock.unlock() }
    cancels += 1
    guard !ignoreCancellation else { return }
    for pending in [pendingList, pendingDownload].compactMap({ $0 }) {
      active -= 1
      pending.1.yield(event(["type": "error", "state": "cancelled"]))
      pending.1.finish()
    }
    pendingList = nil
    pendingDownload = nil
  }
  func disconnect() {
    lock.lock()
    defer { lock.unlock() }
    disconnects += 1
    if pendingList != nil || pendingDownload != nil { cancel() }
  }
  func shutdown() {
    lock.lock()
    defer { lock.unlock() }
    ignoreCancellation = false
    if pendingList != nil || pendingDownload != nil { cancel() }
  }
}

@MainActor
final class FrequentNavigationTests: XCTestCase {
  private func entry(_ id: UInt32, _ name: String, folder: Bool = true) throws -> RemoteEntry {
    try JSONDecoder().decode(
      RemoteEntry.self,
      from: JSONSerialization.data(withJSONObject: [
        "id": id, "storageID": 1, "name": name, "size": folder ? 0 : 500, "isDirectory": folder,
        "modified": 0,
      ]))
  }
  private func engine(offset: UInt32 = 0) throws -> FrequentTestEngine {
    let engine = FrequentTestEngine()
    engine.directories[FrequentTestDirectory(storage: 1, parent: 0)] = [
      try entry(offset + 10, "DCIM"), try entry(offset + 30, "Other"),
      try entry(offset + 50, ".Secrets"),
    ]
    engine.directories[FrequentTestDirectory(storage: 1, parent: offset + 10)] = [
      try entry(offset + 20, "Camera")
    ]
    engine.directories[FrequentTestDirectory(storage: 1, parent: offset + 20)] = [
      try entry(offset + 40, "photo.jpg", folder: false)
    ]
    engine.directories[FrequentTestDirectory(storage: 1, parent: offset + 30)] = []
    engine.directories[FrequentTestDirectory(storage: 1, parent: offset + 50)] = []
    return engine
  }
  private func preferences() -> UserDefaults {
    let domain = "ferry-frequent-test-\(UUID().uuidString)"
    addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: domain) }
    return UserDefaults(suiteName: domain)!
  }
  private func model(
    _ engine: FrequentTestEngine, preferences: UserDefaults,
    usb: FrequentTestUSB = FrequentTestUSB()
  ) -> AppModel {
    AppModel(
      runner: engine, usbMonitor: usb, preferences: preferences,
      destinationIsAvailable: { _ in true })
  }
  private func waitUntil(_ predicate: () -> Bool) async throws {
    for _ in 0..<500 {
      if predicate() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Frequent navigation timed out")
    throw EngineFailure("test timeout")
  }
  private func connect(_ model: AppModel) async throws {
    model.demo = false
    model.activate()
    model.connect()
    try await waitUntil { !model.busy && !model.entries.isEmpty }
  }
  private func openCamera(_ model: AppModel) async throws -> FrequentDirectory {
    model.open(try XCTUnwrap(model.entries.first { $0.name == "DCIM" }))
    try await waitUntil { !model.busy }
    model.open(try XCTUnwrap(model.entries.first { $0.name == "Camera" }))
    try await waitUntil { !model.busy }
    return try XCTUnwrap(model.frequentDirectories.first { $0.components == ["DCIM", "Camera"] })
  }
  private func returnToFreshRoot(_ model: AppModel) async throws {
    model.navigateToFolder(atDepth: 0)
    model.loadDirectory()
    try await waitUntil { !model.busy }
  }

  func testSuccessfulVisitsRankAndCachedShortcutNeedsNoUSBOrRefreshVisit() async throws {
    let engine = try engine()
    let preferences = preferences()
    let model = model(engine, preferences: preferences)
    defer { model.shutdown() }
    try await connect(model)
    let camera = try await openCamera(model)
    model.navigateToFolder(atDepth: 0)
    let count = engine.requests.count
    model.openFrequentDirectory(camera)
    XCTAssertEqual(model.folders.map(\.name), ["DCIM", "Camera"])
    XCTAssertEqual(model.entries.first?.id, 40)
    XCTAssertEqual(engine.requests.count, count)
    XCTAssertEqual(model.frequentDirectories.first?.visits, 2)
    model.openFrequentDirectory(camera)
    XCTAssertEqual(engine.requests.count, count)
    XCTAssertEqual(model.frequentDirectories.first?.visits, 2)
    model.loadDirectory()
    try await waitUntil { !model.busy }
    XCTAssertEqual(model.frequentDirectories.first?.visits, 2)
    let stored = try XCTUnwrap(preferences.data(forKey: AppModel.frequentDirectoriesKey))
    let text = String(decoding: stored, as: UTF8.self)
    XCTAssertFalse(text.contains("parentID"))
    XCTAssertFalse(text.contains("objectID"))
    let before = engine.requests.count
    model.removeFrequentDirectory(camera.id)
    XCTAssertFalse(model.frequentDirectories.contains { $0.id == camera.id })
    XCTAssertEqual(engine.requests.count, before)
    XCTAssertEqual(model.entries.first?.id, 40)
  }

  func testReconnectResolvesNewHandlesAndRetainsAncestorSnapshots() async throws {
    let preferences = preferences()
    let first = try engine()
    let firstModel = model(first, preferences: preferences)
    try await connect(firstModel)
    _ = try await openCamera(firstModel)
    firstModel.shutdown()
    let second = try engine(offset: 100)
    let secondModel = model(
      second, preferences: preferences, usb: FrequentTestUSB(location: 0x0240_0000))
    defer { secondModel.shutdown() }
    try await connect(secondModel)
    let camera = try XCTUnwrap(
      secondModel.frequentDirectories.first { $0.components == ["DCIM", "Camera"] })
    let dcimVisits = secondModel.frequentDirectories.first { $0.components == ["DCIM"] }?.visits
    let before = second.requests.count
    secondModel.openFrequentDirectory(camera)
    XCTAssertTrue(secondModel.busy)
    XCTAssertTrue(secondModel.folders.isEmpty)
    try await waitUntil { !secondModel.busy }
    XCTAssertEqual(secondModel.folders.map(\.id), [110, 120])
    XCTAssertEqual(secondModel.entries.first?.id, 140)
    XCTAssertEqual(second.requests.dropFirst(before).map(\.parentID), [110, 120])
    XCTAssertEqual(secondModel.frequentDirectories.first { $0.id == camera.id }?.visits, 2)
    XCTAssertEqual(
      secondModel.frequentDirectories.first { $0.components == ["DCIM"] }?.visits, dcimVisits)
    let count = second.requests.count
    secondModel.up()
    XCTAssertEqual(second.requests.count, count)
    XCTAssertEqual(secondModel.entries.first?.id, 120)
  }

  func testEvictedShortcutFailureAndCancellationPreserveBrowserAndVisitCount() async throws {
    let engine = try engine()
    let model = model(engine, preferences: preferences())
    defer { model.shutdown() }
    try await connect(model)
    let camera = try await openCamera(model)
    try await returnToFreshRoot(model)
    model.query = "Other"
    model.selection = [30]
    let oldEntries = model.entries
    let visits = model.frequentDirectories.first { $0.id == camera.id }?.visits
    let disconnected = engine.disconnects
    engine.directories[FrequentTestDirectory(storage: 1, parent: 10)] = []
    model.openFrequentDirectory(camera)
    try await waitUntil { !model.busy }
    XCTAssertNotNil(model.error)
    XCTAssertTrue(model.folders.isEmpty)
    XCTAssertEqual(model.entries, oldEntries)
    XCTAssertEqual(model.query, "Other")
    XCTAssertEqual(model.selection, [30])
    XCTAssertEqual(model.frequentDirectories.first { $0.id == camera.id }?.visits, visits)
    XCTAssertEqual(engine.disconnects, disconnected)
    engine.directories[FrequentTestDirectory(storage: 1, parent: 10)] = [try entry(20, "Camera")]
    engine.holdParents = [10]
    model.openFrequentDirectory(camera)
    try await waitUntil { engine.pendingList != nil }
    model.cancel()
    try await waitUntil { !model.busy }
    XCTAssertTrue(model.folders.isEmpty)
    XCTAssertEqual(model.entries, oldEntries)
    XCTAssertEqual(model.query, "Other")
    XCTAssertEqual(model.selection, [30])
    XCTAssertEqual(model.frequentDirectories.first { $0.id == camera.id }?.visits, visits)
    model.openFrequentDirectory(camera)
    try await waitUntil { engine.pendingList != nil }
    engine.finishList(failure: true)
    try await waitUntil { !model.busy }
    XCTAssertTrue(model.folders.isEmpty)
    XCTAssertEqual(model.entries, oldEntries)
    XCTAssertEqual(model.frequentDirectories.first { $0.id == camera.id }?.visits, visits)
  }

  func testShortcutWaitsForCompleteFileAndMissingFolderKeepsDownloadAlive() async throws {
    let engine = try engine()
    let model = model(engine, preferences: preferences())
    defer { model.shutdown() }
    try await connect(model)
    let camera = try await openCamera(model)
    try await returnToFreshRoot(model)
    engine.directories[FrequentTestDirectory(storage: 1, parent: 10)] = []
    model.selection = [30]
    model.download()
    try await waitUntil { engine.pendingDownload != nil }
    let requests = engine.requests.count
    let disconnected = engine.disconnects
    let cancelled = engine.cancels
    model.openFrequentDirectory(camera)
    XCTAssertEqual(engine.requests.count, requests)
    engine.finishDownload()
    try await waitUntil { !model.busy && engine.pendingDownload != nil }
    XCTAssertNotNil(model.error)
    XCTAssertEqual(model.downloadQueue.tasks.first?.state, .running)
    XCTAssertEqual(engine.disconnects, disconnected)
    XCTAssertEqual(engine.cancels, cancelled)
    XCTAssertEqual(engine.maximumActive, 1)
  }

  func testVerifiedDeviceIsolationSessionFallbackAndHiddenPaths() async throws {
    let preferences = preferences()
    let first = try engine()
    let firstModel = model(first, preferences: preferences)
    try await connect(firstModel)
    _ = try await openCamera(firstModel)
    firstModel.navigateToFolder(atDepth: 0)
    firstModel.setShowHiddenFiles(true)
    firstModel.open(try XCTUnwrap(firstModel.entries.first { $0.id == 50 }))
    try await waitUntil { !firstModel.busy }
    let hidden = try XCTUnwrap(firstModel.frequentDirectories.first { $0.name == ".Secrets" })
    firstModel.setShowHiddenFiles(false)
    XCTAssertFalse(firstModel.frequentDirectories.contains { $0.id == hidden.id })
    let count = first.requests.count
    firstModel.openFrequentDirectory(hidden)
    XCTAssertEqual(first.requests.count, count)
    firstModel.shutdown()
    let persisted = preferences.data(forKey: AppModel.frequentDirectoriesKey)
    let other = try engine()
    other.key = "phone-B"
    let otherModel = model(
      other, preferences: preferences, usb: FrequentTestUSB(serial: "other-phone"))
    try await connect(otherModel)
    XCTAssertTrue(otherModel.frequentDirectories.isEmpty)
    otherModel.shutdown()
    let unknown = try engine()
    let unknownModel = model(unknown, preferences: preferences, usb: FrequentTestUSB(serial: ""))
    defer { unknownModel.shutdown() }
    try await connect(unknownModel)
    XCTAssertTrue(unknownModel.frequentDirectories.isEmpty)
    _ = try await openCamera(unknownModel)
    XCTAssertFalse(unknownModel.frequentDirectories.isEmpty)
    unknownModel.connect()
    try await waitUntil { !unknownModel.busy }
    XCTAssertTrue(unknownModel.frequentDirectories.isEmpty)
    XCTAssertEqual(preferences.data(forKey: AppModel.frequentDirectoriesKey), persisted)
  }

  func testUnplugAndReinsertWhileResolvingReschedulesAutomaticConnection() async throws {
    let engine = try engine()
    let usb = FrequentTestUSB()
    let model = model(engine, preferences: preferences(), usb: usb)
    defer { model.shutdown() }
    try await connect(model)
    let camera = try await openCamera(model)
    try await returnToFreshRoot(model)
    engine.holdParents = [10]
    engine.ignoreCancellation = true
    model.openFrequentDirectory(camera)
    try await waitUntil { engine.pendingList != nil }
    usb.emit([])
    engine.directories[FrequentTestDirectory(storage: 1, parent: 0)] = [try entry(110, "DCIM")]
    usb.emit([42])
    engine.finishList()
    try await waitUntil {
      engine.requests.filter { $0.operation == "connect" }.count == 2 && !model.busy
        && model.entries.first?.id == 110
    }
    XCTAssertTrue(model.folders.isEmpty)
    XCTAssertNil(model.error)
    XCTAssertEqual(model.frequentDirectories.first { $0.id == camera.id }?.visits, 1)
  }
}
