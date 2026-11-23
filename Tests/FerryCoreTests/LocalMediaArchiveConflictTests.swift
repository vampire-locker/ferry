import Foundation
import XCTest

@testable import FerryCore

private final class ArchiveQuestionLog: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [MediaArchiveConflict] = []
  func append(_ value: MediaArchiveConflict) -> Int {
    lock.lock()
    defer { lock.unlock() }
    values.append(value)
    return values.count
  }
  var questions: [MediaArchiveConflict] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }
}

final class LocalMediaArchiveConflictTests: XCTestCase {
  private func fixture(count: Int = 1) throws -> (root: URL, sources: [URL], targets: [URL]) {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ferry-archive-conflicts-\(UUID())")
    let root = parent.appendingPathComponent("2022")
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("08月"), withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
    var sources: [URL] = []
    var targets: [URL] = []
    for index in 0..<count {
      let name = "VID_20220801_12000\(index).jpg"
      let source = root.appendingPathComponent(name)
      let target = root.appendingPathComponent("08月/" + name)
      try Data("incoming-\(index)".utf8).write(to: source)
      try Data("existing-\(index)".utf8).write(to: target)
      sources.append(source)
      targets.append(target)
    }
    return (root, sources, targets)
  }
  private func scan(_ root: URL) async throws -> MediaArchivePlan {
    try await LocalMediaArchive.scan(
      folder: root, recursive: true, images: true, videos: false, cancellation: .init())
  }

