import AppKit
import FerryCore
import SwiftUI
import XCTest

@testable import FerryApp

private final class ArchiveConflictToolRunner: EngineRunning, @unchecked Sendable {
  func events(for request: EngineRequest, demo: Bool) -> AsyncThrowingStream<EngineEvent, Error> {
    XCTFail("Local archive conflicts must not request a phone")
    return AsyncThrowingStream { $0.finish() }
  }
  func cancel() {}
  func shutdown() {}
}

@MainActor
final class LocalArchiveConflictToolTests: XCTestCase {
  private func fixture(count: Int = 1, special: Bool = false) throws -> URL {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ferry-archive-question-\(UUID())")
    let root = parent.appendingPathComponent("2022")
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("08月"), withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
    for index in 0..<count {
      let name = "VID_20220801_12000\(index).jpg"
      try Data("incoming-\(index)".utf8).write(to: root.appendingPathComponent(name))
      let target = root.appendingPathComponent("08月/" + name)
      if special {
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
      } else {
        try Data("existing-\(index)".utf8).write(to: target)
      }
    }
    return root
  }
  private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<300 {
      if condition() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Local archive question timed out")
    throw EngineFailure("timeout")
  }
  private func start(_ controller: LocalMediaArchiveController, folder: URL) async throws
    -> MediaArchiveConflict
  {
    controller.selectFolder(folder)
    try await waitUntil { !controller.isBusy }
    controller.apply()
    try await waitUntil { controller.conflict != nil }
    return try XCTUnwrap(controller.conflict)
  }

