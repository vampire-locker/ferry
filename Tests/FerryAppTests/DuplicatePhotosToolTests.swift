import AppKit
import CoreGraphics
import FerryCore
import ImageIO
import SwiftUI
import XCTest

@testable import FerryApp

private final class DuplicateToolRunner: EngineRunning, @unchecked Sendable {
  func events(for request: EngineRequest, demo: Bool) -> AsyncThrowingStream<EngineEvent, Error> {
    XCTFail("Duplicate tools must not request a phone")
    return AsyncThrowingStream { $0.finish() }
  }
  func cancel() {}
  func shutdown() {}
}

@MainActor
final class DuplicatePhotosToolTests: XCTestCase {
  private func fixture() throws -> (root: URL, photos: URL, trash: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ferry-duplicate-tool-\(UUID())")
    let photos = root.appendingPathComponent("photos")
    let album = photos.appendingPathComponent("album")
    let trash = root.appendingPathComponent("test-trash")
    for url in [album, trash] {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let provider = try XCTUnwrap(CGDataProvider(data: Data([80, 180, 160, 255]) as CFData))
    let image = try XCTUnwrap(
      CGImage(
        width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let file = photos.appendingPathComponent("photo.jpg")
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithURL(file as CFURL, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    try FileManager.default.copyItem(at: file, to: album.appendingPathComponent("copy.jpg"))
    return (root, photos, trash)
  }
  private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<300 {
      if condition() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Duplicate tool timed out")
    throw EngineFailure("timeout")
  }

  func testNoDefaultCleanupAndPreferredFolderRuleKeepsTheChosenCopy() async throws {
    let fixture = try fixture()
    let controller = DuplicatePhotosController(trash: { url in
      try FileManager.default.moveItem(
        at: url, to: fixture.trash.appendingPathComponent(url.lastPathComponent))
    })
    defer { controller.shutdown() }
    controller.selectFolder(fixture.photos)
    try await waitUntil { !controller.isBusy }
    XCTAssertEqual(controller.phase, .ready, controller.error ?? "")
    XCTAssertEqual(controller.plan?.groups.count, 1)
    XCTAssertTrue(controller.selectedGroups.isEmpty)
    XCTAssertFalse(controller.canClean)
    controller.clean()
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
    let group = try XCTUnwrap(controller.plan?.groups.first)
    controller.preferFolder(fixture.root)
    XCTAssertNotNil(controller.error)
    controller.preferFolder(fixture.photos.appendingPathComponent("album"))
    XCTAssertNil(controller.error)
    XCTAssertEqual(controller.keepers[group.id], "album/copy.jpg")
    controller.selectAll(true)
    XCTAssertEqual(controller.selectedCopies, 1)
    XCTAssertTrue(controller.canClean)
    controller.keep("missing.jpg", in: group.id)
    XCTAssertEqual(controller.keepers[group.id], "album/copy.jpg")
    controller.clean()
    try await waitUntil { !controller.isBusy }
    XCTAssertEqual(controller.result?.moved, 1)
    XCTAssertFalse(controller.canClean)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: fixture.photos.appendingPathComponent("album/copy.jpg").path))
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path), ["photo.jpg"])
  }

  func testToolChoiceIsRememberedAndBusyToolsCannotBeSwitched() async throws {
    let model = AppModel(runner: DuplicateToolRunner())
    defer { model.shutdown() }
    model.selectPage(.tools)
    model.selectLocalTool(.duplicates)
    let fixture = try fixture()
    model.duplicatePhotos.selectFolder(fixture.photos)
    model.selectLocalTool(.dates)
    XCTAssertEqual(model.selectedLocalTool, .duplicates)
    try await waitUntil { !model.duplicatePhotos.isBusy }
    model.selectPage(.downloads)
    model.selectPage(.tools)
    XCTAssertEqual(model.selectedLocalTool, .duplicates)
    XCTAssertEqual(model.duplicatePhotos.plan?.groups.count, 1)
    model.duplicatePhotos.setRecursive(false)
    XCTAssertNil(model.duplicatePhotos.plan)
    XCTAssertFalse(model.duplicatePhotos.canClean)
  }

  func testThumbnailIsBoundedAndSurvivesTheSourceDescriptorClosing() async throws {
    let fixture = try fixture()
    let plan = try DuplicatePhotos.scan(
      folder: fixture.photos, recursive: true, cancellation: .init())
    let image = try XCTUnwrap(
      DuplicatePhotos.thumbnail(plan.groups[0].photos[0], plan: plan, cancellation: .init()))
    XCTAssertLessThanOrEqual(image.width, 144)
    XCTAssertLessThanOrEqual(image.height, 144)
    let target = try XCTUnwrap(
      CGContext(
        data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    target.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16))
    XCTAssertNotNil(target.makeImage())
  }

  func testDuplicateToolRendersInBothAppearances() async throws {
    if let language = ProcessInfo.processInfo.environment["FERRY_DUPLICATE_LANGUAGE"] {
      UserDefaults.standard.register(defaults: [L10n.languagePreferenceKey: language])
    }
    _ = NSApplication.shared
    let fixture = try fixture()
    let controller = DuplicatePhotosController()
    defer { controller.shutdown() }
    controller.selectFolder(fixture.photos)
    try await waitUntil { !controller.isBusy }
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 720, height: 1000), styleMask: [.titled],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.appearance = NSAppearance(named: appearance)
      let host = NSHostingView(
        rootView: LocalToolsView(
          selection: .constant(.duplicates), dates: PhotoDateRepairController(),
          duplicates: controller, archive: LocalMediaArchiveController(),
          rename: LocalMediaArchiveController(operation: .renameMedia)
        )
        .environment(\.locale, L10n.locale).tint(ferryAccent))
      window.contentView = host
      defer {
        window.contentView = nil
        window.close()
      }
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(nanoseconds: 80_000_000)
      host.layoutSubtreeIfNeeded()
      if let path = ProcessInfo.processInfo.environment["FERRY_DUPLICATE_SNAPSHOTS"] {
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(
          to: folder.appendingPathComponent(
            "duplicates-\(L10n.languageIdentifier)-\(appearance.rawValue).png"))
      }
    }
  }
}