  func testSkipAllKeepsBothFilesAndPolicyResetsForTheNextApply() async throws {
    let value = try fixture(count: 2)
    let log = ArchiveQuestionLog()
    let plan = try await scan(value.root)
    let result = try LocalMediaArchive.apply(
      plan, choices: [:], cancellation: .init(),
      resolveConflict: { question in
        _ = log.append(question)
        return .init(id: question.id, choice: "skip", applyToAll: true)
      })
    XCTAssertEqual(log.questions.count, 1)
    XCTAssertEqual(result.skipped, 2)
    XCTAssertEqual(result.moved, 0)
    XCTAssertEqual(result.failed, 0)
    for index in 0..<2 {
      XCTAssertEqual(try Data(contentsOf: value.sources[index]), Data("incoming-\(index)".utf8))
      XCTAssertEqual(try Data(contentsOf: value.targets[index]), Data("existing-\(index)".utf8))
    }
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(
        atPath: value.root.appendingPathComponent("08月").path
      ).count, 2)
    let nextLog = ArchiveQuestionLog()
    let next = try LocalMediaArchive.apply(
      try await scan(value.root), choices: [:], cancellation: .init(),
      resolveConflict: { question in
        _ = nextLog.append(question)
        return .init(id: question.id, choice: "keepBoth", applyToAll: true)
      })
    XCTAssertEqual(nextLog.questions.count, 1, "The previous skip policy must not persist")
    XCTAssertEqual(next.moved, 2)
    XCTAssertEqual(next.replaced, 0)
    for index in 0..<2 {
      XCTAssertEqual(try Data(contentsOf: value.targets[index]), Data("existing-\(index)".utf8))
      let numbered = value.targets[index].deletingPathExtension().appendingPathExtension("jpg").path
        .replacingOccurrences(of: ".jpg", with: " (1).jpg")
      XCTAssertEqual(
        try Data(contentsOf: URL(fileURLWithPath: numbered)), Data("incoming-\(index)".utf8))
    }
  }

  func testReplaceAllMovesSourceInodesAndPreservesSourceBytesAndDates() async throws {
    let value = try fixture(count: 2)
    let before = try value.sources.map { try FileManager.default.attributesOfItem(atPath: $0.path) }
    let log = ArchiveQuestionLog()
    let result = try LocalMediaArchive.apply(
      try await scan(value.root), choices: [:], cancellation: .init(),
      resolveConflict: { question in
        XCTAssertTrue(question.file.canReplace)
        _ = log.append(question)
        return .init(id: question.id, choice: "replace", applyToAll: true)
      })
    XCTAssertEqual(result.moved, 2, result.issues.map(\.message).joined())
    XCTAssertEqual(result.replaced, 2)
    XCTAssertEqual(result.failed, 0)
    XCTAssertEqual(log.questions.count, 1)
    XCTAssertTrue(result.moves.allSatisfy(\.replaced))
    for index in 0..<2 {
      XCTAssertFalse(FileManager.default.fileExists(atPath: value.sources[index].path))
      XCTAssertEqual(try Data(contentsOf: value.targets[index]), Data("incoming-\(index)".utf8))
      let after = try FileManager.default.attributesOfItem(atPath: value.targets[index].path)
      XCTAssertEqual(before[index][.creationDate] as? Date, after[.creationDate] as? Date)
      XCTAssertEqual(before[index][.modificationDate] as? Date, after[.modificationDate] as? Date)
      XCTAssertEqual(
        before[index][.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
    }
  }

  func testChangedTargetIsAskedAgainEvenAfterReplaceAllWasChosen() async throws {
    let value = try fixture()
    let log = ArchiveQuestionLog()
    let target = value.targets[0]
    let result = try LocalMediaArchive.apply(
      try await scan(value.root), choices: [:], cancellation: .init(),
      resolveConflict: { question in
        if log.append(question) == 1 {
          XCTAssertFalse(question.targetChanged)
          try Data("changed while waiting".utf8).write(to: target)
          return .init(id: question.id, choice: "replace", applyToAll: true)
        }
        XCTAssertTrue(question.targetChanged)
        return .init(id: question.id, choice: "skip")
      })
    XCTAssertEqual(log.questions.count, 2)
    XCTAssertNotEqual(log.questions.first?.id, log.questions.last?.id)
    XCTAssertEqual(result.skipped, 1)
    XCTAssertEqual(result.moved, 0)
    XCTAssertEqual(result.failed, 0)
    XCTAssertEqual(try Data(contentsOf: target), Data("changed while waiting".utf8))
    XCTAssertEqual(try Data(contentsOf: value.sources[0]), Data("incoming-0".utf8))
  }

  func testDirectoriesAndLinksCannotBeReplaced() async throws {
    for link in [false, true] {
      let value = try fixture()
      let target = value.targets[0]
      try FileManager.default.removeItem(at: target)
      let outside = value.root.deletingLastPathComponent().appendingPathComponent("outside.txt")
      try Data("outside".utf8).write(to: outside)
      if link {
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
      } else {
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
      }
      let result = try LocalMediaArchive.apply(
        try await scan(value.root), choices: [:], cancellation: .init(),
        resolveConflict: { question in
          XCTAssertFalse(question.file.canReplace)
          return .init(id: question.id, choice: "replace")
        })
      XCTAssertEqual(result.failed, 1)
      XCTAssertEqual(result.moved, 0)
      XCTAssertTrue(FileManager.default.fileExists(atPath: value.sources[0].path))
      XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
      if link {
        XCTAssertEqual(
          try FileManager.default.destinationOfSymbolicLink(atPath: target.path), outside.path)
      }
    }
  }

  func testSourceChangedOrCancellationAfterQuestionDoesNotReplaceTarget() async throws {
    for cancel in [false, true] {
      let value = try fixture()
      let source = value.sources[0]
      let token = PhotoRepairCancellation()
      let result = try LocalMediaArchive.apply(
        try await scan(value.root), choices: [:], cancellation: token,
        resolveConflict: { question in
          if cancel { token.cancel() } else { try Data("source changed".utf8).write(to: source) }
          return .init(id: question.id, choice: "replace")
        })
      XCTAssertEqual(result.moved, 0)
      XCTAssertEqual(result.cancelled, cancel)
      XCTAssertEqual(result.failed, cancel ? 0 : 1)
      XCTAssertEqual(try Data(contentsOf: value.targets[0]), Data("existing-0".utf8))
      XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
  }

  func testStaleOrUnsupportedDecisionsDoNotMoveFiles() async throws {
    for stale in [false, true] {
      let value = try fixture()
      let result = try LocalMediaArchive.apply(
        try await scan(value.root), choices: [:], cancellation: .init(),
        resolveConflict: { question in
          .init(id: stale ? "stale" : question.id, choice: stale ? "replace" : "directory")
        })
      XCTAssertEqual(result.moved, 0)
      XCTAssertEqual(result.failed, 1)
      XCTAssertEqual(try Data(contentsOf: value.targets[0]), Data("existing-0".utf8))
      XCTAssertTrue(FileManager.default.fileExists(atPath: value.sources[0].path))
    }
  }
  func testReplaceAllAsksAgainForAnUnreplaceableTarget() async throws {
    let value = try fixture(count: 2)
    let plan = try await scan(value.root)
    let second = try XCTUnwrap(plan.items.last)
    let specialTarget = value.root.appendingPathComponent("08月/" + second.relativePath)
    try FileManager.default.removeItem(at: specialTarget)
    try FileManager.default.createDirectory(at: specialTarget, withIntermediateDirectories: false)
    let log = ArchiveQuestionLog()
    let result = try LocalMediaArchive.apply(
      plan, choices: [:], cancellation: .init(),
      resolveConflict: { question in
        if log.append(question) == 1 {
          XCTAssertTrue(question.file.canReplace)
          return .init(id: question.id, choice: "replace", applyToAll: true)
        }
        XCTAssertFalse(question.file.canReplace)
        return .init(id: question.id, choice: "keepBoth")
      })
    XCTAssertEqual(log.questions.count, 2)
    XCTAssertEqual(result.moved, 2, result.issues.map(\.message).joined())
    XCTAssertEqual(result.replaced, 1)
    XCTAssertEqual(result.failed, 0)
    var directory: ObjCBool = false
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: specialTarget.path, isDirectory: &directory))
    XCTAssertTrue(directory.boolValue)
  }

  func testDestinationDirectoryChangedWhileWaitingIsRejected() async throws {
    let value = try fixture()
    let root = value.root
    let result = try LocalMediaArchive.apply(
      try await scan(root), choices: [:], cancellation: .init(),
      resolveConflict: { question in
        try FileManager.default.moveItem(
          at: root.appendingPathComponent("08月"), to: root.appendingPathComponent("saved-month"))
        try FileManager.default.createDirectory(
          at: root.appendingPathComponent("08月"), withIntermediateDirectories: false)
        return .init(id: question.id, choice: "replace")
      })
    XCTAssertEqual(result.failed, 1)
    XCTAssertEqual(result.moved, 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: value.sources[0].path))
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent("saved-month/VID_20220801_120000.jpg")),
      Data("existing-0".utf8))
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("08月").path),
      [])
  }

}
