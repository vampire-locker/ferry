import FerryCore
import Foundation
import XCTest

@testable import FerryApp

private final class SelectionEngine: EngineRunning, @unchecked Sendable {
  private let callsLock = NSRecursiveLock()
  @ThreadSafeTestValue var requests: [EngineRequest] = []
  func events(for request: EngineRequest, demo: Bool) -> AsyncThrowingStream<EngineEvent, Error> {
    callsLock.lock()
    defer { callsLock.unlock() }
    requests.append(request)
    return AsyncThrowingStream { continuation in
      continuation.yield(
        try! JSONDecoder().decode(
          EngineEvent.self,
          from: Data("{\"type\":\"completed\"}".utf8)))
      continuation.finish()
    }
  }
  func cancel() {}
  func shutdown() {}
}

@MainActor
final class BrowserSettingsTests: XCTestCase {
  func testVideoArchiveDefaultsOffPersistsAndFreezesIndependentlyAtEnqueue() throws {
    let domain = "ferry-video-archive-\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: domain)!
    defer { preferences.removePersistentDomain(forName: domain) }
    let model = AppModel(
      runner: SelectionEngine(), preferences: preferences, destinationIsAvailable: { _ in true })
    defer { model.shutdown() }
    XCTAssertFalse(model.archiveVideosByMonth)
    model.entries = try entries()
    model.storageID = 1
    model.selection = [4]
    model.download()
    model.setArchiveVideosByMonth(true)
    model.download()
    XCTAssertEqual(
      model.downloadQueue.tasks.map { $0.request.archiveVideosByMonth }, [false, true])
    XCTAssertFalse(model.downloadQueue.tasks[1].request.archivePhotosByMonth)
    XCTAssertFalse(model.downloadQueue.tasks[1].request.usePhotoCreationDate)
    let reopened = AppModel(
      runner: SelectionEngine(), preferences: preferences, destinationIsAvailable: { _ in true })
    defer { reopened.shutdown() }
    XCTAssertTrue(reopened.archiveVideosByMonth)
    XCTAssertFalse(reopened.archivePhotosByMonth)
    XCTAssertFalse(reopened.usePhotoCreationDate)
    model.setArchiveVideosByMonth(false)
    model.setArchivePhotosByMonth(true)
    XCTAssertTrue(model.downloadQueue.tasks[1].request.archiveVideosByMonth)
    XCTAssertFalse(model.downloadQueue.tasks[1].request.archivePhotosByMonth)
  }
  func testSaveLocationDefaultsToDownloadsAndRemembersConfirmedChoice() throws {
    let domain = "ferry-save-location-\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: domain)!
    defer { preferences.removePersistentDomain(forName: domain) }
    let model = AppModel(runner: SelectionEngine(), preferences: preferences)
    defer { model.shutdown() }
    XCTAssertEqual(model.destination, DownloadDestination.defaultURL)
    XCTAssertNil(preferences.object(forKey: DownloadDestination.preferenceKey))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ferry-destination-\(UUID().uuidString)/照片 备份", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    model.setDestination(directory)
    XCTAssertEqual(preferences.string(forKey: DownloadDestination.preferenceKey), directory.path)
    let reopened = AppModel(runner: SelectionEngine(), preferences: preferences)
    defer { reopened.shutdown() }
    XCTAssertEqual(reopened.destination.path, directory.path)
    reopened.setDestination(URL(string: "https://example.com/photos")!)
    XCTAssertEqual(reopened.destination.path, directory.path)
    XCTAssertEqual(preferences.string(forKey: DownloadDestination.preferenceKey), directory.path)
  }

  func testUnavailableSavedLocationIsRetainedAndRecoversWithoutRedirecting() throws {
    let domain = "ferry-missing-save-location-\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: domain)!
    defer { preferences.removePersistentDomain(forName: domain) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ferry-missing-destination-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("backup", isDirectory: true)
    preferences.set(directory.path, forKey: DownloadDestination.preferenceKey)
    let engine = SelectionEngine()
    let model = AppModel(runner: engine, preferences: preferences)
    defer { model.shutdown() }
    XCTAssertEqual(model.destination.path, directory.path)
    model.entries = try entries()
    model.storageID = 1
    model.selection = [4]
    model.download()
    XCTAssertTrue(model.downloadQueue.tasks.isEmpty)
    XCTAssertTrue(engine.requests.isEmpty, "An unavailable folder must not initialize the engine")
    XCTAssertTrue(try XCTUnwrap(model.error).contains(directory.path))
    XCTAssertNil(model.enqueueFeedback)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    XCTAssertEqual(preferences.string(forKey: DownloadDestination.preferenceKey), directory.path)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    model.download()
    XCTAssertEqual(model.downloadQueue.tasks.count, 1)
    XCTAssertEqual(model.downloadQueue.tasks.first?.request.destination, directory.path)
    XCTAssertNil(model.error)
  }

  func testDestinationAvailabilityRejectsFilesMissingDirectoriesAndDeniedWrites() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ferry-check-destination-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("file.txt")
    try Data("fixture".utf8).write(to: file)
    XCTAssertTrue(DownloadDestination.isAvailable(root))
    XCTAssertFalse(DownloadDestination.isAvailable(file))
    XCTAssertFalse(DownloadDestination.isAvailable(root.appendingPathComponent("missing")))
    let domain = "ferry-readonly-save-location-\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: domain)!
    defer { preferences.removePersistentDomain(forName: domain) }
    let engine = SelectionEngine()
    // Simulate denied write access without relying on the test user's privileges.
    let model = AppModel(
      runner: engine, preferences: preferences, destinationIsAvailable: { _ in false })
    defer { model.shutdown() }
    model.setDestination(root)
    model.entries = try entries()
    model.storageID = 1
    model.selection = [4]
    model.download()
    XCTAssertNotNil(model.error)
    XCTAssertTrue(model.downloadQueue.tasks.isEmpty)
    XCTAssertTrue(engine.requests.isEmpty)
    XCTAssertEqual(model.destination.path, root.path)
  }

