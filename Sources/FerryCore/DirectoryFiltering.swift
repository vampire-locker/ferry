import Foundation

public struct DirectoryFilterResult: Sendable {
  public let entries: [RemoteEntry]
  public let visibleIDs: Set<UInt32>
  public let hiddenCount: Int
  public let yearOptions: [DirectoryYearOption]
  public let monthOptions: [DirectoryMonthOption]
}

/// An immutable input snapshot, safe to evaluate away from the UI actor.
public struct DirectoryFilterInput: Sendable {
  public let entries: [RemoteEntry]
  public let yearIndex: DirectoryYearIndex
  public let yearFilter: DirectoryYearFilter
  public let monthFilter: DirectoryMonthFilter
  public let mediaFilter: DirectoryMediaFilter
  public let showHiddenFiles: Bool
  public let query: String
  public let cachedYearOptions: [DirectoryYearOption]?
  public let cachedMonthOptions: [DirectoryMonthOption]?

  public init(
    entries: [RemoteEntry], yearIndex: DirectoryYearIndex, yearFilter: DirectoryYearFilter,
    mediaFilter: DirectoryMediaFilter, showHiddenFiles: Bool, query: String,
    cachedYearOptions: [DirectoryYearOption]? = nil,
    monthFilter: DirectoryMonthFilter = .all,
    cachedMonthOptions: [DirectoryMonthOption]? = nil
  ) {
    self.entries = entries
    self.yearIndex = yearIndex
    self.yearFilter = yearFilter
    self.monthFilter = monthFilter
    self.mediaFilter = mediaFilter
    self.showHiddenFiles = showHiddenFiles
    self.query = query
    self.cachedYearOptions = cachedYearOptions
    self.cachedMonthOptions = cachedMonthOptions
  }

  public func evaluate(checkCancellation: () throws -> Void) rethrows -> DirectoryFilterResult {
    var matching: [RemoteEntry] = []
    var visibleIDs = Set<UInt32>()
    var counts: [Int: Int] = [:]
    var unknown = 0
    var hiddenCount = 0
    var monthCounts: [Int: Int] = [:]
    var monthTotal = 0
    for (offset, entry) in entries.enumerated() {
      if offset % 256 == 0 { try checkCancellation() }
      guard mediaFilter.matches(entry) else { continue }
      let hidden = entry.isHidden
      if cachedYearOptions == nil && !entry.isDirectory && (showHiddenFiles || !hidden) {
        if let year = yearIndex.year(for: entry) {
          counts[year, default: 0] += 1
        } else {
          unknown += 1
        }
      }
      guard yearIndex.matches(entry, filter: yearFilter) else { continue }
      if cachedMonthOptions == nil && !entry.isDirectory && (showHiddenFiles || !hidden) {
        monthTotal += 1
        if let month = yearIndex.month(for: entry) { monthCounts[month, default: 0] += 1 }
      }
      guard yearIndex.matchesMonth(entry, filter: monthFilter) else { continue }
      if hidden && !showHiddenFiles {
        hiddenCount += 1
        continue
      }
      guard query.isEmpty || entry.name.localizedCaseInsensitiveContains(query) else { continue }
      matching.append(entry)
      visibleIDs.insert(entry.id)
    }
    if let cachedYearOptions {
      for option in cachedYearOptions where option.count > 0 {
        switch option.filter {
        case .year(let year): counts[year] = option.count
        case .unknown: unknown = option.count
        case .all: break
        }
      }
    }
    // An empty active year must not silently broaden a filtered backup.
    if case .year(let selected) = yearFilter, counts[selected] == nil { counts[selected] = 0 }
    var options =
      [DirectoryYearOption(filter: .all, count: counts.values.reduce(unknown, +))]
      + counts.keys.sorted(by: >).map {
        DirectoryYearOption(filter: .year($0), count: counts[$0] ?? 0)
      }
    if unknown > 0 || yearFilter == .unknown {
      options.append(DirectoryYearOption(filter: .unknown, count: unknown))
    }
    if let cachedMonthOptions {
      for option in cachedMonthOptions {
        switch option.filter {
        case .all: monthTotal = option.count
        case .month(let month) where option.count > 0: monthCounts[month] = option.count
        default: break
        }
      }
    }
    // Refresh and year/type changes must preserve an empty active month.
    if case .month(let selected) = monthFilter, monthCounts[selected] == nil {
      monthCounts[selected] = 0
    }
    let months =
      [DirectoryMonthOption(filter: .all, count: monthTotal)]
      + monthCounts.keys.sorted().map {
        DirectoryMonthOption(filter: .month($0), count: monthCounts[$0] ?? 0)
      }
    return DirectoryFilterResult(
      entries: matching, visibleIDs: visibleIDs, hiddenCount: hiddenCount, yearOptions: options,
      monthOptions: months)
  }
}
