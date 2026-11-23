import AppKit
import Darwin
import FerryCore
import Foundation
import SwiftUI
import XCTest

@testable import FerryApp

private final class RenderEngine: EngineRunning, @unchecked Sendable {
  private let lock = NSLock()
  private let queue = DispatchQueue(label: "ferry.render.test")
  private var counts: [String: Int] = [:]
  func events(for request: EngineRequest, demo: Bool) -> AsyncThrowingStream<EngineEvent, Error> {
    AsyncThrowingStream { continuation in
      let delay = request.objectIDs.count > 1 && request.downloadAction == "next" ? 0.1 : 0.001
      queue.asyncAfter(deadline: .now() + delay) { [self] in
        func event(_ value: [String: Any]) -> EngineEvent {
          try! JSONDecoder().decode(
            EngineEvent.self, from: JSONSerialization.data(withJSONObject: value))
        }
        lock.lock()
        let id = request.downloadID!
        switch request.downloadAction {
        case "begin":
          counts[id] = 0
          continuation.yield(event(["type": "yielded", "state": "running"]))
        case "next":
          let count = (counts[id] ?? 0) + 1
          counts[id] = count
          for part in 1...10 {
            continuation.yield(
              event([
                "type": "progress", "completed": count - 1,
                "total": request.objectIDs.count, "bytes": (count - 1) * 1000 + part * 100,
                "totalBytes": request.objectIDs.count * 1000, "currentFile": "photo-\(count).jpg",
              ]))
          }
          let done = count == request.objectIDs.count
          continuation.yield(
            event(["type": done ? "completed" : "yielded", "state": done ? "completed" : "running"])
          )
        case "cancel": continuation.yield(event(["type": "completed", "state": "cancelled"]))
        default: XCTFail("Rendering test must not issue browser or USB requests")
        }
        lock.unlock()
        continuation.finish()
      }
    }
  }
  func cancel() {}
  func shutdown() {}
}

private final class RenderUSB: USBMonitoring {
  var onChange: ((Set<UInt64>) -> Void)?
  var devices: Set<UInt64> = []
  func start() throws { XCTFail("Rendering tests must not initialize USB") }
  func stop() {}
}

@MainActor
private final class RenderHostingView: NSHostingView<ContentView> {
  var layoutCount = 0
  override func layout() {
    layoutCount += 1
    super.layout()
  }
}

@MainActor
final class DownloadRenderingTests: XCTestCase {
  func testInactiveTaskClockDoesNotScheduleFutureTicks() {
    let origin = Date(timeIntervalSince1970: 100)
    let inactive = DownloadTaskClockSchedule(origin: origin, isActive: false)
    let stoppedTicks = Array(inactive.entries(from: origin.addingTimeInterval(10), mode: .normal))
    XCTAssertLessThanOrEqual(stoppedTicks.count, 1)
    XCTAssertTrue(stoppedTicks.allSatisfy { $0 <= origin })
    let active = DownloadTaskClockSchedule(origin: origin, isActive: true)
    let ticks = Array(active.entries(from: origin, mode: .normal).prefix(3))
    XCTAssertEqual(ticks.count, 3)
    XCTAssertEqual(ticks[1].timeIntervalSince(ticks[0]), 1)
  }