  func testMalformedSaveLocationPreferencesUseInitialDefault() {
    let domain = "ferry-invalid-save-location-\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: domain)!
    defer { preferences.removePersistentDomain(forName: domain) }
    for value: Any in ["", "relative/path", "https://example.com/photos", "/bad\0path", 42, Data()]
    {
      preferences.set(value, forKey: DownloadDestination.preferenceKey)
      XCTAssertEqual(DownloadDestination.restore(from: preferences), DownloadDestination.defaultURL)
    }
  }

  func testMonthArchiveDefaultsOffPersistsAndIsIndependentAtEnqueue() throws {
    let domain = "ferry-month-archive-\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: domain)!
    defer { preferences.removePersistentDomain(forName: domain) }
    let model = AppModel(
      runner: SelectionEngine(), preferences: preferences, destinationIsAvailable: { _ in true })
    defer { model.shutdown() }
    XCTAssertFalse(model.archivePhotosByMonth)
    model.entries = try entries()
    model.storageID = 1
    model.selection = [4]
    model.download()
    model.setArchivePhotosByMonth(true)
    model.download()
    XCTAssertEqual(
      model.downloadQueue.tasks.map { $0.request.archivePhotosByMonth }, [false, true])
    XCTAssertFalse(model.downloadQueue.tasks[1].request.usePhotoCreationDate)
    let reopened = AppModel(
      runner: SelectionEngine(), preferences: preferences, destinationIsAvailable: { _ in true })
    defer { reopened.shutdown() }
    XCTAssertTrue(reopened.archivePhotosByMonth)
    XCTAssertFalse(reopened.usePhotoCreationDate)
    model.setArchivePhotosByMonth(false)
    model.setUsePhotoCreationDate(true)
    XCTAssertTrue(model.downloadQueue.tasks[1].request.archivePhotosByMonth)
    XCTAssertFalse(model.downloadQueue.tasks[1].request.usePhotoCreationDate)
  }

  func testPhotoCreationDateDefaultsOffPersistsAndIsFrozenAtEnqueue() throws {
    let domain = "ferry-photo-date-\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: domain)!
    defer { preferences.removePersistentDomain(forName: domain) }
    let model = AppModel(
      runner: SelectionEngine(), preferences: preferences, destinationIsAvailable: { _ in true })
    defer { model.shutdown() }
    XCTAssertFalse(model.usePhotoCreationDate)
    model.entries = try entries()
    model.storageID = 1
    model.selection = [4]
    model.download()
    model.setUsePhotoCreationDate(true)
    model.download()
    XCTAssertEqual(
      model.downloadQueue.tasks.map { $0.request.usePhotoCreationDate }, [false, true])
    let reopened = AppModel(
      runner: SelectionEngine(), preferences: preferences, destinationIsAvailable: { _ in true })
    defer { reopened.shutdown() }
    XCTAssertTrue(reopened.usePhotoCreationDate)
    model.setUsePhotoCreationDate(false)
    XCTAssertTrue(model.downloadQueue.tasks[1].request.usePhotoCreationDate)
  }

  func testDownloadFolderPreferenceDefaultsToDirectAndPersists() async throws {
    let domain = "ferry-save-layout-\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: domain)!
    defer { preferences.removePersistentDomain(forName: domain) }
    let engine = SelectionEngine()
    let model = AppModel(
      runner: engine, preferences: preferences, destinationIsAvailable: { _ in true })
    defer { model.shutdown() }
    XCTAssertFalse(model.createDownloadFolder)
    model.entries = try entries()
    model.storageID = 1
    model.selection = [4]
    model.download()
    model.setCreateDownloadFolder(true)
    XCTAssertEqual(model.downloadQueue.tasks.first?.request.downloadLayout, "direct")
    XCTAssertNotNil(model.downloadQueue.tasks.first?.request.reportDirectory)
    let reopened = AppModel(
      runner: SelectionEngine(), preferences: preferences, destinationIsAvailable: { _ in true })
    defer { reopened.shutdown() }
    XCTAssertTrue(reopened.createDownloadFolder)
    reopened.entries = try entries()
    reopened.storageID = 1
    reopened.selection = [4]
    reopened.download()
    XCTAssertEqual(reopened.downloadQueue.tasks.first?.request.downloadLayout, "folder")
  }

