import AppKit
import CoreGraphics
import FerryCore
import ImageIO
import SwiftUI
import XCTest

@testable import FerryApp

private final class MediaRenameRunner: EngineRunning, @unchecked Sendable {
  func events(for request: EngineRequest, demo: Bool) -> AsyncThrowingStream<EngineEvent, Error> {
    XCTFail("Local rename tools must not request a phone")
    return AsyncThrowingStream { $0.finish() }
  }
  func cancel() {}
  func shutdown() {}
}
private final class MediaRenameUSB: USBMonitoring {
  var devices: Set<UInt64> = [1]
  var onChange: ((Set<UInt64>) -> Void)?
  func start() throws { onChange?(devices) }
  func stop() {}
}

@MainActor
final class MediaRenameToolTests: XCTestCase {
  private func fixture(conflict: Bool = false, filenameFallback: Bool = false) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ferry-rename-tool-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    let provider = try XCTUnwrap(CGDataProvider(data: Data([200, 80, 100, 255]) as CFData))
    let image = try XCTUnwrap(
      CGImage(
        width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let noMetadataName = filenameFallback ? "IMG_20130525_120612.jpg" : "no-date.jpg"
    for name in ["photo.jpg", conflict ? "IMG_20151101_145451.jpg" : "drawing.png", noMetadataName]
    {
      let file = root.appendingPathComponent(name)
      let output = try XCTUnwrap(
        CGImageDestinationCreateWithURL(
          file as CFURL, (name.hasSuffix(".png") ? "public.png" : "public.jpeg") as CFString, 1, nil
        ))
      let properties: [CFString: Any] =
        name == noMetadataName
        ? [:]
        : [
          kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: "2015:11:01 14:54:51"
          ]
        ]
      CGImageDestinationAddImage(output, image, properties as CFDictionary)
      XCTAssertTrue(CGImageDestinationFinalize(output))
    }
    return root
  }
  private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<300 {
      if condition() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Media rename timed out")
    throw EngineFailure("timeout")
  }

