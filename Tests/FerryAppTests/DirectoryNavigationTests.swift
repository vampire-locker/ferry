import FerryCore
import Foundation
import XCTest

@testable import FerryApp

private struct TestDirectory: Hashable {
  let storage: UInt32
  let parent: UInt32
}

private final class NavigationEngine: EngineRunning, @unchecked Sendable {
  private let callsLock = NSRecursiveLock()
  @ThreadSafeTestValue var requests: [EngineRequest] = []
  @ThreadSafeTestValue var directories: [TestDirectory: [RemoteEntry]] = [:]
  @ThreadSafeTestValue var fastListing = false
  @ThreadSafeTestValue var incompleteSizes = false
  @ThreadSafeTestValue var holdListing = false
  @ThreadSafeTestValue var failAfterListing = false
  @ThreadSafeTestValue var pending: AsyncThrowingStream<EngineEvent, Error>.Continuation? = nil

  private func listing(for request: EngineRequest) -> EngineEvent {
    var entries =
      directories[TestDirectory(storage: request.storageID, parent: request.parentID)] ?? []
    if request.operation == "sizes" {
      let values = entries.filter { !incompleteSizes || $0.isDirectory }.map {
        ["id": Int64($0.id), "size": $0.size]
      }
      let data = try! JSONSerialization.data(withJSONObject: ["type": "sized", "sizes": values])
      return try! JSONDecoder().decode(EngineEvent.self, from: data)
    }
    if fastListing && request.includeSizes == false {
      entries = entries.map { $0.isDirectory ? $0 : $0.replacingSize(-1) }
    }
    let data =
      Data("{\"type\":\"listed\",\"entries\":".utf8)
      + (try! JSONEncoder().encode(entries)) + Data("}".utf8)
    return try! JSONDecoder().decode(EngineEvent.self, from: data)
  }

  func events(for request: EngineRequest, demo: Bool) -> AsyncThrowingStream<EngineEvent, Error> {
    callsLock.lock()
    defer { callsLock.unlock() }
    requests.append(request)
    return AsyncThrowingStream { continuation in
      if request.operation == "connect" {
        let data = Data(
          """
          {"type":"connected","deviceName":"测试手机","deviceKey":"test",
           "storages":[{"id":1,"name":"内部存储","capacity":100,"free":50},
                       {"id":2,"name":"SD 卡","capacity":100,"free":50}]}
          """.utf8)
        continuation.yield(try! JSONDecoder().decode(EngineEvent.self, from: data))
      } else if request.operation == "download" {
        continuation.yield(
          try! JSONDecoder().decode(
            EngineEvent.self,
            from: Data("{\"type\":\"completed\",\"state\":\"completed\"}".utf8)))
      } else if holdListing {
        pending = continuation
        return
      } else {
        continuation.yield(listing(for: request))
        if failAfterListing {
          failAfterListing = false
          continuation.finish(throwing: EngineFailure("测试读取失败"))
          return
        }
      }
      continuation.finish()
    }
  }

  func finishHeldListing() {
    callsLock.lock()
    defer { callsLock.unlock() }
    pending?.yield(listing(for: requests.last!))
    pending?.finish()
    pending = nil
  }

  func cancel() {}
  func shutdown() {
    callsLock.lock()
    defer { callsLock.unlock() }
    pending?.finish()
    pending = nil
  }
}

private final class NavigationUSBMonitor: USBMonitoring {
  var onChange: ((Set<UInt64>) -> Void)?
  var devices: Set<UInt64> = [42]
  func start() throws { onChange?(devices) }
  func stop() {}
  func emit(_ devices: Set<UInt64>) {
    self.devices = devices
    onChange?(devices)
  }
}

@MainActor
final class DirectoryNavigationTests: XCTestCase {
  private func entry(
    _ id: UInt32, _ name: String, folder: Bool = false, storage: UInt32 = 1, modified: Int64 = 0,
    size: Int64 = 0
  ) throws -> RemoteEntry {
    let object: [String: Any] = [
      "id": id, "storageID": storage, "name": name,
      "isDirectory": folder, "size": size, "modified": modified,
    ]
    return try JSONDecoder().decode(
      RemoteEntry.self, from: JSONSerialization.data(withJSONObject: object))
  }

