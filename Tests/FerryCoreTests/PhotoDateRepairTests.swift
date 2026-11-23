import CoreGraphics
import Darwin
import Foundation
import ImageIO
import XCTest

@testable import FerryCore

final class PhotoDateRepairTests: XCTestCase {
  private func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ferry-photo-dates-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  private func image(_ folder: URL, _ name: String, original: String? = nil) throws -> URL {
    let url = folder.appendingPathComponent(name)
    let bytes = Data([255, 255, 255, 255])
    let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
    let image = try XCTUnwrap(
      CGImage(
        width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
    let properties: [CFString: Any] =
      original.map { [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: $0]] }
      ?? [:]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    try FileManager.default.setAttributes(
      [
        .creationDate: Date(timeIntervalSince1970: 1_700_000_000),
        .modificationDate: Date(timeIntervalSince1970: 1_750_000_000),
      ], ofItemAtPath: url.path)
    return url
  }

  func testExifWinsAndRepairPreservesImageBytesAndModificationDate() async throws {
    let root = try folder()
    let file = try image(root, "20130607_190722.jpg", original: "2011:12:13 14:15:16")
    let bytes = try Data(contentsOf: file)
    let before = try FileManager.default.attributesOfItem(atPath: file.path)
    let plan = try await PhotoDateRepair.scan(
      folder: root, recursive: true, allowFilename: true, allowDateOnly: true, cancellation: .init()
    )
    XCTAssertEqual(plan.items.count, 1)
    XCTAssertEqual(plan.items[0].source, .exif)
    XCTAssertEqual(
      try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date,
      before[.modificationDate] as? Date, "Scanning must not change dates")
    let result = try PhotoDateRepair.apply(plan, cancellation: .init())
    XCTAssertEqual(result.repaired, 1, result.issues.map(\.message).joined())
    XCTAssertEqual(result.failed, 0)
    XCTAssertEqual(try Data(contentsOf: file), bytes)
    let after = try FileManager.default.attributesOfItem(atPath: file.path)
    XCTAssertEqual(after[.modificationDate] as? Date, before[.modificationDate] as? Date)
    XCTAssertEqual(
      try XCTUnwrap(after[.creationDate] as? Date).timeIntervalSince1970,
      plan.items[0].targetDate.timeIntervalSince1970, accuracy: 0.001)
    let rescan = try await PhotoDateRepair.scan(
      folder: root, recursive: true,
      allowFilename: true, allowDateOnly: true, cancellation: .init())
    XCTAssertTrue(rescan.items.isEmpty)
  }

  func testCreationRepairDoesNotDependOnMatchingModificationDate() async throws {
    let root = try folder()
    let file = try image(root, "photo.jpg", original: "2013:06:07 19:07:22")
    let target = try XCTUnwrap(PhotoDateRepair.parseDate("2013:06:07 19:07:22"))
    try FileManager.default.setAttributes([.modificationDate: target], ofItemAtPath: file.path)
    try FileManager.default.setAttributes(
      [.creationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: file.path)
    let plan = try await PhotoDateRepair.scan(
      folder: root, recursive: true, allowFilename: true, allowDateOnly: true, cancellation: .init()
    )
    XCTAssertEqual(
      plan.items.count, 1,
      "An already correct modification date must not hide a wrong creation date")
    XCTAssertEqual(plan.items.first?.originalDate, Date(timeIntervalSince1970: 1_700_000_000))
    let result = try PhotoDateRepair.apply(plan, cancellation: .init())
    XCTAssertEqual(result.repaired, 1, result.issues.map(\.message).joined())
    let changedModification = Date(timeIntervalSince1970: 1_780_000_000)
    try FileManager.default.setAttributes(
      [.modificationDate: changedModification], ofItemAtPath: file.path)
    let again = try await PhotoDateRepair.scan(
      folder: root, recursive: true, allowFilename: true, allowDateOnly: true, cancellation: .init()
    )
    XCTAssertTrue(
      again.items.isEmpty,
      "A correct creation date must stay unchanged even if the modification date differs")
    XCTAssertEqual(again.summary.unchanged, 1)
  }

  func testOptionalModificationRepairUpdatesBothDatesEvenWhenCreationIsCorrect() async throws {
    let root = try folder()
    let file = try image(root, "20130607_190722.jpg")
    let target = try XCTUnwrap(
      PhotoDateRepair.dateFromFilename(file.lastPathComponent, allowDateOnly: true)?.date)
    try FileManager.default.setAttributes([.creationDate: target], ofItemAtPath: file.path)
    let bytes = try Data(contentsOf: file)
    let creationOnly = try await PhotoDateRepair.scan(
      folder: root, recursive: true, allowFilename: true, allowDateOnly: true, cancellation: .init()
    )
    XCTAssertTrue(creationOnly.items.isEmpty)
    XCTAssertFalse(creationOnly.repairModificationDate)
    let both = try await PhotoDateRepair.scan(
      folder: root, recursive: true, allowFilename: true, allowDateOnly: true,
      repairModificationDate: true, cancellation: .init())
    XCTAssertEqual(both.items.count, 1)
    XCTAssertTrue(both.repairModificationDate)
    let result = try PhotoDateRepair.apply(both, cancellation: .init())
    XCTAssertEqual(result.repaired, 1, result.issues.map(\.message).joined())
    let after = try FileManager.default.attributesOfItem(atPath: file.path)
    for key in [FileAttributeKey.creationDate, .modificationDate] {
      XCTAssertEqual(
        try XCTUnwrap(after[key] as? Date).timeIntervalSince1970, target.timeIntervalSince1970,
        accuracy: 0.001)
    }
    XCTAssertEqual(try Data(contentsOf: file), bytes)
  }

  func testUserFilenameExamplesAndAmbiguousNames() async throws {
    let zone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
    let full = try XCTUnwrap(
      PhotoDateRepair.dateFromFilename("20130607_190722.jpg", allowDateOnly: true, timeZone: zone))
    XCTAssertEqual(full.date, PhotoDateRepair.parseDate("2013:06:07 19:07:22", timeZone: zone))
    XCTAssertEqual(full.source, .filenameTime)
    let day = try XCTUnwrap(
      PhotoDateRepair.dateFromFilename("20121209_015.jpg", allowDateOnly: true, timeZone: zone))
    XCTAssertEqual(day.date, PhotoDateRepair.parseDate("2012:12:09 00:00:00", timeZone: zone))
    XCTAssertEqual(day.source, .filenameDay)
    XCTAssertNil(PhotoDateRepair.dateFromFilename("20121209_015.jpg", allowDateOnly: false))
    for name in [
      "20130230_190722.jpg", "20130607_256199.jpg", "123456789.jpg",
      "20130607_190722_20130608_190722.jpg", "20130607_190722_20121209_015.jpg",
    ] {
      XCTAssertNil(PhotoDateRepair.dateFromFilename(name, allowDateOnly: true), name)
    }
    XCTAssertNotNil(
      PhotoDateRepair.dateFromFilename("IMG_2023-04-05 12.34.56.jpg", allowDateOnly: false))
  }

  func testStrictExifTimeZoneAndLeapDateValidation() {
    XCTAssertEqual(
      PhotoDateRepair.parseDate("2024:02:29 12:00:00", offset: "+08:00"),
      PhotoDateRepair.parseDate("2024:02:29 04:00:00", offset: "+00:00"))
    XCTAssertNil(PhotoDateRepair.parseDate("2023:02:29 12:00:00"))
    XCTAssertNil(PhotoDateRepair.parseDate("2024:02:29 25:00:00"))
    XCTAssertNil(PhotoDateRepair.parseDate("2024:02:29 12:00:00", offset: "+24:00"))
    XCTAssertNil(PhotoDateRepair.parseDate("2024:02:29 12:00:00", offset: "+-1:00"))
    XCTAssertNil(PhotoDateRepair.parseDate("2024:02:29 12:00:00", subsecond: "bad"))
  }

  func testFilenameFallbackDateOnlyOptionsAndRecursion() async throws {
    let root = try folder()
    _ = try image(root, "20130607_190722.jpg")
    _ = try image(root, "20121209_015.jpg")
    _ = try image(root, "unknown.jpg")
    let nested = root.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    _ = try image(nested, "20200102_030405.jpg")
    let plan = try await PhotoDateRepair.scan(
      folder: root, recursive: true, allowFilename: true, allowDateOnly: true, cancellation: .init()
    )
    XCTAssertEqual(plan.items.count, 3)
    XCTAssertEqual(plan.summary.noDate, 1)
    XCTAssertEqual(plan.summary.fromFilenameDay, 1)
    XCTAssertEqual(plan.summary.fromFilenameTime, 2)
    let strict = try await PhotoDateRepair.scan(
      folder: root, recursive: false, allowFilename: true, allowDateOnly: false,
      cancellation: .init())
    XCTAssertEqual(strict.items.map(\.relativePath), ["20130607_190722.jpg"])
    let exifOnly = try await PhotoDateRepair.scan(
      folder: root, recursive: true, allowFilename: false, allowDateOnly: false,
      cancellation: .init())
    XCTAssertTrue(exifOnly.items.isEmpty)
    XCTAssertEqual(exifOnly.summary.noDate, 4)
    let result = try PhotoDateRepair.apply(plan, cancellation: .init())
    XCTAssertEqual(result.repaired, 3, result.issues.map(\.message).joined())
  }

  func testSymlinksHardLinksAndPhotoLibrariesAreSkipped() async throws {
    let root = try folder()
    let outside = try folder()
    let original = try image(outside, "outside.jpg", original: "2013:06:07 19:07:22")
    let before = try FileManager.default.attributesOfItem(atPath: original.path)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("linked.jpg"), withDestinationURL: original)
    XCTAssertEqual(link(original.path, root.appendingPathComponent("hard.jpg").path), 0)
    let library = root.appendingPathComponent("Photos.photoslibrary")
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    _ = try image(library, "inside.jpg", original: "2013:06:07 19:07:22")
    _ = try image(root, "._20130607_190722.jpg")
    let plan = try await PhotoDateRepair.scan(
      folder: root, recursive: true, allowFilename: true, allowDateOnly: true, cancellation: .init()
    )
    XCTAssertTrue(plan.items.isEmpty)
    XCTAssertGreaterThanOrEqual(plan.summary.linksOrContainers, 3)
    do {
      _ = try await PhotoDateRepair.scan(
        folder: library, recursive: true, allowFilename: true,
        allowDateOnly: true, cancellation: .init())
      XCTFail("Photo libraries must be rejected")
    } catch {}
    XCTAssertEqual(
      try FileManager.default.attributesOfItem(atPath: original.path)[.modificationDate] as? Date,
      before[.modificationDate] as? Date)
  }

  func testChangedFileAndReplacedParentAreNeverModified() async throws {
    for replaceParent in [false, true] {
      let root = try folder()
      let nested = root.appendingPathComponent("nested")
      try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
      let file = try image(nested, "photo.jpg", original: "2013:06:07 19:07:22")
      let plan = try await PhotoDateRepair.scan(
        folder: root, recursive: true, allowFilename: true, allowDateOnly: true,
        cancellation: .init())
      let outside = try folder()
      let other = try image(outside, "photo.jpg", original: "2013:06:07 19:07:22")
      let beforeOther = try FileManager.default.attributesOfItem(atPath: other.path)
      let changed = Date(timeIntervalSince1970: 1_760_000_000)
      if replaceParent {
        try FileManager.default.moveItem(at: nested, to: root.appendingPathComponent("moved"))
        try FileManager.default.createSymbolicLink(at: nested, withDestinationURL: outside)
      } else {
        try FileManager.default.setAttributes([.modificationDate: changed], ofItemAtPath: file.path)
      }
      let result = try PhotoDateRepair.apply(plan, cancellation: .init())
      XCTAssertEqual(result.repaired, 0)
      XCTAssertEqual(result.failed + result.changed, 1)
      XCTAssertEqual(
        try FileManager.default.attributesOfItem(atPath: other.path)[.modificationDate] as? Date,
        beforeOther[.modificationDate] as? Date)
      if !replaceParent {
        XCTAssertEqual(
          try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date,
          changed)
      }
    }
  }

  func testCancellationStopsRemainingFilesAndRootReplacementIsRejected() async throws {
    let root = try folder()
    for number in 1...3 {
      _ = try image(root, "photo-\(number).jpg", original: "2013:06:07 19:07:22")
    }
    let plan = try await PhotoDateRepair.scan(
      folder: root, recursive: true, allowFilename: true, allowDateOnly: true, cancellation: .init()
    )
    let cancellation = PhotoRepairCancellation()
    let result = try PhotoDateRepair.apply(plan, cancellation: cancellation) { progress in
      if progress.repaired == 1 { cancellation.cancel() }
    }
    XCTAssertTrue(result.cancelled)
    XCTAssertEqual(result.repaired, 1)
    let stopped = PhotoRepairCancellation()
    stopped.cancel()
    do {
      _ = try await PhotoDateRepair.scan(
        folder: root, recursive: true, allowFilename: true,
        allowDateOnly: true, cancellation: stopped)
      XCTFail("Cancelled scans must not produce a plan")
    } catch is CancellationError {}
    try FileManager.default.moveItem(at: root, to: root.appendingPathExtension("old"))
    defer { try? FileManager.default.removeItem(at: root.appendingPathExtension("old")) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    XCTAssertThrowsError(try PhotoDateRepair.apply(plan, cancellation: .init()))
  }
}
