import Foundation

public enum DirectoryYearFilter: Hashable, Sendable {
  case all
  case year(Int)
  case unknown
}

public struct DirectoryYearOption: Identifiable, Equatable, Sendable {
  public let filter: DirectoryYearFilter
  public let count: Int
  public var id: DirectoryYearFilter { filter }

  public init(filter: DirectoryYearFilter, count: Int) {
    self.filter = filter
    self.count = count
  }

  public var title: String {
    switch filter {
    case .all: return L10n.text("全部年份")
    case .year(let year): return L10n.text("\(year) 年（\(count)）")
    case .unknown: return L10n.text("日期未知（\(count)）")
    }
  }
}

/// Built once alongside directory sorting, then reused by filters and snapshots.
/// Specific year/month filters match files only: selecting a folder would
/// recursively copy dates that cannot be classified from its own modification date.
public struct DirectoryYearIndex: Sendable {
  private let years: [UInt32: Int]
  private let months: [UInt32: Int]

  public init(_ entries: [RemoteEntry] = [], timeZone: TimeZone = .current) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    var values: [UInt32: Int] = [:]
    var monthValues: [UInt32: Int] = [:]
    for entry in entries where !entry.isDirectory && entry.modified > 0 {
      let components = calendar.dateComponents(
        [.year, .month], from: Date(timeIntervalSince1970: Double(entry.modified)))
      if let year = components.year, let month = components.month,
        (1...9999).contains(year), (1...12).contains(month)
      {
        values[entry.id] = year
        monthValues[entry.id] = month
      }
    }
    years = values
    months = monthValues
  }

  public func year(for entry: RemoteEntry) -> Int? { years[entry.id] }
  public func month(for entry: RemoteEntry) -> Int? { months[entry.id] }

  public func matchesMonth(_ entry: RemoteEntry, filter: DirectoryMonthFilter) -> Bool {
    switch filter {
    case .all: return true
    case .month(let month): return !entry.isDirectory && months[entry.id] == month
    }
  }

  public func matches(_ entry: RemoteEntry, filter: DirectoryYearFilter) -> Bool {
    switch filter {
    case .all: return true
    case .year(let year): return !entry.isDirectory && years[entry.id] == year
    case .unknown: return !entry.isDirectory && years[entry.id] == nil
    }
  }
}
