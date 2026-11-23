import Darwin
import Foundation
import XCTest

@testable import FerryCore

private final class CompatibilityProgress: @unchecked Sendable {
  private let lock = NSLock()
  private var copying = false
  private var verifying = false
  func record(_ value: MediaArchiveProgress) {
    lock.lock()
    defer { lock.unlock() }
    if value.localCopyTotal > 0 {
      if value.verifyingCopy { verifying = true } else { copying = true }
    }
  }
  var completeStages: Bool {
    lock.lock()
    defer { lock.unlock() }
    return copying && verifying
  }
}

final class ArchiveFileMoveTests: XCTestCase {
  private let unsupported: ArchiveFileMove.Rename = { _, _, _, _ in throw POSIXError(.ENOTSUP) }
  private func folder() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ferry-compat-move-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }
  private func move(
    _ root: URL, token: PhotoRepairCancellation = .init(),
    validatePaths: () throws -> Void = {}, progress: (Int64, Int64, Bool) -> Void = { _, _, _ in }
  ) throws {
    let parent = try LocalImageFiles.openRoot(root)
    defer { close(parent) }
    let input = try LocalImageFiles.openItem(parent, ["source.jpg"])
    defer { close(input) }
    try ArchiveFileMove.move(
      sourceParent: parent, sourceName: "source.jpg", sourceFD: input,
      destinationParent: parent, destinationName: "target.jpg", cancellation: token,
      rename: unsupported, validatePaths: validatePaths, progress: progress)
  }
  private func bytes() -> Data { Data((0..<(2 * 1024 * 1024 + 31)).map { UInt8($0 % 251) }) }

  func testUnsupportedRenameCopiesVerifiesAndPreservesDatesBeforeRemovingSource() throws {
    let root = try folder()
    let source = root.appendingPathComponent("source.jpg")
    let data = bytes()
    try data.write(to: source)
    let dates = try FileManager.default.attributesOfItem(atPath: source.path)
    var copied = false
    var verified = false
    try move(
      root,
      progress: { done, total, verifying in
        XCTAssertTrue(
          FileManager.default.fileExists(atPath: source.path),
          "Never remove the source while copying or verifying")
        XCTAssertEqual(total, Int64(data.count) * (verifying ? 2 : 1))
        if done > 0 { if verifying { verified = true } else { copied = true } }
      })
    let target = root.appendingPathComponent("target.jpg")
    XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    XCTAssertTrue(copied && verified)
    XCTAssertEqual(try Data(contentsOf: target), data)
    let result = try FileManager.default.attributesOfItem(atPath: target.path)
    XCTAssertEqual(dates[.creationDate] as? Date, result[.creationDate] as? Date)
    XCTAssertEqual(dates[.modificationDate] as? Date, result[.modificationDate] as? Date)
  }

  func testCancelledCopyOrVerificationKeepsSourceAndRemovesOnlyTheIncompleteCopy() throws {
    for verification in [false, true] {
      let root = try folder()
      let data = bytes()
      try data.write(to: root.appendingPathComponent("source.jpg"))
      let token = PhotoRepairCancellation()
      XCTAssertThrowsError(
        try move(
          root, token: token,
          progress: { done, _, verifying in
            if done > 0 && verifying == verification { token.cancel() }
          })
      ) { XCTAssertTrue($0 is CancellationError) }
      XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("source.jpg")), data)
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: root.appendingPathComponent("target.jpg").path))
    }
  }

  func testExistingFileAndLinkAreNeverOverwrittenByFallback() throws {
    for symlink in [false, true] {
      let root = try folder()
      try Data("source".utf8).write(to: root.appendingPathComponent("source.jpg"))
      let outside = root.appendingPathComponent("outside.txt")
      try Data("original".utf8).write(to: outside)
      if symlink {
        try FileManager.default.createSymbolicLink(
          at: root.appendingPathComponent("target.jpg"), withDestinationURL: outside)
      } else {
        try Data("original".utf8).write(to: root.appendingPathComponent("target.jpg"))
      }
      XCTAssertThrowsError(try move(root)) { error in
        XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
        XCTAssertEqual((error as NSError).code, NSFileWriteFileExistsError)
      }
      XCTAssertEqual(
        try Data(contentsOf: root.appendingPathComponent("source.jpg")), Data("source".utf8))
      XCTAssertEqual(
        try Data(contentsOf: root.appendingPathComponent("target.jpg")), Data("original".utf8))
      XCTAssertEqual(try Data(contentsOf: outside), Data("original".utf8))
    }
  }

  func testChangedSourceOrCorruptCopyLeavesSourceAndCleansTheCopy() throws {
    for changeSource in [false, true] {
      let root = try folder()
      let data = bytes()
      let source = root.appendingPathComponent("source.jpg")
      let target = root.appendingPathComponent("target.jpg")
      try data.write(to: source)
      var changed = false
      XCTAssertThrowsError(
        try move(
          root,
          progress: { done, _, verifying in
            if !changed && (changeSource ? done > 0 && !verifying : verifying && done == 0) {
              changed = true
              do { try Data("changed".utf8).write(to: changeSource ? source : target) } catch {
                XCTFail(String(describing: error))
              }
            }
          }))
      XCTAssertTrue(changed)
      XCTAssertEqual(try Data(contentsOf: source), changeSource ? Data("changed".utf8) : data)
      XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
  }

  func testReplacedDestinationPathIsNotRemovedByCleanup() throws {
    let root = try folder()
    let source = root.appendingPathComponent("source.jpg")
    let target = root.appendingPathComponent("target.jpg")
    try bytes().write(to: source)
    var changed = false
    XCTAssertThrowsError(
      try move(
        root,
        progress: { done, _, verifying in
          if verifying && done == 0 && !changed {
            changed = true
            do { try Data("another writer".utf8).write(to: target, options: .atomic) } catch {
              XCTFail(String(describing: error))
            }
          }
        }))
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    XCTAssertEqual(try Data(contentsOf: target), Data("another writer".utf8))
  }

  func testChangedRootPreventsSourceRemoval() throws {
    let root = try folder()
    let moved = root.appendingPathExtension("moved")
    addTeardownBlock { try? FileManager.default.removeItem(at: moved) }
    try bytes().write(to: root.appendingPathComponent("source.jpg"))
    let parent = try LocalImageFiles.openRoot(root)
    defer { close(parent) }
    let original = try LocalImageFiles.checkedStat(parent)
    var changed = false
    XCTAssertThrowsError(
      try move(
        root,
        validatePaths: {
          let current = try LocalImageFiles.openRoot(root)
          defer { close(current) }
          guard try LocalImageFiles.checkedStat(current).st_ino == original.st_ino else {
            throw EngineFailure("changed root")
          }
        },
        progress: { done, total, verifying in
          if verifying && done == total && !changed {
            changed = true
            XCTAssertEqual(Darwin.rename(root.path, moved.path), 0)
            do {
              try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            } catch { XCTFail(String(describing: error)) }
          }
        }))
    XCTAssertTrue(changed)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: moved.appendingPathComponent("source.jpg").path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: moved.appendingPathComponent("target.jpg").path))
  }

  func testOtherRenameErrorsDoNotTriggerACopy() throws {
    let root = try folder()
    try Data("source".utf8).write(to: root.appendingPathComponent("source.jpg"))
    let parent = try LocalImageFiles.openRoot(root)
    defer { close(parent) }
    let source = try LocalImageFiles.openItem(parent, ["source.jpg"])
    defer { close(source) }
    XCTAssertThrowsError(
      try ArchiveFileMove.move(
        sourceParent: parent, sourceName: "source.jpg", sourceFD: source,
        destinationParent: parent, destinationName: "target.jpg", cancellation: .init(),
        rename: { _, _, _, _ in throw POSIXError(.EACCES) }, validatePaths: {}))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("target.jpg").path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("source.jpg").path))
  }

  func testSourceRemovalFailurePreservesOriginalAndCleansVerifiedCopy() throws {
    if geteuid() == 0 { throw XCTSkip("Requires normal user permissions") }
    let root = try folder()
    let source = root.appendingPathComponent("source.jpg")
    let destination = root.appendingPathComponent("destination")
    try Data("source".utf8).write(to: source)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let parent = try LocalImageFiles.openRoot(root)
    defer { close(parent) }
    let input = try LocalImageFiles.openItem(parent, ["source.jpg"])
    defer { close(input) }
    let outputParent = try LocalImageFiles.openItem(parent, ["destination"], directory: true)
    defer { close(outputParent) }
    XCTAssertEqual(fchmod(parent, 0o500), 0)
    defer { _ = fchmod(parent, 0o700) }
    XCTAssertThrowsError(
      try ArchiveFileMove.move(
        sourceParent: parent, sourceName: "source.jpg", sourceFD: input,
        destinationParent: outputParent, destinationName: "target.jpg", cancellation: .init(),
        rename: unsupported, validatePaths: {}))
    XCTAssertEqual(try Data(contentsOf: source), Data("source".utf8))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: destination.appendingPathComponent("target.jpg").path))
  }

  func testArchiveEndToEndOnExplicitTestVolumeOrTemporaryFolder() async throws {
    let base =
      ProcessInfo.processInfo.environment["FERRY_ARCHIVE_TEST_VOLUME"].map {
        URL(fileURLWithPath: $0)
      }
      ?? FileManager.default.temporaryDirectory
    let parent = base.appendingPathComponent("ferry-local-archive-test-\(UUID())")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    addTeardownBlock { try FileManager.default.removeItem(at: parent) }
    let root = parent.appendingPathComponent("2022")
    let source = root.appendingPathComponent("VID_20220801_120000.jpg")
    let target = root.appendingPathComponent("08月/VID_20220801_120000.jpg")
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = bytes()
    try data.write(to: source)
    try Data("old target".utf8).write(to: target)
    let before = try FileManager.default.attributesOfItem(atPath: source.path)
    let plan = try await LocalMediaArchive.scan(
      folder: root, recursive: true, images: true, videos: false, cancellation: .init())
    let originalFD = open(source.path, O_RDONLY | O_NOFOLLOW)
    XCTAssertGreaterThanOrEqual(originalFD, 0)
    defer { close(originalFD) }
    let progress = CompatibilityProgress()
    let started = ProcessInfo.processInfo.systemUptime
    let moved = try LocalMediaArchive.apply(
      plan, choices: [:], selectedIDs: [source.lastPathComponent], cancellation: .init(),
      resolveConflict: { .init(id: $0.id, choice: "keepBoth") }, progress: { progress.record($0) })
    XCTAssertFalse(progress.completeStages, "The same-volume move must not fall back to copying")
    if ProcessInfo.processInfo.environment["FERRY_ARCHIVE_TEST_VOLUME"] != nil {
      print("EXFAT_DIRECT_MOVE_SECONDS", ProcessInfo.processInfo.systemUptime - started)
    }
    XCTAssertEqual(moved.moved, 1, moved.issues.map(\.message).joined())
    XCTAssertEqual(moved.failed, 0)
    let numbered = root.appendingPathComponent("08月/VID_20220801_120000 (1).jpg")
    XCTAssertEqual(try Data(contentsOf: numbered), data)
    XCTAssertEqual(try Data(contentsOf: target), Data("old target".utf8))
    let after = try FileManager.default.attributesOfItem(atPath: numbered.path)
    let finalFD = open(numbered.path, O_RDONLY | O_NOFOLLOW)
    XCTAssertGreaterThanOrEqual(finalFD, 0)
    defer { close(finalFD) }
    let originalNode = try LocalImageFiles.checkedStat(originalFD)
    let finalNode = try LocalImageFiles.checkedStat(finalFD)
    XCTAssertEqual(originalNode.st_nlink, 1)
    XCTAssertEqual(originalNode.st_dev, finalNode.st_dev)
    XCTAssertEqual(
      originalNode.st_ino, finalNode.st_ino, "Must retain the original file instead of copying")
    let tolerance = 0.000001
    for key in [FileAttributeKey.creationDate, .modificationDate] {
      XCTAssertEqual(
        try XCTUnwrap(before[key] as? Date).timeIntervalSince1970,
        try XCTUnwrap(after[key] as? Date).timeIntervalSince1970, accuracy: tolerance)
    }
    try Data("next source".utf8).write(to: source)
    let nextPlan = try await LocalMediaArchive.scan(
      folder: root, recursive: true, images: true, videos: false, cancellation: .init())
    let skip = try LocalMediaArchive.apply(
      nextPlan, choices: [:], cancellation: .init(),
      resolveConflict: { .init(id: $0.id, choice: "skip") })
    XCTAssertEqual(skip.skipped, 1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    let replace = try LocalMediaArchive.apply(
      nextPlan, choices: [:], cancellation: .init(),
      resolveConflict: { .init(id: $0.id, choice: "replace") })
    XCTAssertEqual(replace.replaced, 1, replace.issues.map(\.message).joined())
    XCTAssertEqual(try Data(contentsOf: target), Data("next source".utf8))
    XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
  }
}
