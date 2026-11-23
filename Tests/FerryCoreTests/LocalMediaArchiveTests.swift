import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import FerryCore

final class LocalMediaArchiveTests: XCTestCase {
  private func folder() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ferry-local-archive-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }
  private func image(_ root: URL, _ path: String, original: String? = nil, offset: String? = nil)
    throws -> URL
  {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let provider = try XCTUnwrap(CGDataProvider(data: Data([255, 255, 255, 255]) as CFData))
    let image = try XCTUnwrap(
      CGImage(
        width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
    var exif: [CFString: Any] = [:]
    if let original { exif[kCGImagePropertyExifDateTimeOriginal] = original }
    if let offset { exif[kCGImagePropertyExifOffsetTimeOriginal] = offset }
    CGImageDestinationAddImage(
      destination, image, [kCGImagePropertyExifDictionary: exif] as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return url
  }
  func testExifMonthKeepsRecordedCalendarAndMovesWithoutChangingDatesOrBytes() async throws {
    let root = try folder()
    let file = try image(
      root, "old/20140101_000000.jpg", original: "2022:02:28 23:40:00", offset: "-05:00")
    let bytes = try Data(contentsOf: file)
    let before = try FileManager.default.attributesOfItem(atPath: file.path)
    let plan = try await LocalMediaArchive.scan(
      folder: root, recursive: true, images: true, videos: false, cancellation: .init())
    XCTAssertEqual(plan.items.count, 1)
    XCTAssertEqual(plan.items[0].month.id, "2022/02月")
    XCTAssertEqual(plan.items[0].source, .exif)
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "Scan must not move files")
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("2022").path))
    let result = try LocalMediaArchive.apply(plan, choices: [:], cancellation: .init())
    XCTAssertEqual(result.moved, 1, result.issues.map(\.message).joined())
    let target = root.appendingPathComponent("2022/02月/20140101_000000.jpg")
    XCTAssertEqual(try Data(contentsOf: target), bytes)
    let after = try FileManager.default.attributesOfItem(atPath: target.path)
    XCTAssertEqual(before[.creationDate] as? Date, after[.creationDate] as? Date)
    XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("old").path))
    let again = try await LocalMediaArchive.scan(
      folder: root, recursive: true, images: true, videos: false, cancellation: .init())
    XCTAssertEqual(
      try LocalMediaArchive.apply(again, choices: [:], cancellation: .init()).already, 1)
  }
  func testFilenamePrecedesCreationAndModificationIsNotUsed() async throws {
    let root = try folder()
    _ = try image(root, "20121209_015.jpg")
    let unnamed = try image(root, "unknown.jpg")
    let date = try XCTUnwrap(PhotoDateRepair.parseDate("2010:03:15 12:00:00"))
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1_780_000_000)], ofItemAtPath: unnamed.path)
    try FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: unnamed.path)
    let plan = try await LocalMediaArchive.scan(
      folder: root, recursive: true, images: true, videos: false, cancellation: .init())
    let byPath = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.relativePath, $0) })
    XCTAssertEqual(byPath["20121209_015.jpg"]?.month.id, "2012/12月")
    XCTAssertEqual(byPath["20121209_015.jpg"]?.source, .filename)
    XCTAssertEqual(byPath["unknown.jpg"]?.month.id, "2010/03月")
    XCTAssertEqual(byPath["unknown.jpg"]?.source, .creation)
  }
  func testExistingMonthsNeedChoiceAndNameCollisionsKeepBoth() async throws {
    let root = try folder()
    _ = try image(root, "one/same.jpg", original: "2022:02:01 12:00:00")
    _ = try image(root, "two/same.jpg", original: "2022:02:01 12:00:00")
    for name in ["2022/02月", "2022/2"] {
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    let old = root.appendingPathComponent("2022/2/same.jpg")
    _ = try image(root, "2022/2/same.jpg", original: "2022:02:02 12:00:00")
    let oldBytes = try Data(contentsOf: old)
    let plan = try await LocalMediaArchive.scan(
      folder: root, recursive: true, images: true, videos: false, cancellation: .init())
    XCTAssertNil(plan.directories.first?.defaultPath)
    XCTAssertThrowsError(try LocalMediaArchive.apply(plan, choices: [:], cancellation: .init()))
    let result = try LocalMediaArchive.apply(
      plan, choices: ["2022/02月": "2022/2"], cancellation: .init())
    XCTAssertEqual(result.moved, 2, result.issues.map(\.message).joined())
    XCTAssertEqual(try Data(contentsOf: old), oldBytes)
    XCTAssertEqual(result.already, 1)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("2022/2/same (1).jpg").path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("2022/2/same (2).jpg").path))
  }
  func testVideoMetadataStringKeepsItsExplicitMonth() throws {
    let zone = try XCTUnwrap(TimeZone(secondsFromGMT: 8 * 3600))
    XCTAssertEqual(
      LocalMediaArchive.monthFromMetadataString("2022-02-28T23:40:00-0500", timeZone: zone)?.id,
      "2022/02月")
    XCTAssertEqual(
      LocalMediaArchive.monthFromMetadataString("2022-02-28T23:40:00.123-05:00", timeZone: zone)?
        .id, "2022/02月")
    XCTAssertNil(LocalMediaArchive.monthFromMetadataString("1904-01-01T00:00:00Z", timeZone: zone))
    XCTAssertNil(LocalMediaArchive.monthFromMetadataString("2023-02-29T00:00:00Z", timeZone: zone))
  }
  func testMediaAndRecursionOptionsAndProtectedFiles() async throws {
    let root = try folder()
    _ = try image(root, "20130607_190722.jpg")
    _ = try image(root, "nested/20121209_015.jpg")
    _ = try image(root, ".hidden.jpg")
    _ = try image(root, "Library.photoslibrary/photo.jpg")
    try Data("not a video".utf8).write(to: root.appendingPathComponent("20180102_030405.mp4"))
    try FileManager.default.createSymbolicLink(
      atPath: root.appendingPathComponent("link.jpg").path,
      withDestinationPath: root.appendingPathComponent("20130607_190722.jpg").path)
    try FileManager.default.linkItem(
      at: root.appendingPathComponent("nested/20121209_015.jpg"),
      to: root.appendingPathComponent("hard.jpg"))
    let photos = try await LocalMediaArchive.scan(
      folder: root, recursive: false, images: true,
      videos: false, cancellation: .init())
    XCTAssertEqual(photos.items.map(\.relativePath), ["20130607_190722.jpg"])
    let videos = try await LocalMediaArchive.scan(
      folder: root, recursive: true, images: false,
      videos: true, cancellation: .init())
    XCTAssertEqual(videos.items.map(\.relativePath), ["20180102_030405.mp4"])
    XCTAssertEqual(videos.items.first?.source, .filename)
    let result = try LocalMediaArchive.apply(photos, choices: [:], cancellation: .init())
    XCTAssertEqual(result.moved, 1, result.issues.map(\.message).joined())
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("2013/06月/20130607_190722.jpg").path))
  }

  func testChangedSourceAndLinkedDestinationAreNotMoved() async throws {
    let root = try folder()
    let file = try image(root, "old/20130607_190722.jpg")
    let plan = try await LocalMediaArchive.scan(
      folder: root, recursive: true, images: true,
      videos: false, cancellation: .init())
    try Data("changed".utf8).write(to: file)
    let changed = try LocalMediaArchive.apply(plan, choices: [:], cancellation: .init())
    XCTAssertEqual(changed.failed, 1)
    XCTAssertEqual(changed.moved, 0)
    let newPlan = try await LocalMediaArchive.scan(
      folder: root, recursive: true, images: true,
      videos: false, cancellation: .init())
    let outside = try folder()
    try FileManager.default.createSymbolicLink(
      atPath: root.appendingPathComponent("2013").path,
      withDestinationPath: outside.path)
    let linked = try LocalMediaArchive.apply(newPlan, choices: [:], cancellation: .init())
    XCTAssertEqual(linked.failed, 1)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    XCTAssertEqual(try Data(contentsOf: file), Data("changed".utf8))
  }

  func testReplacedParentAndRootAreRejected() async throws {
    let root = try folder()
    _ = try image(root, "old/20130607_190722.jpg")
    let plan = try await LocalMediaArchive.scan(
      folder: root, recursive: true, images: true,
      videos: false, cancellation: .init())
    let outside = try folder()
    try FileManager.default.moveItem(
      at: root.appendingPathComponent("old"), to: outside.appendingPathComponent("old"))
    try FileManager.default.createSymbolicLink(
      atPath: root.appendingPathComponent("old").path,
      withDestinationPath: outside.appendingPathComponent("old").path)
    XCTAssertEqual(try LocalMediaArchive.apply(plan, choices: [:], cancellation: .init()).failed, 1)
    let movedRoot = outside.appendingPathComponent("replaced")
    try FileManager.default.moveItem(at: root, to: movedRoot)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    XCTAssertThrowsError(try LocalMediaArchive.apply(plan, choices: [:], cancellation: .init()))
  }

  func testCancellationLeavesCompletedMovesAndRemainingSources() async throws {
    let root = try folder()
    for index in 0..<3 { _ = try image(root, "20130607_190722_\(index).jpg") }
    let plan = try await LocalMediaArchive.scan(
      folder: root, recursive: true, images: true,
      videos: false, cancellation: .init())
    let token = PhotoRepairCancellation()
    let result = try LocalMediaArchive.apply(
      plan, choices: [:], cancellation: token,
      progress: { _ in token.cancel() })
    XCTAssertTrue(result.cancelled)
    XCTAssertEqual(result.moved, 1)
    XCTAssertEqual(result.failed, 0)
    let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path).filter {
      $0.hasSuffix(".jpg")
    }
    XCTAssertEqual(remaining.count, 2)
    let cancelled = PhotoRepairCancellation()
    cancelled.cancel()
    do {
      _ = try await LocalMediaArchive.scan(
        folder: root, recursive: true, images: true, videos: true, cancellation: cancelled)
      XCTFail("Cancelled scans must not produce a plan")
    } catch is CancellationError {}
  }

  func testRealVideoMetadataPrecedesFilename() async throws {
    let root = try folder()
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("engine/internal/device/fixtures/demo.mp4")
    let asset = AVURLAsset(url: fixture)
    let export = try XCTUnwrap(
      AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough))
    let metadata = AVMutableMetadataItem()
    metadata.identifier = .quickTimeMetadataCreationDate
    metadata.value = "2022-02-28T23:40:00-05:00" as NSString
    metadata.dataType = "com.apple.metadata.datatype.UTF-8"
    export.metadata = [metadata]
    export.outputURL = root.appendingPathComponent("20130607_190722.mov")
    export.outputFileType = .mov
    await withCheckedContinuation { continuation in
      export.exportAsynchronously { continuation.resume() }
    }
    XCTAssertEqual(export.status, .completed, export.error?.localizedDescription ?? "")
    let plan = try await LocalMediaArchive.scan(
      folder: root, recursive: true, images: false,
      videos: true, cancellation: .init())
    XCTAssertEqual(plan.items.first?.source, .videoMetadata)
    XCTAssertEqual(plan.items.first?.month.id, "2022/02月")
    let file = try XCTUnwrap(export.outputURL)
    let bytes = try Data(contentsOf: file)
    let dates = try FileManager.default.attributesOfItem(atPath: file.path)
    let result = try LocalMediaArchive.apply(plan, choices: [:], cancellation: .init())
    XCTAssertEqual(result.moved, 1, result.issues.map(\.message).joined())
    let target = root.appendingPathComponent("2022/02月/20130607_190722.mov")
    XCTAssertEqual(try Data(contentsOf: target), bytes)
    let after = try FileManager.default.attributesOfItem(atPath: target.path)
    XCTAssertEqual(dates[.creationDate] as? Date, after[.creationDate] as? Date)
    XCTAssertEqual(dates[.modificationDate] as? Date, after[.modificationDate] as? Date)
  }

  func testVideoContainerCreationPrecedesFilename() async throws {
    let root = try folder()
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("engine/internal/device/fixtures/demo.mp4")
    try FileManager.default.copyItem(
      at: fixture, to: root.appendingPathComponent("20130607_190722.mp4"))
    let plan = try await LocalMediaArchive.scan(
      folder: root, recursive: true, images: false,
      videos: true, cancellation: .init())
    XCTAssertEqual(plan.items.first?.source, .videoMetadata)
    XCTAssertNotEqual(plan.items.first?.month.year, 2013)
  }

  func testYearFolderArchivesOnlyLooseMatchingFilesDirectlyIntoMonths() async throws {
    let parent = try folder()
    let root = parent.appendingPathComponent("2022")
    let loose = try image(root, "VID_20220801_120000.jpg")
    _ = try image(root, "VID_20220101_120000.jpg")
    let differentYear = try image(root, "VID_20211201_120000.jpg")
    // Existing month contents must stay untouched even if their metadata points elsewhere.
    let organized = try image(root, "08月/already.jpg", original: "2024:01:01 12:00:00")
    let nested = try image(root, "other/VID_20220301_120000.jpg")
    let bytes = try Data(contentsOf: organized)
    let plan = try await LocalMediaArchive.scan(
      folder: root, recursive: true, images: true,
      videos: false, cancellation: .init())
    XCTAssertEqual(plan.folderYear, 2022)
    XCTAssertEqual(plan.items.count, 2)
    XCTAssertEqual(plan.summary.images, 3)
    XCTAssertEqual(plan.summary.otherYears, 1)
    XCTAssertEqual(plan.skippedYearItems.first?.path, differentYear.lastPathComponent)
    let byPath = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.relativePath, $0) })
    XCTAssertEqual(
      plan.destination(try XCTUnwrap(byPath[loose.lastPathComponent]), choices: [:]),
      "08月/VID_20220801_120000.jpg")
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("01月").path))
    let result = try LocalMediaArchive.apply(plan, choices: [:], cancellation: .init())
    XCTAssertEqual(result.moved, 2, result.issues.map(\.message).joined())
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("01月/VID_20220101_120000.jpg").path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("08月/VID_20220801_120000.jpg").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("2022").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: differentYear.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    XCTAssertEqual(try Data(contentsOf: organized), bytes)
    let again = try await LocalMediaArchive.scan(
      folder: root, recursive: true, images: true,
      videos: false, cancellation: .init())
    XCTAssertTrue(again.items.isEmpty)
    XCTAssertEqual(again.summary.otherYears, 1)
  }

  func testYearFolderAliasesRequireChoiceAndKeepBothNames() async throws {
    let root = try folder().appendingPathComponent("2022")
    _ = try image(root, "VID_20220801_120000.jpg")
    _ = try image(root, "8月/VID_20220801_120000.jpg")
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("08月"), withIntermediateDirectories: true)
    let plan = try await LocalMediaArchive.scan(
      folder: root, recursive: false, images: true,
      videos: false, cancellation: .init())
    let directory = try XCTUnwrap(plan.directories.first)
    XCTAssertEqual(Set(directory.candidates), ["08月", "8月"])
    XCTAssertNil(directory.defaultPath)
    XCTAssertThrowsError(try LocalMediaArchive.apply(plan, choices: [:], cancellation: .init()))
    let result = try LocalMediaArchive.apply(
      plan, choices: [directory.id: "8月"], cancellation: .init())
    XCTAssertEqual(result.moved, 1, result.issues.map(\.message).joined())
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("8月/VID_20220801_120000 (1).jpg").path))
    XCTAssertNil(LocalMediaArchive.yearFolder(root.appendingPathComponent("2022年")))
  }

}
