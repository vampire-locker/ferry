import AppKit
import FerryCore
import Foundation
import XCTest

@testable import FerryApp

private final class MediaTestEngine: EngineRunning, @unchecked Sendable {
  private let callsLock = NSRecursiveLock()
  @ThreadSafeTestValue var requests: [EngineRequest] = []
  @ThreadSafeTestValue var heldOperation: String? = nil
  @ThreadSafeTestValue var pending: AsyncThrowingStream<EngineEvent, Error>.Continuation? = nil
  @ThreadSafeTestValue var pendingRequest: EngineRequest? = nil
  @ThreadSafeTestValue var failThumbnails = false
  @ThreadSafeTestValue var cancelCount = 0
  @ThreadSafeTestValue var active = 0
  @ThreadSafeTestValue var maximumActive = 0

  static var png: Data {
    let image = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0)!
    return image.representation(using: .png, properties: [:])!
  }

  private func event(_ object: [String: Any]) -> EngineEvent {
    try! JSONDecoder().decode(
      EngineEvent.self, from: JSONSerialization.data(withJSONObject: object))
  }

  private func deliver(
    _ req: EngineRequest, to continuation: AsyncThrowingStream<EngineEvent, Error>.Continuation
  ) {
    callsLock.lock()
    defer { callsLock.unlock() }
    switch req.operation {
    case "connect":
      continuation.yield(
        event([
          "type": "connected", "deviceKey": "test", "deviceName": "测试手机",
          "storages": [["id": 1, "name": "内部存储", "capacity": 100, "free": 50]],
        ]))
    case "list":
      continuation.yield(
        event([
          "type": "listed",
          "entries": [
            [
              "id": 1, "storageID": 1, "name": "照片.png", "size": 100, "modified": 0,
              "isDirectory": false,
            ],
            [
              "id": 2, "storageID": 1, "name": "视频.mp4", "size": 100, "modified": 0,
              "isDirectory": false,
            ],
            ["id": 3, "storageID": 1, "name": "目录", "size": 0, "modified": 0, "isDirectory": true],
          ],
        ]))
    case "preview", "thumbnails":
      if req.operation == "thumbnails" && failThumbnails {
        continuation.yield(event(["type": "error", "message": "USB timeout"]))
        break
      }
      for id in req.objectIDs {
        let file = URL(fileURLWithPath: req.destination).appendingPathComponent("\(id).png")
        do { try Self.png.write(to: file) } catch {
          active -= 1
          continuation.finish(throwing: error)
          return
        }
        continuation.yield(
          event([
            "type": req.operation == "preview" ? "completed" : "thumbnail",
            "objectID": id, "output": file.path, "state": "completed",
          ]))
      }
      if req.operation == "thumbnails" { continuation.yield(event(["type": "completed"])) }
    default: break
    }
    active -= 1
    continuation.finish()
  }

  func events(for request: EngineRequest, demo: Bool) -> AsyncThrowingStream<EngineEvent, Error> {
    callsLock.lock()
    defer { callsLock.unlock() }
    requests.append(request)
    active += 1
    maximumActive = max(maximumActive, active)
    return AsyncThrowingStream { continuation in
      if heldOperation == request.operation {
        pending = continuation
        pendingRequest = request
      } else {
        deliver(request, to: continuation)
      }
    }
  }

  func finishHeld() {
    callsLock.lock()
    defer { callsLock.unlock() }
    if let pending, let pendingRequest { deliver(pendingRequest, to: pending) }
    pending = nil
    pendingRequest = nil
  }
  func cancel() {
    callsLock.lock()
    defer { callsLock.unlock() }
    cancelCount += 1
  }
  func shutdown() {
    callsLock.lock()
    defer { callsLock.unlock() }
    if pending != nil { active -= 1 }
    pending?.finish()
    pending = nil
  }
}

