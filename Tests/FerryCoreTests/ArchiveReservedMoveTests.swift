import Darwin
import Foundation
import XCTest

@testable import FerryCore

private final class MoveRaceResults: @unchecked Sendable {
  private let lock = NSLock()
  private var winners: [String] = []
  func add(_ name: String) {
    lock.lock()
    winners.append(name)
    lock.unlock()
  }
  var names: [String] {
    lock.lock()
    defer { lock.unlock() }
    return winners
  }
}

final class ArchiveReservedMoveTests: XCTestCase {
  private let unsupported: ArchiveFileMove.Rename = { _, _, _, _ in throw POSIXError(.ENOTSUP) }
  private func folder() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ferry-reserved-move-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    return root
  }
  private func move(
    _ root: URL, token: PhotoRepairCancellation = .init(),
    rename: ArchiveFileMove.Rename = ArchiveFileMove.plainRename,
    validate: () throws -> Void = {},
    progress: (Int64, Int64, Bool) -> Void = { _, _, _ in XCTFail("Unexpected copy") }
  ) throws {
    let parent = try LocalImageFiles.openRoot(root)
    defer { close(parent) }
    let source = try LocalImageFiles.openItem(parent, ["source.jpg"])
    defer { close(source) }
    try ArchiveFileMove.move(
      sourceParent: parent, sourceName: "source.jpg", sourceFD: source,
      destinationParent: parent, destinationName: "target.jpg", cancellation: token,
      allowReservedRename: true, rename: unsupported, reservedRename: rename,
      validatePaths: validate, progress: progress)
  }

  func testReservedMoveKeepsOriginalOpenFileAndDatesWithoutCopying() throws {
    let root = try folder()
    let source = root.appendingPathComponent("source.jpg")
    let target = root.appendingPathComponent("target.jpg")
    let data = Data(repeating: 63, count: 8 << 20)
    try data.write(to: source)
    let fd = open(source.path, O_RDONLY | O_NOFOLLOW)
    defer { close(fd) }
    let before = try LocalImageFiles.checkedStat(fd)
    try move(root)
    let targetFD = open(target.path, O_RDONLY | O_NOFOLLOW)
    defer { close(targetFD) }
    let original = try LocalImageFiles.checkedStat(fd)
    let final = try LocalImageFiles.checkedStat(targetFD)
    XCTAssertEqual(original.st_nlink, 1)
    XCTAssertEqual(original.st_dev, final.st_dev)
    XCTAssertEqual(
      original.st_ino, final.st_ino, "Move the original node rather than copying and removing it")
    XCTAssertEqual(before.st_birthtimespec.tv_sec, final.st_birthtimespec.tv_sec)
    XCTAssertEqual(before.st_birthtimespec.tv_nsec, final.st_birthtimespec.tv_nsec)
    XCTAssertEqual(before.st_mtimespec.tv_sec, final.st_mtimespec.tv_sec)
    XCTAssertEqual(before.st_mtimespec.tv_nsec, final.st_mtimespec.tv_nsec)
    XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    XCTAssertEqual(try Data(contentsOf: target), data)
  }

  func testExistingFileDirectoryAndLinkCannotBeReservedOrOverwritten() throws {
    for kind in 0..<3 {
      let root = try folder()
      try Data("source".utf8).write(to: root.appendingPathComponent("source.jpg"))
      let target = root.appendingPathComponent("target.jpg")
      let outside = root.appendingPathComponent("outside.txt")
      try Data("existing".utf8).write(to: outside)
      if kind == 0 {
        try Data("existing".utf8).write(to: target)
      } else if kind == 1 {
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
      } else {
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
      }
      XCTAssertThrowsError(try move(root)) { error in
        XCTAssertEqual((error as NSError).code, NSFileWriteFileExistsError)
      }
      XCTAssertEqual(
        try Data(contentsOf: root.appendingPathComponent("source.jpg")), Data("source".utf8))
      XCTAssertEqual(try Data(contentsOf: outside), Data("existing".utf8))
      if kind != 1 { XCTAssertEqual(try Data(contentsOf: target), Data("existing".utf8)) }
    }
  }

  func testChangedReservationIsKeptAndSourceIsNotMoved() throws {
    for replacePath in [false, true] {
      let root = try folder()
      let target = root.appendingPathComponent("target.jpg")
      try Data("source".utf8).write(to: root.appendingPathComponent("source.jpg"))
      var checks = 0
      XCTAssertThrowsError(
        try move(
          root,
          validate: {
            checks += 1
            if checks == 2 {
              try Data("external data".utf8).write(to: target, options: replacePath ? .atomic : [])
            }
          }))
      XCTAssertEqual(
        try Data(contentsOf: target), Data("external data".utf8),
        "Never clean a changed placeholder")
      XCTAssertEqual(
        try Data(contentsOf: root.appendingPathComponent("source.jpg")), Data("source".utf8))
    }
  }

  func testCancelledOrChangedPathsRemoveOnlyTheEmptyReservation() throws {
    for cancelled in [false, true] {
      let root = try folder()
      try Data("source".utf8).write(to: root.appendingPathComponent("source.jpg"))
      let token = PhotoRepairCancellation()
      var checks = 0
      XCTAssertThrowsError(
        try move(
          root, token: token,
          validate: {
            checks += 1
            if checks == 2 {
              if cancelled { token.cancel() } else { throw EngineFailure("changed path") }
            }
          }))
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: root.appendingPathComponent("target.jpg").path))
      XCTAssertEqual(
        try Data(contentsOf: root.appendingPathComponent("source.jpg")), Data("source".utf8))
    }
  }

  func testPermissionErrorsDoNotStartCopyingAndCleanTheReservation() throws {
    let root = try folder()
    try Data("source".utf8).write(to: root.appendingPathComponent("source.jpg"))
    XCTAssertThrowsError(try move(root, rename: { _, _, _, _ in throw POSIXError(.EACCES) }))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("target.jpg").path))
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent("source.jpg")), Data("source".utf8))
  }

  func testUnsupportedOrdinaryRenameFallsBackToVerifiedCopy() throws {
    let root = try folder()
    try Data("source".utf8).write(to: root.appendingPathComponent("source.jpg"))
    var copied = false
    try move(root, rename: unsupported, progress: { _, _, _ in copied = true })
    XCTAssertTrue(copied)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("source.jpg").path))
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent("target.jpg")), Data("source".utf8))
  }

  func testCompetingReservedMovesDoNotOverwriteEachOther() throws {
    for _ in 0..<30 {
      let root = try folder()
      for name in ["a.jpg", "b.jpg"] {
        try Data(name.utf8).write(to: root.appendingPathComponent(name))
      }
      let parent = try LocalImageFiles.openRoot(root)
      defer { close(parent) }
      let result = MoveRaceResults()
      let rejectExclusive: ArchiveFileMove.Rename = { _, _, _, _ in throw POSIXError(.ENOTSUP) }
      DispatchQueue.concurrentPerform(iterations: 2) { index in
        let name = index == 0 ? "a.jpg" : "b.jpg"
        do {
          let source = try LocalImageFiles.openItem(parent, [name])
          defer { close(source) }
          try ArchiveFileMove.move(
            sourceParent: parent, sourceName: name, sourceFD: source,
            destinationParent: parent, destinationName: "target.jpg", cancellation: .init(),
            allowReservedRename: true, rename: rejectExclusive, validatePaths: {},
            progress: { _, _, _ in XCTFail("Unexpected copy") })
          result.add(name)
        } catch {
          XCTAssertEqual((error as NSError).code, NSFileWriteFileExistsError)
        }
      }
      XCTAssertEqual(result.names.count, 1)
      let winner = try XCTUnwrap(result.names.first)
      XCTAssertEqual(
        try Data(contentsOf: root.appendingPathComponent("target.jpg")), Data(winner.utf8))
      let loser = winner == "a.jpg" ? "b.jpg" : "a.jpg"
      XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(loser)), Data(loser.utf8))
    }
  }
}
