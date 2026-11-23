import AVFoundation
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import XCTest

@testable import FerryCore

final class MediaRenameTests: XCTestCase {
  private func folder() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ferry-media-rename-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    return root
  }
  private func image(
    _ root: URL, _ path: String, original: String? = "2015:11:01 14:54:51", offset: String? = nil,
    digitized: String? = nil, pngCreation: String? = nil, color: UInt8 = 220
  ) throws -> URL {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let provider = try XCTUnwrap(CGDataProvider(data: Data([color, 100, 100, 255]) as CFData))
    let pixels = try XCTUnwrap(
      CGImage(
        width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let type = url.pathExtension.lowercased() == "png" ? "public.png" : "public.jpeg"
    let output = try XCTUnwrap(
      CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
    var exif: [String: Any] = [:]
    if let original { exif[kCGImagePropertyExifDateTimeOriginal as String] = original }
    if let offset { exif[kCGImagePropertyExifOffsetTimeOriginal as String] = offset }
    if let digitized { exif[kCGImagePropertyExifDateTimeDigitized as String] = digitized }
    var properties: [String: Any] = [kCGImagePropertyExifDictionary as String: exif]
    if let pngCreation {
      properties[kCGImagePropertyPNGDictionary as String] = [
        kCGImagePropertyPNGCreationTime as String: pngCreation
      ]
    }
    CGImageDestinationAddImage(output, pixels, properties as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(output))
    if let pngCreation, type == "public.png" {
      // ImageIO does not write this read-only property; build a real PNG tEXt chunk.
      var data = try Data(contentsOf: url)
      let payload = Data(("Creation Time\0" + pngCreation).utf8)
      let kind = Data("tEXt".utf8)
      var checksum = UInt32.max
      for byte in kind + payload {
        checksum ^= UInt32(byte)
        for _ in 0..<8 { checksum = (checksum >> 1) ^ ((checksum & 1) == 0 ? 0 : 0xedb8_8320) }
      }
      var length = UInt32(payload.count).bigEndian
      var crc = (checksum ^ UInt32.max).bigEndian
      var chunk = withUnsafeBytes(of: &length) { Data($0) }
      chunk.append(kind)
      chunk.append(payload)
      chunk.append(withUnsafeBytes(of: &crc) { Data($0) })
      data.insert(contentsOf: chunk, at: data.count - 12)
      try data.write(to: url)
    }
    try FileManager.default.setAttributes(
      [
        .creationDate: Date(timeIntervalSince1970: 1_700_000_000),
        .modificationDate: Date(timeIntervalSince1970: 1_750_000_000),
      ], ofItemAtPath: url.path)
    return url
  }
  private func scan(_ root: URL, recursive: Bool = true) async throws -> MediaArchivePlan {
    try await LocalMediaArchive.scan(
      folder: root, recursive: recursive, images: true, videos: true,
      operation: .renameMedia, cancellation: .init())
  }
  private func assertDates(_ url: URL, date: Date) throws {
    let values = try FileManager.default.attributesOfItem(atPath: url.path)
    for key in [FileAttributeKey.creationDate, .modificationDate] {
      XCTAssertEqual(
        try XCTUnwrap(values[key] as? Date).timeIntervalSince1970, date.timeIntervalSince1970,
        accuracy: 0.000001)
    }
  }

  func testJPEGAndPNGKeepFormatsAndBytesAndSynchronizeBothDates() async throws {
    let root = try folder()
    let jpeg = try image(root, "old/photo.JpG")
    let png = try image(root, "drawing.png")
    let originalBytes = try [
      jpeg.lastPathComponent: Data(contentsOf: jpeg), png.lastPathComponent: Data(contentsOf: png),
    ]
    let plan = try await scan(root)
    XCTAssertEqual(plan.operation, .renameMedia)
    XCTAssertEqual(plan.items.count, 2)
    XCTAssertTrue(plan.directories.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: jpeg.path), "Scan must not rename")
    XCTAssertEqual(
      plan.items.first { $0.relativePath.hasSuffix("photo.JpG") }?.targetName,
      "IMG_20151101_145451.JpG")
    XCTAssertEqual(
      plan.items.first { $0.relativePath == "drawing.png" }?.targetName, "IMG_20151101_145451.png")
    let result = try LocalMediaArchive.apply(plan, choices: [:], cancellation: .init())
    XCTAssertEqual(result.moved, 2, result.issues.map(\.message).joined())
    XCTAssertEqual(result.datesUpdated, 2)
    XCTAssertEqual(result.failed, 0)
    let date = try XCTUnwrap(PhotoDateRepair.parseDate("2015:11:01 14:54:51"))
    for (target, original) in [
      ("old/IMG_20151101_145451.JpG", "photo.JpG"), ("IMG_20151101_145451.png", "drawing.png"),
    ] {
      let url = root.appendingPathComponent(target)
      XCTAssertEqual(try Data(contentsOf: url), originalBytes[original])
      try assertDates(url, date: date)
    }
    let again = try await scan(root)
    XCTAssertTrue(again.items.allSatisfy { !again.needsProcessing($0, choices: [:]) })
    XCTAssertEqual(
      try LocalMediaArchive.apply(again, choices: [:], cancellation: .init()).already, 2)
  }

  func testMissingOrInvalidMetadataFallsBackToFilenameAfterEmbeddedDates() async throws {
    let root = try folder()
    _ = try image(root, "20130607_190722.jpg", original: nil)
    _ = try image(root, "IMG_20130525_120612.jpg", original: "2023:02:29 12:00:00")
    _ = try image(
      root, "digitized_20130607_190722.jpg", original: nil, digitized: "2015:11:01 14:54:51")
    _ = try image(
      root, "original_20130607_190722.jpg", original: "2015:11:01 23:59:59", offset: "-05:00")
    let plan = try await scan(root)
    XCTAssertEqual(plan.summary.noDate, 0)
    XCTAssertEqual(plan.items.count, 4)
    let filename = try XCTUnwrap(plan.items.first { $0.relativePath == "20130607_190722.jpg" })
    XCTAssertEqual(filename.source, .filename)
    XCTAssertEqual(filename.targetName, "IMG_20130607_190722.jpg")
    XCTAssertEqual(filename.captureDate, PhotoDateRepair.parseDate("2013:06:07 19:07:22"))
    let invalid = try XCTUnwrap(plan.items.first { $0.relativePath == "IMG_20130525_120612.jpg" })
    XCTAssertEqual(invalid.source, .filename)
    XCTAssertEqual(invalid.targetName, invalid.relativePath)
    XCTAssertTrue(invalid.needsDateRepair)
    let digitized = try XCTUnwrap(plan.items.first { $0.relativePath.hasPrefix("digitized_") })
    XCTAssertEqual(digitized.source, .embeddedCreation)
    XCTAssertEqual(digitized.targetName, "IMG_20151101_145451.jpg")
    let original = try XCTUnwrap(plan.items.first { $0.relativePath.hasPrefix("original_") })
    XCTAssertEqual(original.source, .exif)
    XCTAssertEqual(original.targetName, "IMG_20151101_235959.jpg")
    XCTAssertEqual(
      original.captureDate, PhotoDateRepair.parseDate("2015:11:01 23:59:59", offset: "-05:00"))
  }

  func testFilenameFallbackSkipsMissingDateOnlyInvalidAndConflictingTimes() async throws {
    let root = try folder()
    let names = [
      "no-date.jpg", "20121209_015.jpg", "20230229_120000.jpg", "20240229_250000.jpg",
      "20130607_190722_20140607_190722.jpg", "20130607_190722_20130607_190723.jpg",
      "20130607_190722_20140607.jpg",
    ]
    for name in names { _ = try image(root, name, original: nil) }
    let plan = try await scan(root)
    XCTAssertEqual(plan.summary.noDate, names.count)
    XCTAssertEqual(plan.summary.skipped, names.count)
    XCTAssertTrue(plan.items.isEmpty, "File system dates must not supply missing times")
  }

  func testFilenameFallbackScanIsReadOnlyAndSelectedExecutionPreservesContentAndNumbering()
    async throws
  {
    let root = try folder()
    let source = try image(root, "20130607_190722.JpG", original: nil)
    let numbered = try image(root, "IMG_20130525_120612 (1).jpg", original: nil)
    let untouched = try image(root, "20140607_190722.png", original: nil)
    let files = [source, numbered, untouched]
    let bytes = try files.map { try Data(contentsOf: $0) }
    let dates = try files.map { try FileManager.default.attributesOfItem(atPath: $0.path) }
    let plan = try await scan(root)
    XCTAssertEqual(plan.items.count, 3)
    XCTAssertTrue(plan.items.allSatisfy { $0.source == .filename })
    for (index, file) in files.enumerated() {
      let after = try FileManager.default.attributesOfItem(atPath: file.path)
      for key in [FileAttributeKey.creationDate, .modificationDate] {
        XCTAssertEqual(after[key] as? Date, dates[index][key] as? Date, "Scan must be read-only")
      }
    }
    let result = try LocalMediaArchive.apply(
      plan, choices: [:], selectedIDs: [source.lastPathComponent, numbered.lastPathComponent],
      cancellation: .init())
    XCTAssertEqual(result.moved, 1, result.issues.map(\.message).joined())
    XCTAssertEqual(result.datesUpdated, 2)
    XCTAssertEqual(result.failed, 0)
    let target = root.appendingPathComponent("IMG_20130607_190722.JpG")
    XCTAssertEqual(try Data(contentsOf: target), bytes[0])
    XCTAssertEqual(try Data(contentsOf: numbered), bytes[1])
    try assertDates(target, date: XCTUnwrap(PhotoDateRepair.parseDate("2013:06:07 19:07:22")))
    try assertDates(numbered, date: XCTUnwrap(PhotoDateRepair.parseDate("2013:05:25 12:06:12")))
    XCTAssertEqual(try Data(contentsOf: untouched), bytes[2])
    let after = try FileManager.default.attributesOfItem(atPath: untouched.path)
    for key in [FileAttributeKey.creationDate, .modificationDate] {
      XCTAssertEqual(after[key] as? Date, dates[2][key] as? Date)
    }
    let again = try await scan(root)
    for item in again.items where item.relativePath != untouched.lastPathComponent {
      XCTAssertFalse(again.needsProcessing(item, choices: [:]))
    }
  }

  func testVideoWithoutEmbeddedTimeUsesFilenameAndPreservesContent() async throws {
    let root = try folder()
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("engine/internal/device/fixtures/demo.mp4")
    let source = root.appendingPathComponent("clip_20250704_005959.MP4")
    // Clear container creation/modification timestamps in a temporary fixture copy.
    var video = try Data(contentsOf: fixture)
    func integer(_ start: Int, _ count: Int) -> Int {
      video[start..<(start + count)].reduce(0) { ($0 << 8) | Int($1) }
    }
    func clearTimes(_ start: Int, _ end: Int) {
      var position = start
      while position + 8 <= end {
        let size = integer(position, 4)
        let header = size == 1 ? 16 : 8
        guard position + header <= end else { return }
        let length = size == 1 ? integer(position + 8, 8) : (size == 0 ? end - position : size)
        guard length >= header, length <= end - position else { return }
        let kind = String(decoding: video[(position + 4)..<(position + 8)], as: UTF8.self)
        let body = position + header
        if ["moov", "trak", "mdia"].contains(kind) {
          clearTimes(body, position + length)
        } else if ["mvhd", "tkhd", "mdhd"].contains(kind), body + 4 <= position + length {
          let count = video[body] == 1 ? 16 : 8
          if body + 4 + count <= position + length {
            video.replaceSubrange(
              (body + 4)..<(body + 4 + count), with: repeatElement(UInt8(0), count: count))
          }
        }
        position += length
      }
    }
    clearTimes(0, video.count)
    try video.write(to: source)
    let metadata = await MediaCaptureTimestamp.video(
      source, timeZone: .current, cancellation: .init())
    XCTAssertNil(metadata, "This fixture must exercise filename fallback")
    let bytes = try Data(contentsOf: source)
    let plan = try await scan(root)
    let item = try XCTUnwrap(plan.items.first)
    XCTAssertTrue(item.isVideo)
    XCTAssertEqual(item.source, .filename)
    XCTAssertEqual(item.targetName, "VID_20250704_005959.MP4")
    let result = try LocalMediaArchive.apply(plan, choices: [:], cancellation: .init())
    XCTAssertEqual(result.moved, 1, result.issues.map(\.message).joined())
    XCTAssertEqual(result.datesUpdated, 1)
    let target = root.appendingPathComponent("VID_20250704_005959.MP4")
    XCTAssertEqual(try Data(contentsOf: target), bytes)
    try assertDates(target, date: XCTUnwrap(PhotoDateRepair.parseDate("2025:07:04 00:59:59")))
  }

  func testRecordedTimezoneIsUsedForNameAndAbsoluteTimeForFileDates() async throws {
    let root = try folder()
    _ = try image(root, "travel.jpg", original: "2015:11:01 23:59:59", offset: "-05:00")
    let plan = try await scan(root)
    XCTAssertEqual(plan.items.first?.targetName, "IMG_20151101_235959.jpg")
    let date = try XCTUnwrap(PhotoDateRepair.parseDate("2015:11:01 23:59:59", offset: "-05:00"))
    XCTAssertEqual(plan.items.first?.captureDate, date)
    XCTAssertEqual(
      try LocalMediaArchive.apply(plan, choices: [:], cancellation: .init()).datesUpdated, 1)
    try assertDates(root.appendingPathComponent("IMG_20151101_235959.jpg"), date: date)
  }

  func testKeepBothNumberedNamesRemainStableAndDateOnlyRepairWorks() async throws {
    let root = try folder()
    _ = try image(root, "a.jpg", color: 100)
    _ = try image(root, "b.jpg", color: 200)
    let result = try LocalMediaArchive.apply(
      try await scan(root), choices: [:], cancellation: .init(),
      resolveConflict: { .init(id: $0.id, choice: "keepBoth", applyToAll: true) })
    XCTAssertEqual(result.moved, 2, result.issues.map(\.message).joined())
    let numbered = root.appendingPathComponent("IMG_20151101_145451 (1).jpg")
    XCTAssertTrue(FileManager.default.fileExists(atPath: numbered.path))
    let again = try await scan(root)
    XCTAssertTrue(again.items.allSatisfy { !again.needsProcessing($0, choices: [:]) })
    try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: numbered.path)
    let dated = try await scan(root)
    let selected = try XCTUnwrap(dated.items.first { $0.relativePath.hasSuffix("(1).jpg") })
    XCTAssertEqual(dated.destination(selected, choices: [:]), selected.relativePath)
    let fixed = try LocalMediaArchive.apply(
      dated, choices: [:], selectedIDs: [selected.id], cancellation: .init())
    XCTAssertEqual(fixed.moved, 0)
    XCTAssertEqual(fixed.datesUpdated, 1)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("IMG_20151101_145451 (2).jpg").path))
  }

  func testSkipDoesNotChangeNameOrDatesAndExplicitReplaceIsCounted() async throws {
    let root = try folder()
    let source = try image(root, "incoming.jpg", color: 100)
    let target = try image(root, "IMG_20151101_145451.jpg", color: 200)
    let sourceBytes = try Data(contentsOf: source)
    let targetBytes = try Data(contentsOf: target)
    let dates = try FileManager.default.attributesOfItem(atPath: source.path)
    let plan = try await scan(root)
    let skipped = try LocalMediaArchive.apply(
      plan, choices: [:], selectedIDs: ["incoming.jpg"], cancellation: .init(),
      resolveConflict: { .init(id: $0.id, choice: "skip") })
    XCTAssertEqual(skipped.skipped, 1)
    XCTAssertEqual(skipped.datesUpdated, 0)
    XCTAssertEqual(try Data(contentsOf: target), targetBytes)
    XCTAssertEqual(
      try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date,
      dates[.modificationDate] as? Date)
    let replaced = try LocalMediaArchive.apply(
      plan, choices: [:], selectedIDs: ["incoming.jpg"], cancellation: .init(),
      resolveConflict: { .init(id: $0.id, choice: "replace") })
    XCTAssertEqual(replaced.replaced, 1, replaced.issues.map(\.message).joined())
    XCTAssertEqual(replaced.datesUpdated, 1)
    XCTAssertEqual(try Data(contentsOf: target), sourceBytes)
  }

  func testOtherPendingRenameSourcesCannotBeReplaced() async throws {
    let root = try folder()
    _ = try image(root, "incoming.jpg")
    _ = try image(root, "IMG_20151101_145451.jpg", original: "2020:01:02 03:04:05")
    let plan = try await scan(root)
    // Process only the incoming image first with the other image also selected. Whichever order
    // the enumerator uses, both original image contents must survive.
    let result = try LocalMediaArchive.apply(
      plan, choices: [:], cancellation: .init(),
      resolveConflict: { question in
        if question.replacementBlockedReason != nil { XCTAssertFalse(question.file.canReplace) }
        return .init(id: question.id, choice: "keepBoth")
      })
    XCTAssertEqual(result.moved, 2, result.issues.map(\.message).joined())
    XCTAssertEqual(result.failed, 0)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".jpg") }
        .count, 2)
  }

  func testChangedFileAndSelectedScopeAndProtectedDirectories() async throws {
    let root = try folder()
    let selected = try image(root, "selected.jpg")
    let untouched = try image(root, "nested/untouched.jpg")
    _ = try image(root, "Library.photoslibrary/no.jpg")
    _ = try image(root, ".hidden.jpg")
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("linked.jpg"), withDestinationURL: untouched)
    let plan = try await scan(root)
    XCTAssertEqual(
      plan.items.count, 2, "items: \(plan.items.map(\.relativePath)); summary: \(plan.summary)")
    try Data("changed".utf8).write(to: selected)
    let failed = try LocalMediaArchive.apply(
      plan, choices: [:], selectedIDs: ["selected.jpg"], cancellation: .init())
    XCTAssertEqual(failed.failed, 1)
    XCTAssertEqual(failed.moved, 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: untouched.path))
    let topOnly = try await scan(root, recursive: false)
    XCTAssertFalse(topOnly.items.contains { $0.relativePath.contains("/") })
  }

  func testCaseOnlyCanonicalRenameDoesNotPromptOrReplaceAnotherFile() async throws {
    let root = try folder()
    _ = try image(root, "img_20151101_145451.jpg")
    let plan = try await scan(root)
    let result = try LocalMediaArchive.apply(
      plan, choices: [:], cancellation: .init(),
      resolveConflict: { question in
        XCTFail("Case-only renaming of the same file must not ask to replace itself")
        return .init(id: question.id, choice: "skip")
      })
    XCTAssertEqual(result.moved, 1, result.issues.map(\.message).joined())
    XCTAssertEqual(result.replaced, 0)
    XCTAssertTrue(
      try FileManager.default.contentsOfDirectory(atPath: root.path).contains(
        "IMG_20151101_145451.jpg"))
  }

  func testSelectedDateOnlyTargetCanBeExplicitlyReplacedWithoutAStaleSourceFailure() async throws {
    let root = try folder()
    let incoming = try image(root, "incoming.jpg", color: 100)
    _ = try image(root, "IMG_20151101_145451.jpg", color: 200)
    let data = try Data(contentsOf: incoming)
    let result = try LocalMediaArchive.apply(
      try await scan(root), choices: [:], cancellation: .init(),
      resolveConflict: { .init(id: $0.id, choice: "replace") })
    XCTAssertEqual(result.failed, 0, result.issues.map(\.message).joined())
    XCTAssertEqual(result.replaced, 1)
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent("IMG_20151101_145451.jpg")), data)
  }

  func testPNGEmbeddedCreationTimeWithoutExifCanBeUsed() async throws {
    let root = try folder()
    let file = try image(
      root, "created.png", original: nil, pngCreation: "Sun, 01 Nov 2015 14:54:51 +0000")
    let plan = try await scan(root)
    XCTAssertEqual(plan.items.count, 1)
    XCTAssertEqual(plan.items.first?.source, .embeddedCreation)
    XCTAssertEqual(plan.items.first?.targetName, "IMG_20151101_145451.png")
    let fd = open(file.path, O_RDONLY | O_NOFOLLOW)
    defer { close(fd) }
    let cancelled = PhotoRepairCancellation()
    cancelled.cancel()
    XCTAssertNil(PNGCreationTime.read(fd, cancellation: cancelled, timeZone: .current))
    // A corrupt metadata chunk must not supply a guessed capture time.
    var data = try Data(contentsOf: file)
    let year = Data("2015".utf8)
    if let range = data.range(of: year) { data[range.lowerBound + 3] = 52 }
    try data.write(to: file)
    XCTAssertNil(PNGCreationTime.read(fd, cancellation: .init(), timeZone: .current))
  }

  func testVideoMetadataProducesVIDAndPreservesMP4Content() async throws {
    let root = try folder()
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
    let source = root.appendingPathComponent("video_20130607_190722.mp4")
    export.outputURL = source
    export.outputFileType = .mp4
    await withCheckedContinuation { continuation in
      export.exportAsynchronously { continuation.resume() }
    }
    XCTAssertEqual(export.status, .completed, export.error?.localizedDescription ?? "")
    let bytes = try Data(contentsOf: source)
    let plan = try await scan(root)
    XCTAssertEqual(plan.items.first?.source, .videoMetadata)
    XCTAssertEqual(plan.items.first?.targetName, "VID_20250704_005959.mp4")
    let result = try LocalMediaArchive.apply(plan, choices: [:], cancellation: .init())
    XCTAssertEqual(result.moved, 1, result.issues.map(\.message).joined())
    let target = root.appendingPathComponent("VID_20250704_005959.mp4")
    XCTAssertEqual(try Data(contentsOf: target), bytes)
    try assertDates(
      target, date: XCTUnwrap(PhotoDateRepair.parseDate("2025:07:04 00:59:59", offset: "+08:00")))
  }
}