  func testCompletionRetainsTheNativeProgressViewForItsTransition() async throws {
    _ = NSApplication.shared
    let controller = DownloadQueueController(runner: RenderEngine(), uptime: { 20 })
    defer { controller.shutdown() }
    var task = DownloadTask(
      id: UUID(), title: "Transition", state: .running, transferred: 900, totalBytes: 1000,
      request: EngineRequest(operation: "download"), demo: true)
    let row = DownloadTaskRowModel(task)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 620, height: 300), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(
      rootView: DownloadTaskRowView(row: row, controller: controller, showReport: { _ in }))
    window.contentView = host
    defer {
      window.contentView = nil
      window.close()
    }
    try await waitUntil(host: host) { self.sailingViews(in: host).first?.artwork.scene == .sailing }
    let original = try XCTUnwrap(sailingViews(in: host).first)
    task.state = .completed
    task.transferred = 1000
    row.update(task)
    try await waitUntil(host: host) { self.sailingViews(in: host).first?.artwork.scene == .docked }
    XCTAssertTrue(
      try XCTUnwrap(sailingViews(in: host).first) === original,
      "Completing a task must update its existing native view so it can animate")
    XCTAssertEqual(original.artwork.boat.opacity, 0)
    XCTAssertFalse(original.artwork.harbor.isHidden)
  }

  func testTaskCardsRenderAtNarrowAndWideSizesInBothAppearances() async throws {
    if let language = ProcessInfo.processInfo.environment["FERRY_TASK_LAYOUT_LANGUAGE"] {
      UserDefaults.standard.register(defaults: [L10n.languagePreferenceKey: language])
    }
    _ = NSApplication.shared
    let controller = DownloadQueueController(runner: RenderEngine(), uptime: { 2000 })
    defer { controller.shutdown() }
    let rows = [DownloadTaskState.completed, .failed, .running, .cancelled, .interrupted]
      .enumerated().map {
        index, state in
        var conditions = [
          DirectoryMediaFilter.images.title, L10n.text("修改年份：\(2025)"),
          L10n.text("修改月份：\(index + 1)"), L10n.text("不含隐藏文件"),
        ]
        if state == .running {
          conditions.append(L10n.text("搜索“\("Camera / 照片备份 / very long search text")”"))
        }
        var task = DownloadTask(
          id: UUID(),
          title: L10n.text("\(826 + index) 个项目 · \("Internal storage / DCIM / Camera")"),
          filterSummary: L10n.text("筛选：\(conditions.joined(separator: " · "))"),
          state: state, completed: state == .completed ? 826 + index : 214, total: 826 + index,
          transferred: state == .completed ? 6_600_000_000 : 1_700_000_000,
          totalBytes: 6_600_000_000,
          currentFile: "2025/11月/MVIMG_20251130_211222_very_long_photo_filename.jpg",
          request: EngineRequest(operation: "download"), demo: true)
        task.output = URL(fileURLWithPath: "/synthetic/photos")
        task.reportURL = URL(fileURLWithPath: "/synthetic/report.json")
        task.resumeAvailable = state == .cancelled || state == .interrupted
        task.timing.start(at: state == .running ? 1900 : 0)
        if state != .running { task.timing.finish(at: 647) }
        if state == .interrupted { task.timing = TransferTiming() }
        return DownloadTaskRowModel(task)
      }
    for width in [620.0, 960] {
      for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        let window = NSWindow(
          contentRect: NSRect(x: 0, y: 0, width: width, height: 1480), styleMask: [.titled],
          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let host = NSHostingView(
          rootView: VStack(spacing: 16) {
            ForEach(rows) { row in
              DownloadTaskRowView(row: row, controller: controller, showReport: { _ in })
            }
          }
          .padding(24)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .background(Color(nsColor: .windowBackgroundColor))
          .environment(\.locale, L10n.locale)
          .tint(ferryAccent))
        window.contentView = host
        defer {
          window.contentView = nil
          window.close()
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 30_000_000)
        host.layoutSubtreeIfNeeded()
        let progressViews = sailingViews(in: host)
        XCTAssertEqual(progressViews.count, rows.count)
        for (progress, row) in zip(progressViews, rows) {
          let rect = progress.convert(progress.bounds, to: host)
          XCTAssertGreaterThan(rect.width, width / 2)
          XCTAssertGreaterThan(rect.height, 0)
          XCTAssertTrue(host.bounds.contains(rect), "Progress artwork must stay inside the page")
          XCTAssertNotNil(progress.artwork.boat.contents)
          XCTAssertEqual(progress.artwork.scene, SailingScene(row.task.state))
          if row.task.state == .completed {
            let track = try XCTUnwrap(progress.artwork.root.sublayers?.first as? CAShapeLayer)
            let endpoint = try XCTUnwrap(track.path).boundingBoxOfPath.maxX
            let harborBounds = progress.artwork.flag.convert(
              try XCTUnwrap(progress.artwork.flag.path).boundingBoxOfPath,
              to: progress.artwork.root)
            XCTAssertEqual(
              harborBounds.maxX, endpoint, accuracy: 0.001,
              "The completed artwork's right edge must match the actual track in the task card")
          }
          XCTAssertFalse(progress.artwork.marker.isHidden)
          XCTAssertEqual(progress.artwork.boat.isHidden, row.task.state == .failed)
          XCTAssertEqual(progress.artwork.boat.opacity, row.task.state == .completed ? 0 : 1)
          XCTAssertFalse(progress.artwork.root.isHidden)
        }
        if let directory = ProcessInfo.processInfo.environment["FERRY_TASK_LAYOUT_SNAPSHOTS"] {
          let destination = URL(fileURLWithPath: directory)
          try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: true)
          let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
          host.cacheDisplay(in: host.bounds, to: bitmap)
          let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
          try data.write(
            to: destination.appendingPathComponent(
              "cards-\(L10n.languageIdentifier)-\(appearance.rawValue)-\(Int(width)).png"))
        }
      }
    }
  }

  private func sailingViews(in view: NSView) -> [SailingProgressNSView] {
    if let progress = view as? SailingProgressNSView { return [progress] }
    return view.subviews.flatMap { sailingViews(in: $0) }
  }

  func testRetainedBrowserKeepsNativeTableScrollAndSelectionAcrossPageChanges() async throws {
    _ = NSApplication.shared
    let domain = "ferry-scroll-retention-\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: domain)!
    defer { preferences.removePersistentDomain(forName: domain) }
    let model = AppModel(runner: RenderEngine(), usbMonitor: RenderUSB(), preferences: preferences)
    defer { model.shutdown() }
    model.demo = true
    model.storageID = 1
    model.storages = try JSONDecoder().decode(
      [DeviceStorage].self,
      from: Data("[{\"id\":1,\"name\":\"Test\",\"capacity\":1000000,\"free\":1000000}]".utf8))
    let rows = (1...43000).map {
      "{\"id\":\($0),\"storageID\":1,\"name\":\"photo-\($0).jpg\",\"isDirectory\":false,\"size\":1000,\"modified\":1760000000}"
    }.joined(separator: ",")
    model.entries = try JSONDecoder().decode([RemoteEntry].self, from: Data("[\(rows)]".utf8))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1080, height: 740), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = RenderHostingView(rootView: ContentView(model: model))
    window.contentView = host
    defer {
      window.contentView = nil
      window.close()
    }
    try await waitUntil(host: host) {
      !model.filtering && !model.sorting && self.findTable(in: host)?.numberOfRows == 43000
    }
    let table = try XCTUnwrap(findTable(in: host))
    let container = try XCTUnwrap(findContainer(in: host))
    XCTAssertGreaterThan(container.bounds.width, 600)
    XCTAssertGreaterThan(container.bounds.height, 300)
    XCTAssertEqual(container.hostingView.frame, container.bounds)
    XCTAssertGreaterThan(try XCTUnwrap(table.enclosingScrollView).bounds.height, 200)
    model.selection = [model.visibleEntries[30000].id]
    table.scrollRowToVisible(30000)
    try await waitUntil(host: host) {
      (table.enclosingScrollView?.documentVisibleRect.minY ?? 0) > 0
    }
    let before = try XCTUnwrap(table.enclosingScrollView).documentVisibleRect.origin.y
    let frame = container.hostingView.frame
    let selected = model.selection
    model.selectPage(.downloads)
    try await waitUntil(host: host) { container.isHidden }
    window.setContentSize(NSSize(width: 1180, height: 740))
    host.layoutSubtreeIfNeeded()
    XCTAssertEqual(container.hostingView.frame, frame, "Hidden browser geometry must be frozen")
    model.selectPage(.browser)
    try await waitUntil(host: host) {
      !container.isHidden && container.hostingView.frame.width == container.bounds.width
    }
    XCTAssertTrue(findTable(in: host) === table, "The native Table must not be recreated")
    XCTAssertEqual(model.selection, selected)
    XCTAssertEqual(
      try XCTUnwrap(table.enclosingScrollView).documentVisibleRect.origin.y, before, accuracy: 1)
    XCTAssertEqual(model.visibleEntries.count, 43000)
  }

  func testNativeLargeDirectoryDuringProgress() async throws {
    _ = NSApplication.shared
    let domain = "ferry-render-\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: domain)!
    defer { preferences.removePersistentDomain(forName: domain) }
    let model = AppModel(runner: RenderEngine(), usbMonitor: RenderUSB(), preferences: preferences)
    defer { model.shutdown() }
    model.demo = true
    model.storageID = 1
    model.storages = try JSONDecoder().decode(
      [DeviceStorage].self,
      from: Data("[{\"id\":1,\"name\":\"Test\",\"capacity\":1000000000,\"free\":1000000000}]".utf8))
    let rows = (1...43000).map {
      "{\"id\":\($0),\"storageID\":1,\"name\":\"photo-\($0).jpg\",\"isDirectory\":false,\"size\":1000,\"modified\":1760000000}"
    }.joined(separator: ",")
    model.entries = try JSONDecoder().decode([RemoteEntry].self, from: Data("[\(rows)]".utf8))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1080, height: 740), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = RenderHostingView(rootView: ContentView(model: model))
    window.contentView = host
    defer {
      window.contentView = nil
      window.close()
    }
    try await waitUntil(host: host) { !model.filtering && model.visibleEntries.count == 43000 }
    host.layoutSubtreeIfNeeded()
    model.selectPage(.downloads)
    for index in 0..<6 {
      model.downloadQueue.enqueue(
        title: "history-\(index)", request: EngineRequest(operation: "download", objectIDs: [1]),
        demo: true)
    }
    try await waitUntil(host: host) {
      model.downloadQueue.tasks.count == 6
        && model.downloadQueue.tasks.allSatisfy { $0.state == .completed }
    }
    model.downloadQueue.enqueue(
      title: "active", request: EngineRequest(operation: "download", objectIDs: Array(1...20)),
      demo: true)
    try await waitUntil(host: host) { (model.downloadQueue.tasks.last?.transferred ?? 0) > 0 }
    let cpu = cpuTime()
    let start = ProcessInfo.processInfo.systemUptime
    let layouts = host.layoutCount
    try await waitUntil(host: host) { model.downloadQueue.tasks.last?.state == .completed }
    let result: [String: Double] = [
      "cpu_seconds": cpuTime() - cpu, "wall_seconds": ProcessInfo.processInfo.systemUptime - start,
      "root_layouts": Double(host.layoutCount - layouts),
    ]
    print("NATIVE_RENDER 43000 entries / 6 history / 1 active: \(result)")
    if let output = ProcessInfo.processInfo.environment["FERRY_UI_PERF_OUTPUT"] {
      try JSONSerialization.data(withJSONObject: result).write(to: URL(fileURLWithPath: output))
    }
    XCTAssertEqual(model.downloadQueue.tasks.count, 7)
    XCTAssertEqual(model.visibleEntries.count, 43000)
    model.selectPage(.browser)
    host.layoutSubtreeIfNeeded()
    XCTAssertEqual(model.visibleEntries.count, 43000)
  }

  private func waitUntil(host: NSView, _ predicate: () -> Bool) async throws {
    for _ in 0..<1500 {
      host.layoutSubtreeIfNeeded()
      if predicate() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Native rendering workload timed out")
    throw EngineFailure("test timeout")
  }
  private func cpuTime() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(
      usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
  }

  private func findTable(in view: NSView) -> NSTableView? {
    if let table = view as? NSTableView { return table }
    for child in view.subviews { if let table = findTable(in: child) { return table } }
    return nil
  }
  private func findContainer(in view: NSView) -> RetainedBrowserContainer? {
    if let container = view as? RetainedBrowserContainer { return container }
    for child in view.subviews { if let container = findContainer(in: child) { return container } }
    return nil
  }
}
