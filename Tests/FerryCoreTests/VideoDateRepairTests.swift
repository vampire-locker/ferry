import AVFoundation
import Foundation
import XCTest

@testable import FerryCore

final class VideoDateRepairTests: XCTestCase {
  private func folder() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ferry-video-dates-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    return root
  }
  private func video(_ root: URL) async throws -> URL {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent(
        "engine/internal/device/fixtures/demo.mp4")
    let export = try XCTUnwrap(
      AVAssetExportSession(
        asset: AVURLAsset(url: fixture), presetName: AVAssetExportPresetPassthrough))
    let entry = AVMutableMetadataItem()
    entry.identifier = .quickTimeMetadataCreationDate
    entry.value = "2025-07-04T00:59:59+08:00" as NSString
    entry.dataType = "com.apple.metadata.datatype.UTF-8"
    export.metadata = [entry]
    let file = root.appendingPathComponent("Original Clip.MP4")
    export.outputURL = file
    export.outputFileType = .mp4
    await withCheckedContinuation { continuation in
      export.exportAsynchronously { continuation.resume() }
    }
    XCTAssertEqual(export.status, .completed, export.error?.localizedDescription ?? "")
    try FileManager.default.setAttributes(
      [
        .creationDate: Date(timeIntervalSince1970: 1_700_000_000),
        .modificationDate: Date(timeIntervalSince1970: 1_750_000_000),
      ], ofItemAtPath: file.path)
    return file
  }

  func testEmbeddedVideoTimeRepairsCreationOnlyThenOptionalModificationWithoutRenaming()
    async throws
  {
    let root = try folder()
    let file = try await video(root)
    let bytes = try Data(contentsOf: file)
    let original = try FileManager.default.attributesOfItem(atPath: file.path)
    let expected = try XCTUnwrap(PhotoDateRepair.parseDate("2025:07:04 00:59:59", offset: "+08:00"))
    let plan = try await PhotoDateRepair.scan(
      folder: root, recursive: true, allowFilename: true,
      allowDateOnly: true, images: false, videos: true, cancellation: .init())
    XCTAssertEqual(plan.summary.images, 0)
    XCTAssertEqual(plan.summary.videos, 1)
    XCTAssertEqual(plan.summary.fromVideoMetadata, 1)
    XCTAssertEqual(plan.items.first?.source, .videoMetadata)
    XCTAssertEqual(plan.items.first?.isVideo, true)
    XCTAssertEqual(plan.items.first?.targetDate, expected)
    XCTAssertEqual(
      try FileManager.default.attributesOfItem(atPath: file.path)[.creationDate] as? Date,
      original[.creationDate] as? Date, "Scan must remain read-only")
    XCTAssertEqual(try PhotoDateRepair.apply(plan, cancellation: .init()).repaired, 1)
    let created = try FileManager.default.attributesOfItem(atPath: file.path)
    XCTAssertEqual(
      try XCTUnwrap(created[.creationDate] as? Date).timeIntervalSince1970,
      expected.timeIntervalSince1970, accuracy: 0.001)
    XCTAssertEqual(created[.modificationDate] as? Date, original[.modificationDate] as? Date)
    let again = try await PhotoDateRepair.scan(
      folder: root, recursive: true, allowFilename: false,
      allowDateOnly: false, cancellation: .init())
    XCTAssertTrue(again.items.isEmpty)
    let both = try await PhotoDateRepair.scan(
      folder: root, recursive: true, allowFilename: false,
      allowDateOnly: false, repairModificationDate: true, cancellation: .init())
    XCTAssertEqual(both.items.count, 1)
    XCTAssertEqual(try PhotoDateRepair.apply(both, cancellation: .init()).repaired, 1)
    let updated = try FileManager.default.attributesOfItem(atPath: file.path)
    for key in [FileAttributeKey.creationDate, .modificationDate] {
      XCTAssertEqual(
        try XCTUnwrap(updated[key] as? Date).timeIntervalSince1970, expected.timeIntervalSince1970,
        accuracy: 0.001)
    }
    XCTAssertEqual(try Data(contentsOf: file), bytes)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: root.path), [file.lastPathComponent])
  }

  func testMediaTypeRecursionAndFilenameFallbackOptions() async throws {
    let root = try folder()
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("nested"), withIntermediateDirectories: false)
    for name in ["20121209_015.jpg", "VID_20250704_005959.mp4", "nested/VID_20240607_010203.mov"] {
      try Data("synthetic fixture".utf8).write(to: root.appendingPathComponent(name))
    }
    let videos = try await PhotoDateRepair.scan(
      folder: root, recursive: true, allowFilename: true,
      allowDateOnly: true, images: false, videos: true, cancellation: .init())
    XCTAssertEqual(videos.summary.videos, 2)
    XCTAssertEqual(videos.summary.images, 0)
    XCTAssertEqual(videos.items.count, 2)
    XCTAssertTrue(videos.items.allSatisfy { $0.isVideo && $0.source == .filenameTime })
    let photos = try await PhotoDateRepair.scan(
      folder: root, recursive: true, allowFilename: true,
      allowDateOnly: true, images: true, videos: false, cancellation: .init())
    XCTAssertEqual(photos.items.map(\.relativePath), ["20121209_015.jpg"])
    let topOnly = try await PhotoDateRepair.scan(
      folder: root, recursive: false, allowFilename: true,
      allowDateOnly: true, images: false, videos: true, cancellation: .init())
    XCTAssertEqual(topOnly.items.map(\.relativePath), ["VID_20250704_005959.mp4"])
    let metadataOnly = try await PhotoDateRepair.scan(
      folder: root, recursive: true, allowFilename: false,
      allowDateOnly: false, images: false, videos: true, cancellation: .init())
    XCTAssertTrue(metadataOnly.items.isEmpty)
    XCTAssertEqual(metadataOnly.summary.noDate, 2)
    do {
      _ = try await PhotoDateRepair.scan(
        folder: root, recursive: true, allowFilename: true,
        allowDateOnly: true, images: false, videos: false, cancellation: .init())
      XCTFail("An empty type selection must be rejected")
    } catch {}
  }

  func testChangedVideoWithRestoredDatesIsSkippedAndCancellationDoesNotModifyFiles() async throws {
    let root = try folder()
    let file = root.appendingPathComponent("VID_20250704_005959.mp4")
    try Data("abcdefghij".utf8).write(to: file)
    let originalDates: [FileAttributeKey: Any] = [
      .creationDate: Date(timeIntervalSince1970: 1_700_000_000),
      .modificationDate: Date(timeIntervalSince1970: 1_750_000_000),
    ]
    try FileManager.default.setAttributes(originalDates, ofItemAtPath: file.path)
    let plan = try await PhotoDateRepair.scan(
      folder: root, recursive: true, allowFilename: true,
      allowDateOnly: true, cancellation: .init())
    try Data("klmnopqrst".utf8).write(to: file)
    try FileManager.default.setAttributes(originalDates, ofItemAtPath: file.path)
    let changed = try PhotoDateRepair.apply(plan, cancellation: .init())
    XCTAssertEqual(changed.changed, 1)
    XCTAssertEqual(changed.repaired, 0)
    XCTAssertEqual(try Data(contentsOf: file), Data("klmnopqrst".utf8))
    let fresh = try await PhotoDateRepair.scan(
      folder: root, recursive: true, allowFilename: true,
      allowDateOnly: true, cancellation: .init())
    let token = PhotoRepairCancellation()
    token.cancel()
    let cancelled = try PhotoDateRepair.apply(fresh, cancellation: token)
    XCTAssertTrue(cancelled.cancelled)
    XCTAssertEqual(cancelled.repaired, 0)
    XCTAssertEqual(
      try FileManager.default.attributesOfItem(atPath: file.path)[.creationDate] as? Date,
      originalDates[.creationDate] as? Date)
  }
}