@MainActor
final class MediaPreviewTests: XCTestCase {
  func testMediaRequestsKeepSelectedUSBTargetAcrossCancellation() async throws {
    let target = try XCTUnwrap(
      USBDeviceTarget(
        locationID: 0x0213_0000,
        vendorID: 10, productID: 20, serialNumber: "phone"))
    let engine = MediaTestEngine()
    let media = MediaController(runner: engine)
    defer { media.shutdown() }
    media.resume(deviceKey: "test", demo: false, showHiddenFiles: false, usbTarget: target)
    let photo = try entry(1, "照片.png")
    engine.heldOperation = "thumbnails"
    media.setThumbnailDemand([photo])
    try await waitUntil { engine.pending != nil }
    media.openPreview(photo)
    engine.heldOperation = nil
    engine.finishHeld()
    try await waitUntil { media.previewURL != nil }
    XCTAssertEqual(engine.requests.map(\.operation), ["thumbnails", "preview"])
    XCTAssertTrue(engine.requests.allSatisfy { $0.usbTarget == target })
    XCTAssertEqual(engine.maximumActive, 1)
  }

  private func entry(_ id: UInt32, _ name: String) throws -> RemoteEntry {
    try JSONDecoder().decode(
      RemoteEntry.self,
      from: JSONSerialization.data(withJSONObject: [
        "id": id, "storageID": 1, "name": name, "size": 100, "modified": 0, "isDirectory": false,
      ]))
  }

