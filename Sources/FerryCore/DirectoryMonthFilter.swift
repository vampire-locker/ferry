import Foundation

public enum DirectoryMonthFilter: Hashable, Sendable {
  case all
  case month(Int)
}

public struct DirectoryMonthOption: Identifiable, Equatable, Sendable {
  public let filter: DirectoryMonthFilter
  public let count: Int
  public var id: DirectoryMonthFilter { filter }

  public init(filter: DirectoryMonthFilter, count: Int) {
    self.filter = filter
    self.count = count
  }

  public var title: String {
    switch filter {
    case .all: return L10n.text("全部月份")
    case .month(let month): return L10n.text("\(month) 月（\(count)）")
    }
  }
}
