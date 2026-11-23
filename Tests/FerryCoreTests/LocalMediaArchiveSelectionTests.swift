import Foundation
import XCTest

@testable import FerryCore

final class LocalMediaArchiveSelectionTests: XCTestCase {
  private func folder() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ferry-archive-selection-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }
  func testOnlySelectedFilesMoveAndReplaceWhileOtherConflictsRemainUntouched() async throws {
    let parent = try folder()
    let root = parent.appendingPathComponent("2022")
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("08月"), withIntermediateDirectories: true)
    let names = (0..<3).map { "VID_20220801_12000\($0).jpg" }
    for (index, name) in names.enumerated() {
      try Data("incoming-\(index)".utf8).write(to: root.appendingPathComponent(name))
      if index > 0 {
        try Data("existing-\(index)".utf8).write(to: root.appendingPathComponent("08月/" + name))
      }
    }
    let plan = try await LocalMediaArchive.scan(
      folder: root, recursive: true, images: true, videos: false, cancellation: .init())
    let result = try LocalMediaArchive.apply(
      plan, choices: [:], selectedIDs: [names[0], names[2]], cancellation: .init(),
      resolveConflict: { question in
        XCTAssertEqual(
          question.file.name, names[2],
          "Unselected name conflicts must not ask or reuse Replace All")
        return .init(id: question.id, choice: "replace", applyToAll: true)
      },
      progress: { value in
        XCTAssertEqual(value.total, 2)
        XCTAssertNotEqual(value.currentPath, names[1])
      })
    XCTAssertEqual(result.moved, 2, result.issues.map(\.message).joined())
    XCTAssertEqual(result.replaced, 1)
    XCTAssertEqual(result.failed, 0)
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent(names[1])), Data("incoming-1".utf8))
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent("08月/" + names[1])), Data("existing-1".utf8))
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent("08月/" + names[0])), Data("incoming-0".utf8))
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent("08月/" + names[2])), Data("incoming-2".utf8))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent(names[0]).path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent(names[2]).path))
  }

  func testUnselectedMonthsNeedNoChoiceAndInvalidOrEmptySelectionsCannotMoveFiles() async throws {
    let root = try folder()
    for name in ["20121209_015.jpg", "20130607_190722.jpg"] {
      try Data(name.utf8).write(to: root.appendingPathComponent(name))
    }
    for path in ["2012/12月", "2012/12"] {
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent(path), withIntermediateDirectories: true)
    }
    let plan = try await LocalMediaArchive.scan(
      folder: root, recursive: true, images: true, videos: false, cancellation: .init())
    XCTAssertThrowsError(
      try LocalMediaArchive.apply(
        plan, choices: [:], selectedIDs: ["../outside.jpg"], cancellation: .init()))
    XCTAssertEqual(
      try LocalMediaArchive.apply(plan, choices: [:], selectedIDs: [], cancellation: .init()).moved,
      0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("2013").path))
    let result = try LocalMediaArchive.apply(
      plan, choices: [:], selectedIDs: ["20130607_190722.jpg"], cancellation: .init())
    XCTAssertEqual(result.moved, 1)
    XCTAssertEqual(result.failed, 0)
    XCTAssertEqual(
      try Data(contentsOf: root.appendingPathComponent("20121209_015.jpg")),
      Data("20121209_015.jpg".utf8))
    XCTAssertTrue(
      try FileManager.default.contentsOfDirectory(
        atPath: root.appendingPathComponent("2012/12月").path
      ).isEmpty)
    XCTAssertTrue(
      try FileManager.default.contentsOfDirectory(
        atPath: root.appendingPathComponent("2012/12").path
      ).isEmpty)
  }
}