  func testWaitingRejectsStaleDecisionsAndTheNextRunAsksAgain() async throws {
    let root = try fixture()
    let controller = LocalMediaArchiveController()
    defer { controller.shutdown() }
    let question = try await start(controller, folder: root)
    XCTAssertTrue(controller.isBusy)
    XCTAssertFalse(controller.canApply)
    controller.resolve(.init(id: "stale", choice: "replace"))
    try await Task.sleep(nanoseconds: 40_000_000)
    XCTAssertEqual(controller.conflict?.id, question.id)
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent("08月/VID_20220801_120000.jpg")),
      Data("existing-0".utf8))
    controller.resolve(.init(id: question.id, choice: "skip", applyToAll: true))
    try await waitUntil { !controller.isBusy }
    XCTAssertEqual(controller.result?.skipped, 1)
    XCTAssertEqual(controller.result?.moved, 0)
    let next = try await start(controller, folder: root)
    XCTAssertNotEqual(next.id, question.id)
    controller.resolve(.init(id: question.id, choice: "replace"))
    XCTAssertEqual(controller.conflict?.id, next.id)
    controller.resolve(.init(id: next.id, choice: "keepBoth"))
    try await waitUntil { !controller.isBusy }
    XCTAssertEqual(controller.result?.moved, 1)
    XCTAssertNil(controller.conflict)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("08月/VID_20220801_120000 (1).jpg").path))
  }

  func testAllThreeChoicesCanApplyToAllConflicts() async throws {
    for choice in ["skip", "replace", "keepBoth"] {
      let root = try fixture(count: 2)
      let controller = LocalMediaArchiveController()
      defer { controller.shutdown() }
      let question = try await start(controller, folder: root)
      controller.resolve(.init(id: question.id, choice: choice, applyToAll: true))
      try await waitUntil { !controller.isBusy }
      XCTAssertEqual(controller.result?.skipped, choice == "skip" ? 2 : 0)
      XCTAssertEqual(controller.result?.replaced, choice == "replace" ? 2 : 0)
      XCTAssertEqual(controller.result?.moved, choice == "skip" ? 0 : 2)
      XCTAssertEqual(controller.result?.failed, 0, controller.error ?? "")
      XCTAssertNil(controller.conflict)
    }
  }

  func testStopAndShutdownWakeAWaitingWorkerAndIgnoreLateAnswers() async throws {
    let root = try fixture()
    let controller = LocalMediaArchiveController()
    defer { controller.shutdown() }
    let question = try await start(controller, folder: root)
    controller.cancel()
    XCTAssertNil(controller.conflict)
    controller.resolve(.init(id: question.id, choice: "replace"))
    try await waitUntil { !controller.isBusy }
    XCTAssertEqual(controller.result?.cancelled, true)
    XCTAssertEqual(controller.result?.moved, 0)
    let next = try await start(controller, folder: root)
    controller.shutdown()
    controller.resolve(.init(id: next.id, choice: "replace"))
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertNil(controller.conflict)
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent("VID_20220801_120000.jpg")),
      Data("incoming-0".utf8))
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent("08月/VID_20220801_120000.jpg")),
      Data("existing-0".utf8))
  }

  func testQuestionRemainsAvailableAfterReturningHomeAndBlocksOtherTools() async throws {
    let model = AppModel(runner: ArchiveConflictToolRunner())
    defer { model.shutdown() }
    model.selectPage(.tools)
    model.selectLocalTool(.archive)
    let question = try await start(model.mediaArchive, folder: fixture())
    model.selectLocalTool(nil)
    model.selectLocalTool(.dates)
    XCTAssertNil(model.selectedLocalTool)
    XCTAssertEqual(model.mediaArchive.conflict?.id, question.id)
    model.selectLocalTool(.archive)
    XCTAssertEqual(model.selectedLocalTool, .archive)
    model.mediaArchive.resolve(.init(id: question.id, choice: "skip"))
    try await waitUntil { !model.mediaArchive.isBusy }
    XCTAssertEqual(model.mediaArchive.result?.skipped, 1)
  }

  func testSharedConflictDialogAndWaitingHomeRenderInBothAppearances() async throws {
    if let language = ProcessInfo.processInfo.environment["FERRY_ARCHIVE_CONFLICT_LANGUAGE"] {
      UserDefaults.standard.register(defaults: [L10n.languagePreferenceKey: language])
    }
    _ = NSApplication.shared
    for special in [false, true] {
      let model = AppModel(runner: ArchiveConflictToolRunner())
      defer { model.shutdown() }
      let question = try await start(model.mediaArchive, folder: fixture(special: special))
      try await render(
        DownloadConflictView(
          conflict: question.file,
          context: .localArchive(sourcePath: question.sourcePath, targetChanged: special),
          resolve: { _ in }, stop: {}), name: special ? "archive-special" : "archive-file")
      if !special {
        try await render(
          DownloadConflictView(conflict: question.file, resolve: { _ in }, stop: {}),
          name: "download")
        try await render(
          LocalToolsView(
            selection: .constant(nil), dates: model.photoDateRepair,
            duplicates: model.duplicatePhotos, archive: model.mediaArchive,
            rename: model.mediaRename), name: "waiting-home")
      } else {
        model.mediaArchive.resolve(.init(id: question.id, choice: "replace"))
        XCTAssertNotNil(
          model.mediaArchive.conflict,
          "The disabled Replace action must also be rejected by the controller")
      }
      model.mediaArchive.cancel()
      try await waitUntil { !model.mediaArchive.isBusy }
    }
  }

  private func render<V: View>(_ view: V, name: String) async throws {
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 640, height: 720), styleMask: [.titled],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.appearance = NSAppearance(named: appearance)
      let host = NSHostingView(
        rootView: view.frame(width: 640, height: 720)
          .background(Color(nsColor: .windowBackgroundColor))
          .environment(\.locale, L10n.locale).tint(ferryAccent))
      window.contentView = host
      defer {
        window.contentView = nil
        window.close()
      }
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(nanoseconds: 20_000_000)
      host.layoutSubtreeIfNeeded()
      if let path = ProcessInfo.processInfo.environment["FERRY_ARCHIVE_CONFLICT_SNAPSHOTS"] {
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
          to: folder.appendingPathComponent(
            "conflict-\(L10n.languageIdentifier)-\(name)-\(appearance.rawValue).png"))
      }
    }
  }
}
