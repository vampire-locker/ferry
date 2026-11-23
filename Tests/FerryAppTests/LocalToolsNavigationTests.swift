import AppKit
import FerryCore
import SwiftUI
import XCTest

@testable import FerryApp

private final class LocalToolsRunner: EngineRunning, @unchecked Sendable {
  func events(for request: EngineRequest, demo: Bool) -> AsyncThrowingStream<EngineEvent, Error> {
    XCTFail("Local tool navigation must not request a phone")
    return AsyncThrowingStream { $0.finish() }
  }
  func cancel() {}
  func shutdown() {}
}

@MainActor
final class LocalToolsNavigationTests: XCTestCase {
  private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ferry-tools-home-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    for name in ["20121209_015.jpg", "20130607_190722.jpg"] {
      try Data("synthetic local tool fixture".utf8).write(to: root.appendingPathComponent(name))
    }
    return root
  }
  private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<300 {
      if condition() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Local tool navigation timed out")
    throw EngineFailure("timeout")
  }
  private func scan(_ tool: LocalTool, model: AppModel, folder: URL) {
    switch tool {
    case .dates: model.photoDateRepair.selectFolder(folder)
    case .duplicates: model.duplicatePhotos.selectFolder(folder)
    case .archive: model.mediaArchive.selectFolder(folder)
    case .rename: model.mediaRename.selectFolder(folder)
    }
  }
  private func isBusy(_ tool: LocalTool, model: AppModel) -> Bool {
    switch tool {
    case .dates: return model.photoDateRepair.isBusy
    case .duplicates: return model.duplicatePhotos.isBusy
    case .archive: return model.mediaArchive.isBusy
    case .rename: return model.mediaRename.isBusy
    }
  }

  func testHomeAndRunningToolCanBeReopenedWithoutLosingScanOrAllowingOtherTools() async throws {
    for tool in LocalTool.allCases {
      let model = AppModel(runner: LocalToolsRunner())
      defer { model.shutdown() }
      XCTAssertNil(model.selectedLocalTool, "The first visit must show the tool home")
      let root = try fixture()
      model.selectPage(.tools)
      model.selectLocalTool(tool)
      scan(tool, model: model, folder: root)
      XCTAssertTrue(isBusy(tool, model: model))
      model.selectLocalTool(nil)
      XCTAssertNil(model.selectedLocalTool)
      XCTAssertTrue(isBusy(tool, model: model), "Going home must not stop the scan")
      let other = try XCTUnwrap(LocalTool.allCases.first { $0 != tool })
      model.selectLocalTool(other)
      XCTAssertNil(model.selectedLocalTool, "Other tools stay unavailable while work is running")
      model.selectLocalTool(tool)
      XCTAssertEqual(model.selectedLocalTool, tool, "The running card must reopen its progress")
      model.selectLocalTool(nil)
      try await waitUntil { !self.isBusy(tool, model: model) }
      XCTAssertNil(model.selectedLocalTool, "Finishing in the background must not leave the home")
      model.selectPage(.downloads)
      model.selectPage(.tools)
      XCTAssertNil(model.selectedLocalTool)
      model.selectLocalTool(tool)
      switch tool {
      case .dates: XCTAssertEqual(model.photoDateRepair.plan?.items.count, 2)
      case .duplicates: XCTAssertEqual(model.duplicatePhotos.plan?.groups.count, 1)
      case .archive: XCTAssertEqual(model.mediaArchive.plan?.items.count, 2)
      case .rename:
        XCTAssertEqual(model.mediaRename.plan?.summary.noDate, 1)
        XCTAssertEqual(model.mediaRename.plan?.items.map(\.relativePath), ["20130607_190722.jpg"])
        XCTAssertEqual(model.mediaRename.plan?.items.first?.source, .filename)
      }
      model.selectPage(.downloads)
      model.selectPage(.tools)
      XCTAssertEqual(model.selectedLocalTool, tool)
      for file in ["20121209_015.jpg", "20130607_190722.jpg"] {
        XCTAssertEqual(
          try Data(contentsOf: root.appendingPathComponent(file)),
          Data("synthetic local tool fixture".utf8))
      }
    }
  }

  func testReturningHomeDuringRepairAndArchivePreservesTheOperationAndResults() async throws {
    for tool in [LocalTool.dates, .archive] {
      let model = AppModel(runner: LocalToolsRunner())
      defer { model.shutdown() }
      let root = try fixture()
      model.selectLocalTool(tool)
      scan(tool, model: model, folder: root)
      try await waitUntil { !self.isBusy(tool, model: model) }
      if tool == .dates { model.photoDateRepair.apply() } else { model.mediaArchive.apply() }
      XCTAssertTrue(isBusy(tool, model: model))
      model.selectLocalTool(nil)
      XCTAssertTrue(isBusy(tool, model: model))
      model.selectLocalTool(tool)
      XCTAssertEqual(model.selectedLocalTool, tool)
      model.selectLocalTool(nil)
      try await waitUntil { !self.isBusy(tool, model: model) }
      XCTAssertNil(model.selectedLocalTool)
      model.selectLocalTool(tool)
      if tool == .dates {
        XCTAssertEqual(model.photoDateRepair.result?.repaired, 2)
        XCTAssertFalse(model.photoDateRepair.result?.cancelled ?? true)
      } else {
        XCTAssertEqual(model.mediaArchive.result?.moved, 2)
        XCTAssertFalse(model.mediaArchive.result?.cancelled ?? true)
      }
    }
  }

  func testHomeReadyRunningAndDetailPagesRenderAtTwoWidthsInLightAndDark() async throws {
    if let language = ProcessInfo.processInfo.environment["FERRY_LOCAL_TOOLS_LANGUAGE"] {
      UserDefaults.standard.register(defaults: [L10n.languagePreferenceKey: language])
    }
    _ = NSApplication.shared
    let model = AppModel(runner: LocalToolsRunner())
    defer { model.shutdown() }
    let root = try fixture()
    for width in [640.0, 900.0] {
      try render(model, name: "home", width: width)
    }
    model.photoDateRepair.selectFolder(root)
    try await waitUntil { !model.photoDateRepair.isBusy }
    try render(model, name: "ready", width: 640)
    model.mediaArchive.selectFolder(root)
    // Stay on the main actor until both snapshots are taken, so the busy state is deterministic.
    try render(model, name: "running", width: 640)
    model.selectLocalTool(.archive)
    try render(model, name: "detail", width: 640)
    try await waitUntil { !model.mediaArchive.isBusy }
  }

  private func render(_ model: AppModel, name: String, width: Double) throws {
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: 920), styleMask: [.titled],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.appearance = NSAppearance(named: appearance)
      let host = NSHostingView(
        rootView: LocalToolsView(
          selection: Binding(get: { model.selectedLocalTool }, set: { model.selectLocalTool($0) }),
          dates: model.photoDateRepair, duplicates: model.duplicatePhotos,
          archive: model.mediaArchive, rename: model.mediaRename
        )
        .environment(\.locale, L10n.locale).tint(ferryAccent))
      window.contentView = host
      defer {
        window.contentView = nil
        window.close()
      }
      host.layoutSubtreeIfNeeded()
      if let path = ProcessInfo.processInfo.environment["FERRY_LOCAL_TOOLS_SNAPSHOTS"] {
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
          to: folder.appendingPathComponent(
            "tools-\(L10n.languageIdentifier)-\(name)-\(Int(width))-\(appearance.rawValue).png"))
      }
    }
  }
}