  private func entries() throws -> [RemoteEntry] {
    try JSONDecoder().decode(
      [RemoteEntry].self,
      from: Data(
        """
        [{"id":1,"storageID":1,"name":".cache","isDirectory":true,"size":0,"modified":0},
         {"id":2,"storageID":1,"name":".nomedia","isDirectory":false,"size":0,"modified":0},
         {"id":3,"storageID":1,"name":"Camera","isDirectory":true,"size":0,"modified":0},
         {"id":4,"storageID":1,"name":"照片.jpg","isDirectory":false,"size":20,"modified":0}]
        """.utf8))
  }

  func testDefaultHiddenAndPersistedPreference() throws {
    let domain = "ferry-settings-test-\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: domain)!
    defer { preferences.removePersistentDomain(forName: domain) }
    let first = AppModel(
      runner: SelectionEngine(), preferences: preferences, destinationIsAvailable: { _ in true })
    first.entries = try entries()
    XCTAssertFalse(first.showHiddenFiles)
    XCTAssertEqual(first.visibleEntries.map(\.id), [3, 4])
    XCTAssertEqual(first.hiddenEntryCount, 2)
    first.setShowHiddenFiles(true)
    XCTAssertEqual(first.visibleEntries.count, 4)
    let reopened = AppModel(
      runner: SelectionEngine(), preferences: preferences, destinationIsAvailable: { _ in true })
    reopened.entries = try entries()
    XCTAssertTrue(reopened.showHiddenFiles)
    XCTAssertEqual(reopened.visibleEntries.count, 4)
    reopened.setShowHiddenFiles(false)
    XCTAssertEqual(reopened.visibleEntries.map(\.id), [3, 4])
    first.shutdown()
    reopened.shutdown()
  }

  func testHiddenAndFilteredSelectionsCannotReachBackup() async throws {
    let domain = "ferry-selection-test-\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: domain)!
    defer { preferences.removePersistentDomain(forName: domain) }
    let engine = SelectionEngine()
    let model = AppModel(
      runner: engine, preferences: preferences, destinationIsAvailable: { _ in true })
    defer { model.shutdown() }
    model.entries = try entries()
    model.storageID = 1
    model.selectAllVisible()
    XCTAssertEqual(model.selection, [3, 4])
    model.setShowHiddenFiles(true)
    model.selectAllVisible()
    XCTAssertEqual(model.selection, [1, 2, 3, 4])
    model.setShowHiddenFiles(false)
    XCTAssertEqual(model.selection, [3, 4])
    model.query = "照片"
    XCTAssertEqual(model.selection, [4])
    model.setSelected(1, selected: true)
    XCTAssertEqual(model.selection, [4])
    model.download()
    try await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertEqual(engine.requests.last?.objectIDs, [4])
    XCTAssertEqual(engine.requests.last?.operation, "download")
    XCTAssertEqual(engine.requests.last?.showHiddenFiles, false)
    model.clearSelection()
    XCTAssertTrue(model.selection.isEmpty)
  }

  func testFolderDownloadUsesCurrentHiddenFilesSetting() async throws {
    for enabled in [false, true] {
      let domain = "ferry-download-settings-test-\(UUID().uuidString)"
      let preferences = UserDefaults(suiteName: domain)!
      defer { preferences.removePersistentDomain(forName: domain) }
      let engine = SelectionEngine()
      let model = AppModel(
        runner: engine, preferences: preferences, destinationIsAvailable: { _ in true })
      defer { model.shutdown() }
      model.entries = try entries()
      model.storageID = 1
      model.setShowHiddenFiles(enabled)
      model.query = "Camera"
      model.selectAllVisible()
      model.download()
      try await Task.sleep(nanoseconds: 50_000_000)
      XCTAssertEqual(engine.requests.last?.objectIDs, [3])
      XCTAssertEqual(engine.requests.last?.showHiddenFiles, enabled)
    }
  }

  func testCheckboxesSelectFilesAndFoldersAndBusyStateIsProtected() throws {
    let domain = "ferry-checkbox-test-\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: domain)!
    defer { preferences.removePersistentDomain(forName: domain) }
    let model = AppModel(
      runner: SelectionEngine(), preferences: preferences, destinationIsAvailable: { _ in true })
    defer { model.shutdown() }
    model.entries = try entries()
    model.setSelected(3, selected: true)
    model.setSelected(4, selected: true)
    XCTAssertEqual(model.selection, [3, 4])
    XCTAssertEqual(model.selectedEntries.count, 2)
    model.setSelected(3, selected: false)
    XCTAssertEqual(model.selection, [4])
    model.busy = true
    model.setShowHiddenFiles(true)
    model.setSelected(3, selected: true)
    model.clearSelection()
    XCTAssertFalse(model.showHiddenFiles)
    XCTAssertEqual(model.selection, [4])
    model.busy = false
    model.entries = []
    XCTAssertTrue(model.selection.isEmpty)
  }
}
