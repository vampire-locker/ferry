import Darwin
import Foundation
import XCTest

@testable import FerryCore

final class DuplicatePhotosTests: XCTestCase {
  private func root() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ferry-duplicates-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
  private func file(_ root: URL, _ name: String, _ data: String) throws -> URL {
    let url = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(data.utf8).write(to: url)
    return url
  }
  private func scan(_ root: URL, recursive: Bool = true) throws -> DuplicatePhotoPlan {
    try DuplicatePhotos.scan(folder: root, recursive: recursive, cancellation: .init())
  }

  func testFullHashGroupsDifferentNamesAndDatesButRejectsDifferentBytes() throws {
    let root = try root()
    _ = try file(root, "one.jpg", "identical")
    let second = try file(root, "nested/two.png", "identical")
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)], ofItemAtPath: second.path)
    _ = try file(root, "other.jpg", "different")  // Same length, different hash.
    _ = try file(root, "unique.jpg", "a different length")
    let plan = try scan(root)
    XCTAssertEqual(plan.groups.count, 1)
    XCTAssertEqual(Set(plan.groups[0].photos.map(\.relativePath)), ["one.jpg", "nested/two.png"])
    XCTAssertEqual(plan.summary.hashed, 3)
    XCTAssertEqual(plan.summary.duplicateCopies, 1)
    XCTAssertEqual(plan.summary.duplicateBytes, 9)
    XCTAssertTrue(try scan(root, recursive: false).groups.isEmpty)
  }

  func testSelectedCopiesMoveOnlyThroughTrashAndRetainedBytesStayUntouched() throws {
    let root = try root()
    let photos = root.appendingPathComponent("photos")
    _ = try file(photos, "a.jpg", "same image")
    _ = try file(photos, "b.jpg", "same image")
    _ = try file(photos, "c.jpg", "same image")
    let trash = root.appendingPathComponent("test-trash")
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    let plan = try scan(photos)
    let group = try XCTUnwrap(plan.groups.first)
    let keep = try XCTUnwrap(group.photos.last)
    let keptURL = photos.appendingPathComponent(keep.relativePath)
    let original = try FileManager.default.attributesOfItem(atPath: keptURL.path)
    let result = try DuplicatePhotos.moveToTrash(
      plan, choices: [.init(groupID: group.id, keepID: keep.id)], cancellation: .init(),
      trash: { source in
        try FileManager.default.moveItem(
          at: source, to: trash.appendingPathComponent(source.lastPathComponent))
      })
    XCTAssertEqual(result.moved, 2)
    XCTAssertEqual(result.failed, 0)
    XCTAssertEqual(try Data(contentsOf: keptURL), Data("same image".utf8))
    XCTAssertEqual(
      try FileManager.default.attributesOfItem(atPath: keptURL.path)[.modificationDate] as? Date,
      original[.modificationDate] as? Date)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: photos.path), [keep.relativePath])
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path).count, 2)
  }

  func testTrashFailureNeverFallsBackToDeleting() throws {
    let root = try root()
    _ = try file(root, "a.jpg", "same")
    let copy = try file(root, "b.jpg", "same")
    let plan = try scan(root)
    let group = try XCTUnwrap(plan.groups.first)
    let result = try DuplicatePhotos.moveToTrash(
      plan, choices: [.init(groupID: group.id, keepID: "a.jpg")], cancellation: .init(),
      trash: { _ in throw POSIXError(.EACCES) })
    XCTAssertEqual(result.failed, 1)
    XCTAssertEqual(result.moved, 0)
    XCTAssertEqual(try Data(contentsOf: copy), Data("same".utf8))
  }

  func testChangedOrMissingKeeperAndChangedCopiesAreProtected() throws {
    for mutation in ["keeper", "missing", "copy", "parent"] {
      let root = try root()
      let keep = try file(root, "a.jpg", "same")
      let copy = try file(root, "nested/b.jpg", "same")
      let plan = try scan(root)
      let group = try XCTUnwrap(plan.groups.first)
      switch mutation {
      case "keeper": try Data("edit".utf8).write(to: keep)
      case "missing": try FileManager.default.removeItem(at: keep)
      case "copy": try Data("edit".utf8).write(to: copy)
      default:
        let nested = copy.deletingLastPathComponent()
        try FileManager.default.moveItem(at: nested, to: root.appendingPathComponent("moved"))
        try FileManager.default.createSymbolicLink(
          at: nested, withDestinationURL: root.appendingPathComponent("moved"))
      }
      let result = try DuplicatePhotos.moveToTrash(
        plan, choices: [.init(groupID: group.id, keepID: "a.jpg")], cancellation: .init(),
        trash: { _ in XCTFail("Must not trash changed files") })
      XCTAssertEqual(result.moved, 0, mutation)
      XCTAssertEqual(result.failed + result.skipped, 1, mutation)
    }
  }

  func testHiddenFilesLibrariesLinksAndEmptyImagesAreExcluded() throws {
    let root = try root()
    let outside = try file(try self.root(), "outside.jpg", "same")
    _ = try file(root, "a.jpg", "same")
    _ = try file(root, "._b.jpg", "same")
    _ = try file(root, "Photos.photoslibrary/b.jpg", "same")
    _ = try file(root, "empty.jpg", "")
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("linked.jpg"), withDestinationURL: outside)
    XCTAssertEqual(link(outside.path, root.appendingPathComponent("hard.jpg").path), 0)
    XCTAssertTrue(try scan(root).groups.isEmpty)
  }

  func testInvalidChoiceRootReplacementAndCancellationNeverTrashEverything() throws {
    let root = try root()
    _ = try file(root, "a.jpg", "same")
    _ = try file(root, "b.jpg", "same")
    let plan = try scan(root)
    let group = try XCTUnwrap(plan.groups.first)
    XCTAssertThrowsError(
      try DuplicatePhotos.moveToTrash(
        plan, choices: [.init(groupID: group.id, keepID: "missing.jpg")], cancellation: .init(),
        trash: { _ in XCTFail() }))
    let stopped = PhotoRepairCancellation()
    stopped.cancel()
    XCTAssertThrowsError(
      try DuplicatePhotos.scan(folder: root, recursive: true, cancellation: stopped))
    let result = try DuplicatePhotos.moveToTrash(
      plan, choices: [.init(groupID: group.id, keepID: "a.jpg")], cancellation: stopped,
      trash: { _ in XCTFail() })
    XCTAssertTrue(result.cancelled)
    XCTAssertEqual(result.moved, 0)
    let moved = root.appendingPathExtension("old")
    try FileManager.default.moveItem(at: root, to: moved)
    defer { try? FileManager.default.removeItem(at: moved) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    XCTAssertThrowsError(
      try DuplicatePhotos.moveToTrash(
        plan, choices: [.init(groupID: group.id, keepID: "a.jpg")], cancellation: .init()))
  }

  func testCancellingAfterOneMoveKeepsTheRemainingCopies() throws {
    let root = try root()
    let photos = root.appendingPathComponent("photos")
    for name in ["a.jpg", "b.jpg", "c.jpg"] { _ = try file(photos, name, "same") }
    let plan = try scan(photos)
    let group = try XCTUnwrap(plan.groups.first)
    let cancellation = PhotoRepairCancellation()
    let result = try DuplicatePhotos.moveToTrash(
      plan, choices: [.init(groupID: group.id, keepID: "a.jpg")], cancellation: cancellation,
      trash: { url in
        try FileManager.default.moveItem(at: url, to: root.appendingPathComponent("trashed.jpg"))
        cancellation.cancel()
      })
    XCTAssertTrue(result.cancelled)
    XCTAssertEqual(result.moved, 1)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: photos.path).count, 2)
    XCTAssertEqual(try Data(contentsOf: photos.appendingPathComponent("a.jpg")), Data("same".utf8))
  }

  func testKeeperRemovedDuringCleanupDoesNotTrashRemainingCopies() throws {
    let root = try root()
    let photos = root.appendingPathComponent("photos")
    for name in ["a.jpg", "b.jpg", "c.jpg"] { _ = try file(photos, name, "same") }
    let plan = try scan(photos)
    let group = try XCTUnwrap(plan.groups.first)
    let result = try DuplicatePhotos.moveToTrash(
      plan, choices: [.init(groupID: group.id, keepID: "a.jpg")], cancellation: .init(),
      trash: { url in
        try FileManager.default.moveItem(at: url, to: root.appendingPathComponent("trashed.jpg"))
        try FileManager.default.removeItem(at: photos.appendingPathComponent("a.jpg"))
      })
    XCTAssertEqual(result.moved, 1)
    XCTAssertEqual(result.failed, 1)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: photos.path).count, 1)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("trashed.jpg").path))
  }
}