  func testPreviewSelectionAndExecutionKeepUnselectedFilesAndDatesUntouched() async throws {
    let root = try fixture()
    let controller = LocalMediaArchiveController(operation: .renameMedia)
    defer { controller.shutdown() }
    let untouched = root.appendingPathComponent("drawing.png")
    let bytes = try Data(contentsOf: untouched)
    let dates = try FileManager.default.attributesOfItem(atPath: untouched.path)
    controller.selectFolder(root)
    try await waitUntil { !controller.isBusy }
    XCTAssertTrue(controller.isRenaming)
    XCTAssertEqual(controller.plan?.summary.noDate, 1)
    XCTAssertEqual(controller.selectedCount, 2)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("photo.jpg").path))
    controller.selectAll(false)
    controller.selectItem("photo.jpg", selected: true)
    controller.apply()
    try await waitUntil { !controller.isBusy }
    XCTAssertEqual(controller.result?.moved, 1, controller.error ?? "")
    XCTAssertEqual(controller.result?.datesUpdated, 1)
    XCTAssertEqual(try Data(contentsOf: untouched), bytes)
    let after = try FileManager.default.attributesOfItem(atPath: untouched.path)
    XCTAssertEqual(dates[.creationDate] as? Date, after[.creationDate] as? Date)
    XCTAssertEqual(dates[.modificationDate] as? Date, after[.modificationDate] as? Date)
    controller.scan()
    try await waitUntil { !controller.isBusy }
    XCTAssertEqual(controller.selectedCount, 1)
    XCTAssertEqual(controller.alreadyCount, 1)
    XCTAssertFalse(controller.canSelect("IMG_20151101_145451.jpg"))
  }

  func testFilenameFallbackIsSelectedAndCanSynchronizeDatesWithoutRenaming() async throws {
    let root = try fixture(filenameFallback: true)
    let controller = LocalMediaArchiveController(operation: .renameMedia)
    defer { controller.shutdown() }
    let name = "IMG_20130525_120612.jpg"
    let file = root.appendingPathComponent(name)
    let bytes = try Data(contentsOf: file)
    let before = try FileManager.default.attributesOfItem(atPath: file.path)
    controller.selectFolder(root)
    try await waitUntil { !controller.isBusy }
    XCTAssertEqual(controller.plan?.summary.noDate, 0)
    XCTAssertEqual(controller.selectedCount, 3)
    let item = try XCTUnwrap(controller.plan?.items.first { $0.id == name })
    XCTAssertEqual(item.source, .filename)
    XCTAssertEqual(item.source.title, L10n.text("文件名日期"))
    XCTAssertEqual(item.targetName, name)
    let scanned = try FileManager.default.attributesOfItem(atPath: file.path)
    for key in [FileAttributeKey.creationDate, .modificationDate] {
      XCTAssertEqual(scanned[key] as? Date, before[key] as? Date)
    }
    controller.selectAll(false)
    controller.selectItem(name, selected: true)
    controller.apply()
    try await waitUntil { !controller.isBusy }
    XCTAssertEqual(controller.result?.moved, 0)
    XCTAssertEqual(controller.result?.datesUpdated, 1)
    XCTAssertEqual(controller.result?.failed, 0)
    XCTAssertEqual(try Data(contentsOf: file), bytes)
    controller.scan()
    try await waitUntil { !controller.isBusy }
    XCTAssertFalse(controller.canSelect(name))
    XCTAssertEqual(controller.alreadyCount, 1)
  }

  func testFourthToolKeepsItsStateAndBusyMutualExclusionWithoutPhoneRequests() async throws {
    let model = AppModel(runner: MediaRenameRunner(), usbMonitor: MediaRenameUSB())
    defer { model.shutdown() }
    model.demo = false
    model.selectPage(.tools)
    model.activate()
    model.selectLocalTool(.rename)
    model.mediaRename.selectFolder(try fixture())
    model.selectLocalTool(.archive)
    XCTAssertEqual(model.selectedLocalTool, .rename)
    model.selectLocalTool(nil)
    model.selectLocalTool(.rename)
    try await waitUntil { !model.mediaRename.isBusy }
    model.mediaRename.selectAll(false)
    model.mediaRename.selectItem("photo.jpg", selected: true)
    model.selectLocalTool(nil)
    model.selectPage(.downloads)
    model.selectPage(.tools)
    model.selectLocalTool(.rename)
    XCTAssertEqual(model.mediaRename.selectedIDs, ["photo.jpg"])
    XCTAssertNil(model.mediaArchive.plan)
    try await Task.sleep(nanoseconds: 700_000_000)
  }

  func testRenameConflictWaitCanSkipAndStopWithoutChangingSourceDates() async throws {
    let root = try fixture(conflict: true)
    let controller = LocalMediaArchiveController(operation: .renameMedia)
    defer { controller.shutdown() }
    let before = try FileManager.default.attributesOfItem(
      atPath: root.appendingPathComponent("photo.jpg").path)
    controller.selectFolder(root)
    try await waitUntil { !controller.isBusy }
    controller.selectAll(false)
    controller.selectItem("photo.jpg", selected: true)
    controller.apply()
    try await waitUntil { controller.conflict != nil }
    let question = try XCTUnwrap(controller.conflict)
    controller.resolve(.init(id: question.id, choice: "skip"))
    try await waitUntil { !controller.isBusy }
    XCTAssertEqual(controller.result?.skipped, 1)
    XCTAssertEqual(controller.result?.datesUpdated, 0)
    let after = try FileManager.default.attributesOfItem(
      atPath: root.appendingPathComponent("photo.jpg").path)
    XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
    controller.scan()
    try await waitUntil { !controller.isBusy }
    controller.selectAll(false)
    controller.selectItem("photo.jpg", selected: true)
    controller.apply()
    try await waitUntil { controller.conflict != nil }
    controller.cancel()
    try await waitUntil { !controller.isBusy }
    XCTAssertEqual(controller.result?.cancelled, true)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("photo.jpg").path))
  }

  func testHomeRenamePreviewAndConflictRenderInLightAndDark() async throws {
    if let language = ProcessInfo.processInfo.environment["FERRY_RENAME_LANGUAGE"] {
      UserDefaults.standard.register(defaults: [L10n.languagePreferenceKey: language])
    }
    _ = NSApplication.shared
    let model = AppModel(runner: MediaRenameRunner(), usbMonitor: MediaRenameUSB())
    defer { model.shutdown() }
    model.mediaRename.selectFolder(try fixture(conflict: true, filenameFallback: true))
    try await waitUntil { !model.mediaRename.isBusy }
    model.mediaRename.selectAll(false)
    model.mediaRename.selectItem("photo.jpg", selected: true)
    try await render(
      LocalToolsView(
        selection: .constant(nil), dates: model.photoDateRepair,
        duplicates: model.duplicatePhotos, archive: model.mediaArchive, rename: model.mediaRename),
      name: "home")
    try await render(
      LocalToolsView(
        selection: .constant(.rename), dates: model.photoDateRepair,
        duplicates: model.duplicatePhotos, archive: model.mediaArchive, rename: model.mediaRename),
      name: "preview")
    model.mediaRename.apply()
    try await waitUntil { model.mediaRename.conflict != nil }
    let question = try XCTUnwrap(model.mediaRename.conflict)
    try await render(
      DownloadConflictView(
        conflict: question.file,
        context: .localRename(
          sourcePath: question.sourcePath, targetChanged: question.targetChanged,
          blockedReason: question.replacementBlockedReason), resolve: { _ in }, stop: {}),
      name: "conflict")
    model.mediaRename.cancel()
    try await waitUntil { !model.mediaRename.isBusy }
  }

  private func render<V: View>(_ view: V, name: String) async throws {
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 720, height: 980), styleMask: [.titled],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.appearance = NSAppearance(named: appearance)
      let host = NSHostingView(
        rootView: view.frame(width: 720, height: 980).background(
          Color(nsColor: .windowBackgroundColor)
        )
        .environment(\.locale, L10n.locale).tint(ferryAccent))
      window.contentView = host
      defer {
        window.contentView = nil
        window.close()
      }
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(nanoseconds: 20_000_000)
      host.layoutSubtreeIfNeeded()
      if let path = ProcessInfo.processInfo.environment["FERRY_RENAME_SNAPSHOTS"] {
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
          to: folder.appendingPathComponent(
            "rename-\(L10n.languageIdentifier)-\(name)-\(appearance.rawValue).png"))
      }
    }
  }
}
