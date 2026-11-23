import AppKit
import FerryCore
import SwiftUI
import XCTest

@testable import FerryApp

@MainActor
final class LocalMediaArchiveToolTests: XCTestCase {
  private func folder() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ferry-archive-tool-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    // Filename fallback works without valid EXIF, no user pictures are used.
    try Data("fixture".utf8).write(to: root.appendingPathComponent("20121209_015.jpg"))
    return root
  }
  private func waitUntil(_ predicate: () -> Bool) async throws {
    for _ in 0..<300 {
      if predicate() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Archive tool timed out")
    throw EngineFailure("timeout")
  }
  func testExplicitApplyAndOptionChangesRequireRescan() async throws {
    let root = try folder()
    let controller = LocalMediaArchiveController()
    defer { controller.shutdown() }
    controller.selectFolder(root)
    try await waitUntil { !controller.isBusy }
    XCTAssertEqual(controller.movingCount, 1)
    XCTAssertTrue(controller.canApply)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("20121209_015.jpg").path))
    controller.setOptions(videos: false)
    XCTAssertNil(controller.plan)
    XCTAssertFalse(controller.canApply)
    controller.scan()
    try await waitUntil { !controller.isBusy }
    controller.apply()
    try await waitUntil { !controller.isBusy }
    XCTAssertEqual(controller.result?.moved, 1, controller.error ?? "")
    XCTAssertFalse(controller.canApply)
    controller.scan()
    try await waitUntil { !controller.isBusy }
    XCTAssertEqual(controller.alreadyCount, 1)
    XCTAssertEqual(controller.movingCount, 0)
    XCTAssertEqual(controller.selectedCount, 0)
    XCTAssertTrue(
      controller.isAllSelected, "Select All must be disabled when nothing is selectable")
  }
  func testMonthChoiceIsRequiredAndBusyToolSelectionIsBlocked() async throws {
    let root = try folder()
    for path in ["2012/12月", "2012/12"] {
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent(path), withIntermediateDirectories: true)
    }
    let model = AppModel()
    defer { model.shutdown() }
    model.selectPage(.tools)
    model.selectLocalTool(.archive)
    model.mediaArchive.selectFolder(root)
    model.selectLocalTool(.dates)
    XCTAssertEqual(model.selectedLocalTool, .archive)
    try await waitUntil { !model.mediaArchive.isBusy }
    XCTAssertFalse(model.mediaArchive.canApply)
    XCTAssertEqual(model.mediaArchive.unresolvedCount, 1)
    model.mediaArchive.choose("../escape", for: "2012/12月")
    XCTAssertEqual(model.mediaArchive.unresolvedCount, 1)
    model.mediaArchive.choose("2012/12", for: "2012/12月")
    XCTAssertTrue(model.mediaArchive.canApply)
    model.selectPage(.downloads)
    model.selectPage(.tools)
    XCTAssertEqual(model.mediaArchive.choices["2012/12月"], "2012/12")
    model.mediaArchive.apply()
    try await waitUntil { !model.mediaArchive.isBusy }
    XCTAssertEqual(model.mediaArchive.result?.moved, 1)
  }
  func testYearFolderPreviewExplainsSkippedYearsAndKeepsMonthsUntouched() async throws {
    let parent = try folder()
    let root = parent.appendingPathComponent("2012")
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("12月"), withIntermediateDirectories: true)
    try FileManager.default.moveItem(
      at: parent.appendingPathComponent("20121209_015.jpg"),
      to: root.appendingPathComponent("20121209_015.jpg"))
    try Data("other year".utf8).write(to: root.appendingPathComponent("20130607_190722.jpg"))
    try Data("organized".utf8).write(to: root.appendingPathComponent("12月/20130607_190722.jpg"))
    let controller = LocalMediaArchiveController()
    defer { controller.shutdown() }
    controller.selectFolder(root)
    try await waitUntil { !controller.isBusy }
    XCTAssertEqual(controller.folderYear, 2012)
    XCTAssertEqual(controller.movingCount, 1)
    XCTAssertEqual(controller.plan?.summary.otherYears, 1)
    XCTAssertTrue(controller.canApply)
    controller.apply()
    try await waitUntil { !controller.isBusy }
    XCTAssertEqual(controller.result?.moved, 1, controller.error ?? "")
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("20130607_190722.jpg").path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("12月/20130607_190722.jpg").path))
  }

  func testPreviewPaginationCoversEveryItemAndResetsWhenPlanChanges() async throws {
    let root = try folder()
    for index in 0..<44 {
      try Data("pagination fixture".utf8).write(
        to: root.appendingPathComponent("20121209_015_copy\(index).jpg"))
    }
    for path in ["2012/12月", "2012/12"] {
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent(path), withIntermediateDirectories: true)
    }
    let controller = LocalMediaArchiveController()
    defer { controller.shutdown() }
    controller.selectFolder(root)
    try await waitUntil { !controller.isBusy }
    XCTAssertEqual(controller.plan?.items.count, 45)
    XCTAssertEqual(controller.previewPageCount, 3)
    XCTAssertEqual(controller.previewPage, 0)
    var allIDs: [String] = []
    for page in 0..<3 {
      controller.showPreviewPage(page)
      XCTAssertEqual(controller.previewItems.count, page == 2 ? 5 : 20)
      allIDs += controller.previewItems.map(\.id)
    }
    XCTAssertEqual(allIDs.count, 45)
    XCTAssertEqual(Set(allIDs), Set(controller.plan?.items.map(\.id) ?? []))
    XCTAssertEqual(controller.previewRange, 40..<45)
    controller.showPreviewPage(3)
    controller.showPreviewPage(-1)
    XCTAssertEqual(controller.previewPage, 2)
    controller.choose("2012/12", for: "2012/12月")
    XCTAssertEqual(controller.previewPage, 2, "Choosing a month folder must not reset the preview")
    let plan = try XCTUnwrap(controller.plan)
    XCTAssertTrue(
      controller.previewItems.allSatisfy {
        plan.destination($0, choices: controller.choices)?.hasPrefix("2012/12/") == true
      })
    XCTAssertEqual(controller.movingCount, 45, "The current page must not limit the archive plan")
    for id in allIDs {
      XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(id).path))
    }
    XCTAssertTrue(
      try FileManager.default.contentsOfDirectory(
        atPath: root.appendingPathComponent("2012/12").path
      ).isEmpty)
    controller.setOptions(videos: false)
    XCTAssertNil(controller.plan)
    XCTAssertEqual(controller.previewPage, 0)
    controller.scan()
    try await waitUntil { !controller.isBusy }
    controller.showPreviewPage(2)
    let next = try folder()
    controller.selectFolder(next)
    try await waitUntil { !controller.isBusy }
    XCTAssertEqual(controller.previewPage, 0)
    XCTAssertEqual(controller.previewPageCount, 1)
    XCTAssertEqual(controller.previewRange, 0..<1)
    let empty = next.appendingPathComponent("empty")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
    controller.selectFolder(empty)
    try await waitUntil { !controller.isBusy }
    controller.showPreviewPage(1)
    XCTAssertEqual(controller.previewPageCount, 0)
    XCTAssertEqual(controller.previewRange, 0..<0)
    XCTAssertTrue(controller.previewItems.isEmpty)
  }

  func testItemPageAndAllSelectionsPersistAcrossNavigationAndOnlySelectedFilesMove() async throws {
    let root = try folder()
    for index in 0..<44 {
      try Data("selection fixture".utf8).write(
        to: root.appendingPathComponent("20121209_015_copy\(index).jpg"))
    }
    let model = AppModel()
    defer { model.shutdown() }
    model.selectPage(.tools)
    model.selectLocalTool(.archive)
    let controller = model.mediaArchive
    controller.selectFolder(root)
    try await waitUntil { !controller.isBusy }
    XCTAssertEqual(controller.selectedCount, 45)
    XCTAssertTrue(controller.isAllSelected)
    controller.selectAll(false)
    controller.selectItem("../outside.jpg", selected: true)
    XCTAssertFalse(controller.canApply)
    XCTAssertEqual(controller.selectedCount, 0)
    controller.selectPage(true)
    XCTAssertEqual(controller.selectedCount, 20)
    XCTAssertTrue(controller.isPageSelected)
    let first = try XCTUnwrap(controller.previewItems.first?.id)
    controller.selectItem(first, selected: false)
    XCTAssertEqual(controller.selectedCount, 19)
    XCTAssertFalse(controller.isPageSelected)
    controller.selectItem(first, selected: true)
    controller.showPreviewPage(1)
    controller.selectPage(true)
    XCTAssertEqual(controller.selectedCount, 40)
    controller.showPreviewPage(2)
    let last = try XCTUnwrap(controller.previewItems.last?.id)
    controller.selectItem(last, selected: true)
    XCTAssertEqual(controller.selectedCount, 41)
    controller.selectPage(false)
    XCTAssertEqual(controller.selectedCount, 40)
    controller.selectAll(true)
    XCTAssertEqual(controller.selectedCount, 45)
    controller.selectAll(false)
    controller.selectItem(first, selected: true)
    controller.selectItem(last, selected: true)
    XCTAssertEqual(controller.selectedCount, 2)
    model.selectLocalTool(nil)
    model.selectPage(.downloads)
    model.selectPage(.tools)
    model.selectLocalTool(.archive)
    XCTAssertEqual(controller.selectedIDs, [first, last])
    XCTAssertEqual(controller.previewPage, 2)
    let plan = try XCTUnwrap(controller.plan)
    let untouched = plan.items.filter { !controller.selectedIDs.contains($0.id) }
    let bytes = try Dictionary(
      uniqueKeysWithValues: untouched.map {
        ($0.id, try Data(contentsOf: root.appendingPathComponent($0.id)))
      })
    controller.apply()
    controller.selectAll(true)
    XCTAssertEqual(controller.selectedIDs, [first, last], "Selection is frozen during execution")
    try await waitUntil { !controller.isBusy }
    XCTAssertEqual(controller.result?.moved, 2, controller.error ?? "")
    XCTAssertEqual(controller.progress.total, 2)
    for item in untouched {
      XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(item.id)), bytes[item.id])
    }
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(
        atPath: root.appendingPathComponent("2012/12月").path
      ).count, 2)
    controller.scan()
    try await waitUntil { !controller.isBusy }
    XCTAssertEqual(controller.selectedCount, 43)
    XCTAssertEqual(controller.alreadyCount, 2)
    let organized = try XCTUnwrap(
      controller.plan?.items.first { $0.relativePath.hasPrefix("2012/12月/") })
    XCTAssertFalse(controller.canSelect(organized.id))
    controller.selectItem(organized.id, selected: true)
    XCTAssertEqual(controller.selectedCount, 43)
    controller.setOptions(videos: false)
    XCTAssertTrue(controller.selectedIDs.isEmpty)
    XCTAssertNil(controller.plan)
  }

  func testUnselectedAmbiguousMonthDoesNotBlockSelectedFilesOrReappearOnDirectoryChoice()
    async throws
  {
    let root = try folder()
    let selected = "20130607_190722.jpg"
    let unselected = "20121209_015.jpg"
    try Data("selected".utf8).write(to: root.appendingPathComponent(selected))
    for path in ["2012/12月", "2012/12"] {
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent(path), withIntermediateDirectories: true)
    }
    let controller = LocalMediaArchiveController()
    defer { controller.shutdown() }
    controller.selectFolder(root)
    try await waitUntil { !controller.isBusy }
    XCTAssertEqual(controller.unresolvedCount, 1)
    controller.selectAll(false)
    controller.selectItem(selected, selected: true)
    XCTAssertEqual(controller.unresolvedCount, 0)
    XCTAssertTrue(controller.canApply)
    controller.choose("2012/12", for: "2012/12月")
    XCTAssertEqual(
      controller.selectedIDs, [selected], "An explicit deselection must survive directory changes")
    controller.scan()
    try await waitUntil { !controller.isBusy }
    controller.selectAll(false)
    controller.selectItem(selected, selected: true)
    controller.apply()
    try await waitUntil { !controller.isBusy }
    XCTAssertEqual(controller.result?.moved, 1, controller.error ?? "")
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent(unselected)), Data("fixture".utf8))
  }

  func testArchivePreviewRendersInLightAndDark() async throws {
    if let language = ProcessInfo.processInfo.environment["FERRY_ARCHIVE_LANGUAGE"] {
      UserDefaults.standard.register(defaults: [L10n.languagePreferenceKey: language])
    }
    _ = NSApplication.shared
    let controller = LocalMediaArchiveController()
    defer { controller.shutdown() }
    let parent = try folder()
    if ProcessInfo.processInfo.environment["FERRY_ARCHIVE_PREVIEW_PAGE"] != nil {
      for index in 0..<44 {
        try Data("pagination fixture".utf8).write(
          to: parent.appendingPathComponent("20121209_015_copy\(index).jpg"))
      }
    }
    if ProcessInfo.processInfo.environment["FERRY_ARCHIVE_YEAR_LAYOUT"] == "1" {
      let root = parent.appendingPathComponent("2012")
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent("12月"), withIntermediateDirectories: true)
      try FileManager.default.moveItem(
        at: parent.appendingPathComponent("20121209_015.jpg"),
        to: root.appendingPathComponent("20121209_015.jpg"))
      try Data("other year".utf8).write(to: root.appendingPathComponent("20130607_190722.jpg"))
      controller.selectFolder(root)
    } else {
      controller.selectFolder(parent)
    }
    try await waitUntil { !controller.isBusy }
    if let page = ProcessInfo.processInfo.environment["FERRY_ARCHIVE_PREVIEW_PAGE"].flatMap(
      Int.init)
    {
      controller.showPreviewPage(page)
      if ProcessInfo.processInfo.environment["FERRY_ARCHIVE_PARTIAL_SELECTION"] == "1" {
        controller.selectAll(false)
        if let item = controller.previewItems.first {
          controller.selectItem(item.id, selected: true)
        }
      }
    }
    let previewWidth: CGFloat =
      ProcessInfo.processInfo.environment["FERRY_ARCHIVE_PREVIEW_PAGE"] == nil ? 900 : 640
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: previewWidth, height: 880),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.appearance = NSAppearance(named: appearance)
      let host = NSHostingView(
        rootView: LocalToolsView(
          selection: .constant(.archive),
          dates: PhotoDateRepairController(), duplicates: DuplicatePhotosController(),
          archive: controller, rename: LocalMediaArchiveController(operation: .renameMedia)
        )
        .environment(\.locale, L10n.locale).tint(ferryAccent))
      window.contentView = host
      defer {
        window.contentView = nil
        window.close()
      }
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(nanoseconds: 30_000_000)
      host.layoutSubtreeIfNeeded()
      if let path = ProcessInfo.processInfo.environment["FERRY_ARCHIVE_SNAPSHOTS"] {
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
          to: folder.appendingPathComponent(
            "archive-\(L10n.languageIdentifier)-\(appearance.rawValue).png"))
      }
    }
  }
}