  private func fixture() throws -> NavigationEngine {
    let engine = NavigationEngine()
    engine.directories[TestDirectory(storage: 1, parent: 0)] = [try entry(10, "DCIM", folder: true)]
    engine.directories[TestDirectory(storage: 1, parent: 10)] = [
      try entry(20, "Camera", folder: true)
    ]
    engine.directories[TestDirectory(storage: 1, parent: 20)] = [
      try entry(30, "子目录", folder: true), try entry(40, ".nomedia"), try entry(50, "照片.jpg"),
    ]
    return engine
  }

  private func waitUntil(_ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    while !predicate() {
      if Date() > deadline {
        XCTFail("等待目录操作超时")
        throw EngineFailure("test timeout")
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  private func openCamera(_ model: AppModel) async throws {
    model.connect()
    try await waitUntil { !model.busy }
    model.open(try XCTUnwrap(model.entries.first))
    try await waitUntil { !model.busy }
    model.open(try XCTUnwrap(model.entries.first))
    try await waitUntil { !model.busy }
  }

  func testFastListingSizesAndSizeSortingPreserveSelectionAndSnapshots() async throws {
    let engine = try fixture()
    engine.fastListing = true
    let root = TestDirectory(storage: 1, parent: 0)
    let folder = try entry(10, "folder", folder: true)
    engine.directories[root] = [
      folder, try entry(20, "a.jpg", size: 100), try entry(30, "b.jpg", size: 50),
    ]
    let model = AppModel(runner: engine)
    defer { model.shutdown() }
    model.connect()
    try await waitUntil { !model.busy && !model.filtering }
    XCTAssertEqual(engine.requests.last?.includeSizes, false)
    XCTAssertTrue(model.hasUnloadedSizes)
    XCTAssertTrue(model.entries.filter { !$0.isDirectory }.allSatisfy { $0.size == -1 })
    model.query = "a.jpg"
    model.selectAllVisible()
    engine.holdListing = true
    model.loadDirectorySizes()
    try await waitUntil { engine.pending != nil }
    XCTAssertTrue(model.fileActionsBlocked)
    engine.holdListing = false
    engine.finishHeldListing()
    try await waitUntil { !model.busy && !model.filtering }
    XCTAssertEqual(model.selection, [20])
    XCTAssertEqual(model.query, "a.jpg")
    XCTAssertFalse(model.hasUnloadedSizes)
    XCTAssertEqual(model.visibleEntries.first?.size, 100)
    XCTAssertEqual(engine.requests.filter { $0.operation == "sizes" }.count, 1)
    model.query = ""
    model.open(folder)
    try await waitUntil { !model.busy && !model.filtering }
    let requests = engine.requests.count
    model.up()
    XCTAssertFalse(model.hasUnloadedSizes)
    XCTAssertEqual(engine.requests.count, requests)
    model.sortOrder = [KeyPathComparator(\RemoteEntry.sortSize)]
    try await waitUntil { !model.sorting && !model.filtering }
    XCTAssertEqual(model.visibleEntries.map(\.id), [10, 30, 20])
    XCTAssertEqual(engine.requests.count, requests)
    model.loadDirectory()
    try await waitUntil { !model.busy && !model.filtering }
    XCTAssertEqual(engine.requests.last?.includeSizes, true)
  }

  func testSizeSortLoadsOnceAndRejectsIncompleteUpdateWithoutRetryLoop() async throws {
    for missing in [false, true] {
      let engine = try fixture()
      engine.fastListing = true
      engine.incompleteSizes = missing
      engine.directories[TestDirectory(storage: 1, parent: 0)] = [
        try entry(1, "a.jpg", size: 100), try entry(2, "b.jpg", size: 50),
      ]
      let model = AppModel(runner: engine)
      defer { model.shutdown() }
      model.connect()
      try await waitUntil { !model.busy && !model.filtering }
      model.sortOrder = [KeyPathComparator(\RemoteEntry.sortSize)]
      try await waitUntil { !model.busy && !model.sorting && !model.filtering }
      XCTAssertEqual(engine.requests.filter { $0.operation == "sizes" }.count, 1)
      if missing {
        XCTAssertNotNil(model.error)
        XCTAssertTrue(model.hasUnloadedSizes)
        XCTAssertTrue(model.entries.allSatisfy { $0.size == -1 })
        XCTAssertEqual(model.sortOrder, DirectoryOrdering.defaultOrder)
      } else {
        XCTAssertNil(model.error)
        XCTAssertFalse(model.hasUnloadedSizes)
        XCTAssertEqual(model.visibleEntries.map(\.id), [2, 1])
      }
    }
  }

  func testMonthFiltersConstrainDownloadsPersistOnRefreshAndResetOnNavigation() async throws {
    let engine = try fixture()
    let root = TestDirectory(storage: 1, parent: 0)
    let folder = try entry(10, "DCIM", folder: true)
    let january: Int64 = 1_736_942_400  // 2025-01-15 12:00 UTC, away from timezone boundaries.
    let february: Int64 = 1_739_620_800
    engine.directories[root] = [
      folder, try entry(1, "one.jpg", modified: january),
      try entry(2, "two.jpg", modified: february),
      try entry(3, "old.jpg", modified: 1_705_320_000),
      try entry(4, ".hidden.jpg", modified: january), try entry(5, "unknown.jpg"),
    ]
    engine.directories[TestDirectory(storage: 1, parent: 10)] = [
      try entry(11, "child.jpg", modified: january)
    ]
    let domain = "ferry-month-test-\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: domain)!
    defer { preferences.removePersistentDomain(forName: domain) }
    let model = AppModel(
      runner: engine, preferences: preferences, destinationIsAvailable: { _ in true })
    defer { model.shutdown() }
    model.connect()
    try await waitUntil { !model.busy && !model.filtering }
    model.setMonthFilter(.month(1))
    XCTAssertTrue(model.filtering)
    model.selectAllVisible()
    XCTAssertTrue(model.selectedEntries.isEmpty)
    try await waitUntil { !model.filtering }
    XCTAssertEqual(Set(model.visibleEntries.map(\.id)), [1, 3])
    model.selectAllVisible()
    model.download()
    try await waitUntil {
      engine.requests.last?.operation == "download" && !model.downloading && !model.filtering
    }
    XCTAssertEqual(engine.requests.last?.operation, "download")
    XCTAssertEqual(Set(engine.requests.last?.objectIDs ?? []), [1, 3])
    model.setYearFilter(.year(2025))
    try await waitUntil { !model.filtering }
    XCTAssertEqual(model.visibleEntries.map(\.id), [1])
    model.setShowHiddenFiles(true)
    XCTAssertEqual(Set(model.visibleEntries.map(\.id)), [1, 4])
    XCTAssertTrue(model.monthOptions.contains(.init(filter: .month(1), count: 2)))
    model.setMediaFilter(.videos)
    try await waitUntil { !model.filtering }
    XCTAssertTrue(model.visibleEntries.isEmpty)
    XCTAssertTrue(model.monthOptions.contains(.init(filter: .month(1), count: 0)))
    model.setMediaFilter(.all)
    try await waitUntil { !model.filtering }
    model.setShowHiddenFiles(false)
    engine.directories[root] = [folder, try entry(2, "two.jpg", modified: february)]
    model.loadDirectory()
    try await waitUntil { !model.busy && !model.filtering }
    XCTAssertEqual(model.monthFilter, .month(1))
    XCTAssertTrue(model.visibleEntries.isEmpty)
    XCTAssertTrue(model.monthOptions.contains(.init(filter: .month(1), count: 0)))
    model.clearFileFilters()
    try await waitUntil { !model.filtering }
    XCTAssertEqual(model.monthFilter, .all)
    model.open(folder)
    try await waitUntil { !model.busy && !model.filtering }
    model.setMonthFilter(.month(1))
    try await waitUntil { !model.filtering }
    let requests = engine.requests.count
    model.up()
    XCTAssertEqual(model.monthFilter, .all)
    XCTAssertEqual(engine.requests.count, requests)
    XCTAssertEqual(model.monthOptions.last?.filter, .month(2))
  }

  func testDownloadTasksFreezeBrowserFilterSummariesAtEnqueue() async throws {
    let engine = try fixture()
    engine.directories[TestDirectory(storage: 1, parent: 0)] = [
      try entry(1, "photo.jpg", modified: 1_736_942_400),
      try entry(2, "unknown.jpg"), try entry(3, "clip.mp4", modified: 1_736_942_400),
    ]
    let domain = "ferry-task-filters-\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: domain)!
    defer { preferences.removePersistentDomain(forName: domain) }
    let model = AppModel(
      runner: engine, preferences: preferences, destinationIsAvailable: { _ in true })
    defer { model.shutdown() }
    model.connect()
    try await waitUntil { !model.busy && !model.filtering }
    model.setMediaFilter(.images)
    try await waitUntil { !model.filtering }
    model.setYearFilter(.year(2025))
    try await waitUntil { !model.filtering }
    model.setMonthFilter(.month(1))
    try await waitUntil { !model.filtering }
    model.query = "photo"
    model.setShowHiddenFiles(true)
    model.selectAllVisible()
    model.download()
    let first = try XCTUnwrap(model.downloadQueue.tasks.first)
    XCTAssertEqual(first.request.objectIDs, [1])
    for condition in [
      DirectoryMediaFilter.images.title, L10n.text("修改年份：\(2025)"),
      L10n.text("修改月份：\(1)"), L10n.text("搜索“\("photo")”"), L10n.text("包含隐藏文件"),
    ] {
      XCTAssertTrue(first.filterSummary.contains(condition), first.filterSummary)
    }
    try await waitUntil { !model.downloading }

    model.clearFileFilters()
    try await waitUntil { !model.filtering }
    model.setShowHiddenFiles(false)
    model.selectAllVisible()
    model.download()
    let second = try XCTUnwrap(model.downloadQueue.tasks.last)
    for condition in [
      L10n.text("全部类型"), L10n.text("全部年份"), L10n.text("全部月份"), L10n.text("不含隐藏文件"),
    ] {
      XCTAssertTrue(second.filterSummary.contains(condition), second.filterSummary)
    }
    XCTAssertNotEqual(first.filterSummary, second.filterSummary)
    XCTAssertEqual(model.downloadQueue.tasks.first?.filterSummary, first.filterSummary)
    try await waitUntil { !model.downloading }

    model.setYearFilter(.unknown)
    try await waitUntil { !model.filtering }
    model.selectAllVisible()
    model.download()
    XCTAssertTrue(
      try XCTUnwrap(model.downloadQueue.tasks.last).filterSummary.contains(L10n.text("日期未知")))
    XCTAssertEqual(model.downloadQueue.tasks.last?.request.objectIDs, [2])
    XCTAssertEqual(model.downloadQueue.tasks.first?.filterSummary, first.filterSummary)
  }

  func testReturnToLargeDirectoryRestoresSortedListingWithoutEngineRequest() async throws {
    let engine = try fixture()
    let key = TestDirectory(storage: 1, parent: 20)
    engine.directories[key]! += try (100..<50_100).reversed().map {
      try entry(UInt32($0), "照片-\($0).jpg")
    }
    let model = AppModel(runner: engine)
    defer { model.shutdown() }
    try await openCamera(model)
    let sortedIDs = model.entries.map(\.id)
    XCTAssertEqual(sortedIDs.count, 50_003)
    model.open(try XCTUnwrap(model.entries.first(where: { $0.id == 30 })))
    try await waitUntil { !model.busy }
    XCTAssertTrue(model.entries.isEmpty)
    let requestCount = engine.requests.count
    model.up()
    XCTAssertFalse(model.busy)
    XCTAssertEqual(engine.requests.count, requestCount)
    XCTAssertEqual(model.entries.map(\.id), sortedIDs)
    XCTAssertEqual(model.path, "内部存储 / DCIM / Camera")
    model.up()
    XCTAssertEqual(model.entries.map(\.id), [20])
    model.up()
    XCTAssertEqual(model.entries.map(\.id), [10])
    XCTAssertEqual(engine.requests.count, requestCount)
    // Re-enter from the root, not just back up to an ancestor.
    model.open(try XCTUnwrap(model.entries.first))
    model.open(try XCTUnwrap(model.entries.first))
    XCTAssertFalse(model.busy)
    XCTAssertEqual(model.entries.map(\.id), sortedIDs)
    XCTAssertEqual(engine.requests.count, requestCount)
  }

  func testRecentDirectoryCacheEvictsLeastRecentlyUsedFolders() async throws {
    let engine = try fixture()
    let folders = try (10...15).map { try entry(UInt32($0), "folder-\($0)", folder: true) }
    engine.directories[TestDirectory(storage: 1, parent: 0)] = folders
    for folder in folders {
      engine.directories[TestDirectory(storage: 1, parent: folder.id)] = [
        try entry(folder.id + 100, "file.jpg")
      ]
    }
    let model = AppModel(runner: engine)
    defer { model.shutdown() }
    model.connect()
    try await waitUntil { !model.busy }
    for folder in folders {
      model.open(folder)
      try await waitUntil { !model.busy }
      model.up()
    }
    let count = engine.requests.count
    model.open(folders[3])
    XCTAssertFalse(model.busy)
    model.up()
    XCTAssertEqual(engine.requests.count, count)
    model.open(folders[0])
    try await waitUntil { !model.busy }
    model.up()
    XCTAssertEqual(engine.requests.count, count + 1)
    // Folder 12 was older than the just-revisited folder 13.
    model.open(folders[2])
    try await waitUntil { !model.busy }
    XCTAssertEqual(engine.requests.count, count + 2)
  }

  func testRecentDirectoryCacheBoundsTotalExtraEntries() async throws {
    let engine = try fixture()
    let folders = [try entry(10, "first", folder: true), try entry(20, "second", folder: true)]
    engine.directories[TestDirectory(storage: 1, parent: 0)] = folders
    let files = try (100..<60_100).map { try entry(UInt32($0), "file-\($0).jpg") }
    for folder in folders {
      engine.directories[TestDirectory(storage: 1, parent: folder.id)] = files
    }
    let model = AppModel(runner: engine)
    defer { model.shutdown() }
    model.connect()
    try await waitUntil { !model.busy }
    for folder in folders {
      model.open(folder)
      try await waitUntil { !model.busy && !model.filtering }
      model.up()
    }
    let count = engine.requests.count
    model.open(folders[1])
    XCTAssertFalse(model.busy)
    XCTAssertEqual(engine.requests.count, count)
    model.up()
    model.open(folders[0])
    try await waitUntil { !model.busy && !model.filtering }
    XCTAssertEqual(engine.requests.count, count + 1)
  }

  func testManualRefreshInvalidatesRecentlyVisitedDescendants() async throws {
    let engine = try fixture()
    let model = AppModel(runner: engine)
    defer { model.shutdown() }
    try await openCamera(model)
    model.up()
    model.up()
    engine.directories[TestDirectory(storage: 1, parent: 20)] = [try entry(99, "new.jpg")]
    model.loadDirectory()
    try await waitUntil { !model.busy }
    model.open(try XCTUnwrap(model.entries.first))
    try await waitUntil { !model.busy }
    model.open(try XCTUnwrap(model.entries.first))
    try await waitUntil { !model.busy }
    XCTAssertEqual(model.entries.map(\.id), [99])
  }

  func testRefreshReplacesSnapshotAndCachedReturnUsesCurrentFilters() async throws {
    let domain = "ferry-navigation-test-\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: domain)!
    defer { preferences.removePersistentDomain(forName: domain) }
    let engine = try fixture()
    let model = AppModel(runner: engine, preferences: preferences)
    defer { model.shutdown() }
    try await openCamera(model)
    let child = try XCTUnwrap(model.entries.first(where: { $0.id == 30 }))
    engine.directories[TestDirectory(storage: 1, parent: 20)]!.append(try entry(60, "新增.jpg"))
    let requestCount = engine.requests.count
    model.loadDirectory()
    try await waitUntil { !model.busy }
    XCTAssertEqual(engine.requests.count, requestCount + 1)
    XCTAssertTrue(model.entries.contains { $0.id == 60 })
    model.query = "照片"
    model.selectAllVisible()
    model.open(child)
    try await waitUntil { !model.busy }
    model.setShowHiddenFiles(true)
    model.query = "不匹配"
    model.error = "旧错误"
    model.up()
    XCTAssertFalse(model.busy)
    XCTAssertEqual(engine.requests.count, requestCount + 2)
    XCTAssertTrue(model.query.isEmpty)
    XCTAssertTrue(model.selection.isEmpty)
    XCTAssertNil(model.error)
    XCTAssertEqual(Set(model.visibleEntries.map(\.id)), [30, 40, 50, 60])
    model.setShowHiddenFiles(false)
    XCTAssertFalse(model.visibleEntries.contains { $0.id == 40 })
  }

  func testFailedOrCancelledListingsAreNotCached() async throws {
    for cancelled in [false, true] {
      let engine = try fixture()
      let model = AppModel(runner: engine)
      defer { model.shutdown() }
      try await openCamera(model)
      let child = try XCTUnwrap(model.entries.first(where: { $0.id == 30 }))
      engine.directories[TestDirectory(storage: 1, parent: child.id)] = [
        try entry(88, "failed.jpg")
      ]
      engine.failAfterListing = !cancelled
      engine.holdListing = cancelled
      model.open(child)
      if cancelled {
        try await waitUntil { engine.pending != nil }
        model.cancel()
        engine.holdListing = false
        engine.finishHeldListing()
      }
      try await waitUntil { !model.busy }
      model.sortOrder = [KeyPathComparator(\RemoteEntry.name, order: .reverse)]
      try await waitUntil { !model.sorting && !model.filtering }
      let requestCount = engine.requests.count
      model.up()
      XCTAssertFalse(model.busy)
      XCTAssertNil(model.error)
      XCTAssertEqual(engine.requests.count, requestCount)
      model.open(child)
      try await waitUntil { !model.busy }
      XCTAssertEqual(engine.requests.count, requestCount + 1)
      XCTAssertNil(model.error)
    }
  }

  func testStorageModeAndReconnectClearSnapshots() async throws {
    let engine = try fixture()
    let model = AppModel(runner: engine)
    defer { model.shutdown() }
    try await openCamera(model)
    engine.directories[TestDirectory(storage: 2, parent: 0)] = [
      try entry(10, "SD 卡文件.jpg", storage: 2)
    ]
    model.selectStorage(2)
    try await waitUntil { !model.busy }
    XCTAssertEqual(model.entries.first?.name, "SD 卡文件.jpg")
    engine.directories[TestDirectory(storage: 1, parent: 0)] = [try entry(70, "重读.jpg")]
    model.selectStorage(1)
    try await waitUntil { !model.busy }
    XCTAssertEqual(model.entries.map(\.id), [70])
    engine.directories[TestDirectory(storage: 1, parent: 0)] = [try entry(80, "重连.jpg")]
    model.connect()
    try await waitUntil { !model.busy }
    XCTAssertEqual(model.entries.map(\.id), [80])
    engine.directories[TestDirectory(storage: 1, parent: 0)] = [try entry(90, "演示.jpg")]
    model.changeMode(true)
    XCTAssertTrue(model.entries.isEmpty)
    model.connect()
    try await waitUntil { !model.busy }
    XCTAssertEqual(model.entries.map(\.id), [90])
  }

  func testDisconnectDiscardsAncestorSnapshots() async throws {
    let engine = try fixture()
    let usb = NavigationUSBMonitor()
    let model = AppModel(runner: engine, usbMonitor: usb)
    defer { model.shutdown() }
    model.demo = false
    model.activate()
    try await openCamera(model)
    usb.emit([])
    XCTAssertTrue(model.entries.isEmpty)
    XCTAssertTrue(model.storages.isEmpty)
    usb.emit([43])
    engine.directories[TestDirectory(storage: 1, parent: 0)] = [try entry(70, "新手机.jpg")]
    model.connect()
    try await waitUntil { !model.busy }
    XCTAssertEqual(model.entries.map(\.id), [70])
  }
}