  private func waitUntil(_ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !predicate() {
      if Date() > deadline {
        XCTFail("等待媒体操作超时")
        throw EngineFailure("test timeout")
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
  }

  func testPreviewLoadsAndCloseRemovesOnlyTemporaryFile() async throws {
    let engine = MediaTestEngine()
    let media = MediaController(runner: engine)
    defer { media.shutdown() }
    media.resume(deviceKey: "test", demo: true, showHiddenFiles: false)
    media.openPreview(try entry(1, "照片.png"))
    try await waitUntil { media.previewURL != nil }
    let url = try XCTUnwrap(media.previewURL)
    XCTAssertNotNil(MediaController.decodeThumbnail(url))
    XCTAssertEqual(engine.requests.last?.operation, "preview")
    XCTAssertEqual(engine.requests.last?.objectIDs, [1])
    XCTAssertFalse(engine.requests.last?.showHiddenFiles ?? true)
    media.closePreview()
    try await waitUntil { !FileManager.default.fileExists(atPath: url.path) }
    XCTAssertNil(media.previewEntry)
    XCTAssertNil(media.previewURL)
  }

  func testVisibleCellDemandIsBatchedAndReleasedCellsAreSkipped() async throws {
    let engine = MediaTestEngine()
    let media = MediaController(runner: engine)
    defer { media.shutdown() }
    media.resume(deviceKey: "test", demo: true, showHiddenFiles: true)
    let first = try entry(1, "照片.png")
    let second = try entry(2, "视频.mp4")
    let released = try entry(3, "不在屏幕.png")
    media.requestThumbnail(first)
    media.requestThumbnail(second)
    media.requestThumbnail(released)
    media.releaseThumbnail(released)
    try await waitUntil { media.thumbnail(for: second) != nil }
    XCTAssertNotNil(media.thumbnail(for: first))
    XCTAssertEqual(engine.requests.count, 1)
    XCTAssertEqual(engine.requests.first?.operation, "thumbnails")
    XCTAssertEqual(engine.requests.first?.objectIDs, [1, 2])
    XCTAssertEqual(engine.requests.first?.showHiddenFiles, true)
    media.reset()
    XCTAssertNil(media.thumbnail(for: first))
  }

  func testForegroundRefreshWaitsForCancelledThumbnailHelper() async throws {
    let engine = MediaTestEngine()
    let model = AppModel(runner: engine)
    defer { model.shutdown() }
    model.connect()
    try await waitUntil { !model.busy }
    let photo = try XCTUnwrap(model.entries.first(where: \.isImage))
    engine.heldOperation = "thumbnails"
    model.media.requestThumbnail(photo)
    try await waitUntil { engine.pending != nil }
    model.loadDirectory()
    try await Task.sleep(nanoseconds: 30_000_000)
    XCTAssertTrue(model.busy)
    XCTAssertEqual(engine.requests.filter { $0.operation == "list" }.count, 1)
    XCTAssertGreaterThan(engine.cancelCount, 0)
    engine.heldOperation = nil
    engine.finishHeld()
    try await waitUntil { !model.busy }
    XCTAssertEqual(engine.requests.filter { $0.operation == "list" }.count, 2)
    XCTAssertEqual(engine.maximumActive, 1)
    XCTAssertNil(model.media.thumbnail(for: photo), "过期缩略图不能重新填充缓存")
  }

  func testCancelledPreviewCannotPublishLateFile() async throws {
    let engine = MediaTestEngine()
    engine.heldOperation = "preview"
    let media = MediaController(runner: engine)
    defer { media.shutdown() }
    media.resume(deviceKey: "test", demo: true, showHiddenFiles: false)
    media.openPreview(try entry(2, "视频.mp4"))
    try await waitUntil { engine.pending != nil }
    let destination = try XCTUnwrap(engine.pendingRequest?.destination)
    media.closePreview()
    engine.finishHeld()
    try await waitUntil { !FileManager.default.fileExists(atPath: destination) }
    XCTAssertNil(media.previewURL)
    XCTAssertNil(media.previewEntry)
    XCTAssertEqual(engine.maximumActive, 1)
  }

  func testThumbnailTransportFailureStopsQueueButAllowsExplicitPreview() async throws {
    let engine = MediaTestEngine()
    engine.failThumbnails = true
    let media = MediaController(runner: engine)
    defer { media.shutdown() }
    media.resume(deviceKey: "test", demo: true, showHiddenFiles: false)
    let photo = try entry(1, "照片.png")
    media.requestThumbnail(photo)
    try await waitUntil { engine.requests.count == 1 }
    try await Task.sleep(nanoseconds: 30_000_000)
    media.requestThumbnail(try entry(2, "视频.mp4"))
    try await Task.sleep(nanoseconds: 150_000_000)
    XCTAssertEqual(engine.requests.count, 1)
    media.openPreview(photo)
    try await waitUntil { media.previewURL != nil }
    XCTAssertEqual(engine.requests.last?.operation, "preview")
  }

  func testViewModePersistsAndSharesSelectionWithList() async throws {
    let domain = "ferry-media-settings-\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: domain)!
    defer { preferences.removePersistentDomain(forName: domain) }
    let engine = MediaTestEngine()
    let model = AppModel(runner: engine, preferences: preferences)
    defer { model.shutdown() }
    model.connect()
    try await waitUntil { !model.busy }
    XCTAssertEqual(model.viewMode, .list)
    let photo = try XCTUnwrap(model.entries.first(where: \.isImage))
    let video = try XCTUnwrap(model.entries.first(where: \.isVideo))
    model.selectGridEntry(photo, extending: false, toggling: false)
    XCTAssertEqual(model.previewableSelection?.id, photo.id)
    model.setViewMode(.preview)
    XCTAssertEqual(model.selection, [photo.id])
    model.selectGridEntry(video, extending: true, toggling: false)
    XCTAssertEqual(model.selection, [photo.id, video.id])
    XCTAssertNil(model.previewableSelection)
    model.selectGridEntry(photo, extending: false, toggling: true)
    XCTAssertEqual(model.selection, [video.id])
    model.query = "照片"
    XCTAssertTrue(model.selection.isEmpty)
    let reopened = AppModel(runner: MediaTestEngine(), preferences: preferences)
    defer { reopened.shutdown() }
    XCTAssertEqual(reopened.viewMode, .preview)
    model.busy = true
    model.setViewMode(.list)
    XCTAssertEqual(model.viewMode, .preview)
  }
}
