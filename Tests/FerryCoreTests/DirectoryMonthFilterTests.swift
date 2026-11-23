import Foundation
import XCTest

@testable import FerryCore

final class DirectoryMonthFilterTests: XCTestCase {
  private func entry(
    _ id: UInt32, _ date: String?, name: String = "photo.jpg", folder: Bool = false
  ) -> RemoteEntry {
    let modified =
      date.flatMap { ISO8601DateFormatter().date(from: $0) }?.timeIntervalSince1970 ?? 0
    return RemoteEntry(
      id: id, storageID: 1, name: name, isDirectory: folder, size: 10, modified: Int64(modified))
  }

  private var rows: [RemoteEntry] {
    [
      entry(1, "2025-01-15T12:00:00Z"), entry(2, "2025-02-15T12:00:00Z"),
      entry(3, "2024-01-15T12:00:00Z"), entry(4, "2025-01-15T12:00:00Z", name: ".hidden.jpg"),
      entry(5, "2025-01-15T12:00:00Z", name: "clip.MP4"), entry(6, nil),
      entry(7, "2025-01-15T12:00:00Z", folder: true),
    ]
  }

  private func evaluate(
    _ rows: [RemoteEntry], year: DirectoryYearFilter = .all,
    month: DirectoryMonthFilter = .all, media: DirectoryMediaFilter = .all,
    hidden: Bool = false, query: String = "",
    cached: DirectoryFilterResult? = nil,
    timeZone: TimeZone = TimeZone(secondsFromGMT: 0)!
  ) -> DirectoryFilterResult {
    DirectoryFilterInput(
      entries: rows, yearIndex: DirectoryYearIndex(rows, timeZone: timeZone),
      yearFilter: year, mediaFilter: media, showHiddenFiles: hidden, query: query,
      cachedYearOptions: cached?.yearOptions, monthFilter: month,
      cachedMonthOptions: cached?.monthOptions
    ).evaluate(checkCancellation: {})
  }

  func testMonthAcrossYearsAndIntersectionExcludeFoldersAndUnknownDates() {
    XCTAssertEqual(evaluate(rows, month: .month(1)).visibleIDs, [1, 3, 5])
    let result = evaluate(rows, year: .year(2025), month: .month(1), media: .images, query: "photo")
    XCTAssertEqual(result.visibleIDs, [1])
    XCTAssertEqual(
      result.monthOptions,
      [
        .init(filter: .all, count: 2), .init(filter: .month(1), count: 1),
        .init(filter: .month(2), count: 1),
      ])
    XCTAssertEqual(
      evaluate(rows, year: .year(2025), month: .month(1), media: .images, hidden: true).visibleIDs,
      [1, 4])
    XCTAssertEqual(evaluate(rows, year: .unknown).visibleIDs, [6])
    XCTAssertTrue(evaluate(rows, year: .unknown, month: .month(1)).visibleIDs.isEmpty)
    XCTAssertTrue(evaluate(rows).visibleIDs.contains(7))
  }

  func testCachedStatisticsMatchFreshMonthSelectionAndSearchDoesNotChangeCounts() {
    let initial = evaluate(rows, year: .year(2025))
    let cached = evaluate(
      rows, year: .year(2025), month: .month(2), query: "no match", cached: initial)
    let fresh = evaluate(rows, year: .year(2025), month: .month(2), query: "no match")
    XCTAssertEqual(cached.monthOptions, fresh.monthOptions)
    XCTAssertEqual(cached.yearOptions, fresh.yearOptions)
    XCTAssertTrue(cached.visibleIDs.isEmpty)
    XCTAssertEqual(cached.monthOptions, initial.monthOptions)
    XCTAssertEqual(evaluate(rows, year: .year(2024)).monthOptions.last?.filter, .month(1))
  }

  func testEmptyActiveMonthIsPreservedWhenContentsChange() {
    let result = evaluate([entry(2, "2025-02-15T12:00:00Z")], year: .year(2025), month: .month(1))
    XCTAssertTrue(result.visibleIDs.isEmpty)
    XCTAssertTrue(result.monthOptions.contains(.init(filter: .month(1), count: 0)))
  }

  func testLocalCalendarHandlesMonthAndYearBoundaries() {
    let boundary = entry(1, "2025-01-01T00:30:00Z")
    let west = DirectoryYearIndex([boundary], timeZone: TimeZone(secondsFromGMT: -3600)!)
    XCTAssertEqual(west.year(for: boundary), 2024)
    XCTAssertEqual(west.month(for: boundary), 12)
    let east = DirectoryYearIndex([boundary], timeZone: TimeZone(secondsFromGMT: 8 * 3600)!)
    XCTAssertEqual(east.year(for: boundary), 2025)
    XCTAssertEqual(east.month(for: boundary), 1)
  }

  func testYearAndMonthFiltersUseLocalModificationDateAtBoundaries() {
    let localZone = TimeZone(secondsFromGMT: 8 * 3600)!
    let rows = [
      entry(1, "2026-02-28T19:31:40+08:00", name: "MVIMG_20260228_193140.jpg"),
      entry(2, "2026-03-01T00:00:00+08:00"),
      entry(3, "2026-12-31T23:59:59+08:00"),
      entry(4, "2027-01-01T00:00:00+08:00"),
      entry(5, "2024-02-29T23:59:59+08:00"),
      // An explicit UTC modification date can differ from the filename's date.
      entry(6, "2026-02-28T19:31:40Z", name: "IMG_20260228_193140.jpg"),
    ]
    XCTAssertEqual(
      evaluate(rows, year: .year(2026), month: .month(2), timeZone: localZone).visibleIDs, [1])
    XCTAssertEqual(
      evaluate(rows, year: .year(2026), month: .month(3), timeZone: localZone).visibleIDs, [2, 6])
    XCTAssertEqual(
      evaluate(rows, year: .year(2026), month: .month(12), timeZone: localZone).visibleIDs, [3])
    XCTAssertEqual(
      evaluate(rows, year: .year(2027), month: .month(1), timeZone: localZone).visibleIDs, [4])
    XCTAssertEqual(
      evaluate(rows, year: .year(2024), month: .month(2), timeZone: localZone).visibleIDs, [5])
  }
}
