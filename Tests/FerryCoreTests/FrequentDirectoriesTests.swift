import Foundation
import XCTest

@testable import FerryCore

final class FrequentDirectoriesTests: XCTestCase {
  private func date(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSinceReferenceDate: seconds)
  }

  private func entry(
    id: UUID = UUID(), deviceID: String = "phone", storageID: UInt32 = 1,
    storageName: String = "Internal", components: [String] = ["DCIM", "Camera"],
    visits: Int = 1, lastVisited: TimeInterval = 10
  ) -> FrequentDirectory {
    FrequentDirectory(
      id: id, deviceID: deviceID, storageID: storageID, storageName: storageName,
      components: components, visits: visits, lastVisited: date(lastVisited))
  }

  func testRankingUsesVisitsThenRecencyAndStablePath() throws {
    var history = FrequentDirectoryHistory()
    history.record(
      deviceID: "phone", storageID: 1, storageName: "Internal", components: ["A"], at: date(1))
    history.record(
      deviceID: "phone", storageID: 1, storageName: "Internal", components: ["A"], at: date(2))
    history.record(
      deviceID: "phone", storageID: 1, storageName: "Internal", components: ["B"], at: date(10))
    history.record(
      deviceID: "phone", storageID: 1, storageName: "Internal", components: ["C"], at: date(10))
    let ranked = history.entries(for: "phone", includeHidden: true)
    XCTAssertEqual(ranked.map(\.name), ["A", "B", "C"])
    XCTAssertEqual(ranked.map(\.visits), [2, 1, 1])
    XCTAssertEqual(
      history.entries(for: "phone", includeHidden: true, limit: 2).map(\.name), ["A", "B"])
    XCTAssertTrue(history.entries(for: "phone", includeHidden: true, limit: 0).isEmpty)
    XCTAssertTrue(history.entries(for: "phone", includeHidden: true, limit: -1).isEmpty)
  }

  func testIdentityIsScopedToPhoneStorageAndExactPathComponents() {
    var history = FrequentDirectoryHistory()
    for phone in ["phone", "other-phone"] {
      for storage: UInt32 in [1, 2] {
        for name in ["Camera", "camera", "caf\u{E9}", "cafe\u{301}"] {
          history.record(
            deviceID: phone, storageID: storage, storageName: "Storage \(storage)",
            components: ["DCIM", name], at: date(1))
        }
      }
    }
    XCTAssertEqual(history.entries(for: "phone", includeHidden: true, limit: 100).count, 8)
    XCTAssertEqual(history.entries(for: "other-phone", includeHidden: true, limit: 100).count, 8)
    XCTAssertTrue(history.entries(for: "PHONE", includeHidden: true).isEmpty)
    XCTAssertTrue(history.entries(for: "unknown", includeHidden: true).isEmpty)
    XCTAssertEqual(Set(history.entries(for: "phone", includeHidden: true).map(\.id)).count, 8)
  }

  func testRepeatVisitKeepsIDAndUpdatesStorageNameAndTimeAcrossRestart() throws {
    var history = FrequentDirectoryHistory()
    history.record(
      deviceID: "phone", storageID: 1, storageName: "Internal",
      components: ["DCIM", "Camera"], at: date(1))
    let initial = try XCTUnwrap(history.entries(for: "phone", includeHidden: true).first)
    history.record(
      deviceID: "phone", storageID: 1, storageName: "Renamed storage",
      components: ["DCIM", "Camera"], at: date(2))
    let encoded = try XCTUnwrap(history.encoded())
    var reloaded = FrequentDirectoryHistory(data: encoded)
    let entry = try XCTUnwrap(reloaded.entries(for: "phone", includeHidden: true).first)
    XCTAssertEqual(entry.id, initial.id)
    XCTAssertEqual(entry.visits, 2)
    XCTAssertEqual(entry.lastVisited, date(2))
    XCTAssertEqual(entry.name, "Camera")
    XCTAssertEqual(entry.pathDescription, "Renamed storage/DCIM/Camera")
    let values = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
    XCTAssertEqual(
      Set(values[0].keys),
      ["id", "deviceID", "storageID", "storageName", "components", "visits", "lastVisited"])
    reloaded.remove(id: entry.id)
    XCTAssertTrue(reloaded.entries(for: "phone", includeHidden: true).isEmpty)
    XCTAssertTrue(
      FrequentDirectoryHistory(data: reloaded.encoded()).entries(for: "phone", includeHidden: true)
        .isEmpty)
  }

  func testHiddenFilterChecksEveryComponentAndDoesNotTreatMiddleDotsAsHidden() {
    var history = FrequentDirectoryHistory()
    for components in [[".cache"], ["Photos", ".private", "Album"], ["Photos", "a.b"], ["相册😀"]] {
      history.record(
        deviceID: "phone", storageID: 1, storageName: "Internal", components: components,
        at: date(1))
    }
    XCTAssertEqual(history.entries(for: "phone", includeHidden: true).count, 4)
    XCTAssertEqual(
      Set(history.entries(for: "phone", includeHidden: false).map(\.name)), ["a.b", "相册😀"])
  }

  func testRootUnsafePathsAndInvalidRecordFieldsAreIgnored() {
    var history = FrequentDirectoryHistory()
    let paths: [[String]] = [
      [], [""], ["."], [".."], ["DCIM", ""], ["a/b"], ["a\0b"],
      Array(repeating: "deep", count: 129),
    ]
    for path in paths {
      history.record(
        deviceID: "phone", storageID: 1, storageName: "Internal", components: path, at: date(1))
    }
    history.record(deviceID: "", storageID: 1, storageName: "Internal", components: ["Camera"])
    history.record(
      deviceID: "phone\0bad", storageID: 1, storageName: "Internal", components: ["Camera"])
    history.record(deviceID: "phone", storageID: 0, storageName: "Internal", components: ["Camera"])
    history.record(deviceID: "phone", storageID: 1, storageName: "", components: ["Camera"])
    history.record(
      deviceID: "phone", storageID: 1, storageName: "Bad\0storage", components: ["Camera"])
    history.record(
      deviceID: "phone", storageID: 1, storageName: "Internal", components: ["Camera"],
      at: date(.infinity))
    XCTAssertTrue(history.entries(for: "phone", includeHidden: true).isEmpty)
    history.record(
      deviceID: "phone", storageID: 1, storageName: "Internal",
      components: Array(repeating: "ok", count: 128), at: date(1))
    XCTAssertEqual(history.entries(for: "phone", includeHidden: true).count, 1)
  }

  func testHistoryLimitEvictsLeastRecentlyVisitedAcrossPhonesInsteadOfLowestFrequency() {
    var history = FrequentDirectoryHistory()
    for index in 0..<200 {
      history.record(
        deviceID: index.isMultiple(of: 2) ? "phone" : "other", storageID: 1,
        storageName: "Internal", components: ["Folder \(index)"], at: date(Double(index)))
    }
    for index in 0..<3 {
      history.record(
        deviceID: "phone", storageID: 1, storageName: "Internal", components: ["Folder 0"],
        at: date(Double(1000 + index)))
    }
    history.record(
      deviceID: "phone", storageID: 1, storageName: "Internal", components: ["new"], at: date(200))
    let all =
      history.entries(for: "phone", includeHidden: true, limit: Int.max)
      + history.entries(for: "other", includeHidden: true, limit: Int.max)
    XCTAssertEqual(all.count, 200)
    XCTAssertFalse(all.contains { $0.name == "Folder 1" })
    XCTAssertTrue(all.contains { $0.name == "Folder 0" && $0.visits == 4 })
    XCTAssertTrue(all.contains { $0.name == "new" })
  }

  func testDecodedRecordsAreValidatedDeduplicatedAndVisitsSaturate() throws {
    let oldID = UUID()
    let latestID = UUID()
    let decoded = [
      entry(id: oldID, visits: 9, lastVisited: 1),
      entry(id: latestID, storageName: "Renamed", visits: 2, lastVisited: 2),
      entry(id: latestID, components: ["Duplicate ID"], lastVisited: 1.5),
      entry(components: [".."]), entry(visits: -1), entry(visits: 0), entry(deviceID: ""),
      entry(storageID: 0), entry(storageName: ""),
      entry(components: ["Maximum"], visits: Int.max),
    ]
    var history = FrequentDirectoryHistory(data: try JSONEncoder().encode(decoded))
    XCTAssertEqual(history.entries(for: "phone", includeHidden: true).count, 2)
    let camera = try XCTUnwrap(
      history.entries(for: "phone", includeHidden: true).first { $0.name == "Camera" })
    XCTAssertEqual(camera.id, latestID)
    XCTAssertEqual(camera.storageName, "Renamed")
    XCTAssertEqual(camera.visits, 9, "Duplicate serialized records must not add visit counts")
    history.record(
      deviceID: "phone", storageID: 1, storageName: "Internal", components: ["Maximum"],
      at: date(20))
    XCTAssertEqual(history.entries(for: "phone", includeHidden: true).first?.visits, Int.max)
    XCTAssertNotNil(history.encoded())
  }

  func testOversizedDecodedLibraryIsCappedAndMalformedJSONFallsBackSafely() throws {
    let records = (0..<250).map { entry(components: ["Folder \($0)"], lastVisited: Double($0)) }
    let history = FrequentDirectoryHistory(data: try JSONEncoder().encode(records))
    let all = history.entries(for: "phone", includeHidden: true, limit: Int.max)
    XCTAssertEqual(all.count, 200)
    XCTAssertFalse(all.contains { $0.name == "Folder 49" })
    XCTAssertTrue(all.contains { $0.name == "Folder 50" })
    for malformed in [
      "garbage", "{}", "[null]", "[{\"visits\":9223372036854775808}]", "[{\"id\":\"bad\"}]",
    ] {
      XCTAssertTrue(
        FrequentDirectoryHistory(data: Data(malformed.utf8)).entries(
          for: "phone", includeHidden: true
        ).isEmpty)
    }
    XCTAssertTrue(FrequentDirectoryHistory().entries(for: "phone", includeHidden: true).isEmpty)
    var invalidFields = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(entry())) as? [String: Any])
    invalidFields["visits"] = NSNumber(value: UInt64.max)
    let overflowData = try JSONSerialization.data(withJSONObject: [invalidFields])
    XCTAssertTrue(
      FrequentDirectoryHistory(data: overflowData).entries(for: "phone", includeHidden: true)
        .isEmpty)
  }

  func testConflictingSerializedIDsAreResolvedDeterministically() throws {
    let id = UUID()
    let first = entry(id: id, deviceID: "first-phone")
    let second = entry(id: id, deviceID: "second-phone")
    let forward = FrequentDirectoryHistory(data: try JSONEncoder().encode([first, second]))
    let reversed = FrequentDirectoryHistory(data: try JSONEncoder().encode([second, first]))
    XCTAssertEqual(forward.encoded(), reversed.encoded())
    XCTAssertEqual(forward.entries(for: "first-phone", includeHidden: true).count, 1)
    XCTAssertTrue(forward.entries(for: "second-phone", includeHidden: true).isEmpty)
  }
}
