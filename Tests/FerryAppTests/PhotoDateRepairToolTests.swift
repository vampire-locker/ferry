import AppKit
import CoreGraphics
import FerryCore
import ImageIO
import SwiftUI
import XCTest

@testable import FerryApp

private final class PhotoToolRunner: EngineRunning, @unchecked Sendable {
  @ThreadSafeTestValue var calls = 0
  func events(for request: EngineRequest, demo: Bool) -> AsyncThrowingStream<EngineEvent, Error> {
    calls += 1
    XCTFail("Local date tools must not request a phone")
    return AsyncThrowingStream { $0.finish() }
  }
  func cancel() {}
  func shutdown() {}
}

private final class PhotoToolUSB: USBMonitoring {
  var onChange: ((Set<UInt64>) -> Void)?
  var devices: Set<UInt64> = [1]
  func start() throws { onChange?(devices) }
  func stop() {}
}

@MainActor
final class PhotoDateRepairToolTests: XCTestCase {
  private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ferry-local-tool-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let provider = try XCTUnwrap(CGDataProvider(data: Data([255, 255, 255, 255]) as CFData))
    let image = try XCTUnwrap(
      CGImage(
        width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    for name in ["20130607_190722.jpg", "20121209_015.jpg"] {
      let file = root.appendingPathComponent(name)
      let destination = try XCTUnwrap(
        CGImageDestinationCreateWithURL(file as CFURL, "public.jpeg" as CFString, 1, nil))
      CGImageDestinationAddImage(destination, image, nil)
      XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
    return root
  }

  private func waitUntil(_ predicate: () -> Bool) async throws {
    for _ in 0..<300 {
      if predicate() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Local tool timed out")
    throw EngineFailure("timeout")
  }

  func testPreviewRequiresExplicitRepairAndOptionsInvalidatePlan() async throws {
    let root = try fixture()
    let controller = PhotoDateRepairController()
    defer { controller.shutdown() }
    let file = root.appendingPathComponent("20130607_190722.jpg")
    let before =
      try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
    controller.selectFolder(root)
    try await waitUntil { !controller.isBusy }
    XCTAssertEqual(controller.phase, .ready, controller.error ?? "")
    XCTAssertEqual(controller.plan?.items.count, 2)
    XCTAssertEqual(
      try FileManager.default.attributesOfItem(
        atPath: file.path)[.modificationDate]
        as? Date, before)
    controller.setOptions(allowDateOnly: false)
    XCTAssertNil(controller.plan)
    XCTAssertFalse(controller.canApply)
    controller.scan()
    try await waitUntil { !controller.isBusy }
    XCTAssertEqual(controller.plan?.items.count, 1)
    controller.apply()
    try await waitUntil { !controller.isBusy }
    XCTAssertEqual(controller.result?.repaired, 1, controller.error ?? "")
    XCTAssertEqual(
      try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date,
      before)
    XCTAssertFalse(controller.canApply, "A finished plan must be rescanned before applying again")
  }

  func testModificationCheckboxDefaultsOffAndChangingItRequiresRescan() async throws {
    let root = try fixture()
    let controller = PhotoDateRepairController()
    defer { controller.shutdown() }
    XCTAssertFalse(controller.repairModificationDate)
    controller.selectFolder(root)
    try await waitUntil { !controller.isBusy }
    XCTAssertEqual(controller.plan?.repairModificationDate, false)
    controller.setOptions(repairModificationDate: true)
    XCTAssertNil(controller.plan)
    XCTAssertFalse(controller.canApply)
    controller.scan()
    try await waitUntil { !controller.isBusy }
    let plan = try XCTUnwrap(controller.plan)
    XCTAssertTrue(plan.repairModificationDate)
    controller.apply()
    try await waitUntil { !controller.isBusy }
    XCTAssertEqual(controller.result?.repaired, 2, controller.error ?? "")
    for item in plan.items {
      let after = try FileManager.default.attributesOfItem(
        atPath: root.appendingPathComponent(item.relativePath).path)
      for key in [FileAttributeKey.creationDate, .modificationDate] {
        XCTAssertEqual(
          try XCTUnwrap(after[key] as? Date).timeIntervalSince1970,
          item.targetDate.timeIntervalSince1970, accuracy: 0.001)
      }
    }
  }

  func testToolNavigationAndWorkDoNotConnectToPhone() async throws {
    let runner = PhotoToolRunner()
    let model = AppModel(runner: runner, usbMonitor: PhotoToolUSB())
    defer { model.shutdown() }
    model.demo = false
    model.selectPage(.tools)
    model.activate()
    let root = try fixture()
    model.photoDateRepair.selectFolder(root)
    try await waitUntil { !model.photoDateRepair.isBusy }
    XCTAssertTrue(model.fileActionsBlocked)
    model.selectPage(.downloads)
    XCTAssertEqual(model.photoDateRepair.plan?.items.count, 2)
    model.selectPage(.tools)
    model.photoDateRepair.apply()
    try await waitUntil { !model.photoDateRepair.isBusy }
    try await Task.sleep(nanoseconds: 900_000_000)
    XCTAssertEqual(model.photoDateRepair.result?.repaired, 2)
    XCTAssertEqual(runner.calls, 0)
  }

  func testTypeOptionsInvalidatePlanAndVideoRepairKeepsOriginalName() async throws {
    let root = try fixture()
    let video = root.appendingPathComponent("VID_20250704_005959.mp4")
    try Data("synthetic video".utf8).write(to: video)
    let originalModified =
      try FileManager.default.attributesOfItem(atPath: video.path)[.modificationDate] as? Date
    let controller = PhotoDateRepairController()
    defer { controller.shutdown() }
    XCTAssertTrue(controller.images)
    XCTAssertTrue(controller.videos)
    controller.selectFolder(root)
    controller.setOptions(videos: false)
    XCTAssertTrue(controller.videos, "Types cannot change while scanning")
    try await waitUntil { !controller.isBusy }
    XCTAssertEqual(controller.plan?.summary.images, 2)
    XCTAssertEqual(controller.plan?.summary.videos, 1)
    controller.setOptions(images: false)
    XCTAssertNil(controller.plan)
    XCTAssertFalse(controller.canApply)
    controller.scan()
    try await waitUntil { !controller.isBusy }
    XCTAssertEqual(controller.plan?.items.count, 1)
    XCTAssertEqual(controller.plan?.items.first?.isVideo, true)
    controller.apply()
    try await waitUntil { !controller.isBusy }
    XCTAssertEqual(controller.result?.repaired, 1, controller.error ?? "")
    XCTAssertEqual(try Data(contentsOf: video), Data("synthetic video".utf8))
    XCTAssertEqual(
      try FileManager.default.attributesOfItem(atPath: video.path)[.modificationDate] as? Date,
      originalModified)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("20130607_190722.jpg").path))
    controller.setOptions(videos: false)
    XCTAssertNil(controller.plan)
  }

  func testLocalToolPageRendersPreviewInLightAndDark() async throws {
    if let language = ProcessInfo.processInfo.environment["FERRY_PHOTO_TOOL_LANGUAGE"] {
      UserDefaults.standard.register(defaults: [L10n.languagePreferenceKey: language])
    }
    _ = NSApplication.shared
    let controller = PhotoDateRepairController()
    defer { controller.shutdown() }
    controller.setOptions(
      repairModificationDate: ProcessInfo.processInfo.environment["FERRY_PHOTO_TOOL_BOTH_DATES"]
        == "1")
    let root = try fixture()
    if ProcessInfo.processInfo.environment["FERRY_DATE_TOOL_VIDEO"] == "1" {
      let video = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(
          "engine/internal/device/fixtures/demo.mp4")
      try FileManager.default.copyItem(
        at: video, to: root.appendingPathComponent("Original Clip.mp4"))
    }
    controller.selectFolder(root)
    try await waitUntil { !controller.isBusy }
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 720, height: 960), styleMask: [.titled],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.appearance = NSAppearance(named: appearance)
      let host = NSHostingView(
        rootView: PhotoDateRepairView(controller: controller).environment(\.locale, L10n.locale)
          .tint(ferryAccent))
      window.contentView = host
      defer {
        window.contentView = nil
        window.close()
      }
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(nanoseconds: 30_000_000)
      host.layoutSubtreeIfNeeded()
      if let path = ProcessInfo.processInfo.environment["FERRY_PHOTO_TOOL_SNAPSHOTS"] {
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(
          to: folder.appendingPathComponent(
            "photo-tool-\(L10n.languageIdentifier)-\(appearance.rawValue).png"))
      }
    }
  }
}
