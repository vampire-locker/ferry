import Foundation

public enum DirectoryOrdering {
  public static var defaultOrder: [KeyPathComparator<RemoteEntry>] {
    [KeyPathComparator(\RemoteEntry.name)]
  }

  /// Invoke off the main actor for large directories.
  public static func sorted(
    _ entries: [RemoteEntry], using order: [KeyPathComparator<RemoteEntry>] = defaultOrder
  ) -> [RemoteEntry] {
    sort(entries, using: order, checkCancellation: {})
  }

  public static func sortedCancellable(
    _ entries: [RemoteEntry], using order: [KeyPathComparator<RemoteEntry>]
  ) throws -> [RemoteEntry] {
    try Task.checkCancellation()
    return try sort(entries, using: order, checkCancellation: { try Task.checkCancellation() })
  }

  private static func sort(
    _ entries: [RemoteEntry], using order: [KeyPathComparator<RemoteEntry>],
    checkCancellation: () throws -> Void
  ) rethrows -> [RemoteEntry] {
    let comparators = order.isEmpty ? defaultOrder : order
    var comparisons = 0
    return try entries.sorted {
      comparisons += 1
      if comparisons % 256 == 0 { try checkCancellation() }
      if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
      for comparator in comparators {
        let comparison: ComparisonResult
        if comparator.keyPath == \RemoteEntry.name || comparator.keyPath == \RemoteEntry.kind {
          let left = comparator.keyPath == \RemoteEntry.name ? $0.name : $0.kind
          let right = comparator.keyPath == \RemoteEntry.name ? $1.name : $1.kind
          let natural = left.localizedStandardCompare(right)
          comparison = comparator.order == .forward ? natural : natural.reversed
        } else {
          comparison = comparator.compare($0, $1)
        }
        if comparison != .orderedSame { return comparison == .orderedAscending }
      }
      // Equal primary values retain a deterministic natural-name/handle order.
      let comparison = $0.name.localizedStandardCompare($1.name)
      if comparison == .orderedSame { return $0.id < $1.id }
      return comparison == .orderedAscending
    }
  }
}

extension ComparisonResult {
  fileprivate var reversed: ComparisonResult {
    switch self {
    case .orderedAscending: return .orderedDescending
    case .orderedDescending: return .orderedAscending
    case .orderedSame: return .orderedSame
    }
  }
}
