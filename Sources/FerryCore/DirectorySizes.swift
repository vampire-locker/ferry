import Foundation

public enum DirectorySizes {
  /// Merge the complete size response by ID; never publish a partial update or
  /// treat missing/deleted files as zero-byte files. Run off the UI actor.
  public static func applying(
    _ sizes: [RemoteObjectSize], to entries: [RemoteEntry],
    checkCancellation: () throws -> Void = {}
  ) throws -> [RemoteEntry] {
    var values: [UInt32: Int64] = [:]
    values.reserveCapacity(sizes.count)
    for (offset, item) in sizes.enumerated() {
      if offset % 256 == 0 { try checkCancellation() }
      guard item.size >= 0, values.updateValue(item.size, forKey: item.id) == nil else {
        throw EngineFailure(L10n.text("目录内容已变化或大小信息不完整，请刷新后重试。"))
      }
    }
    var result: [RemoteEntry] = []
    result.reserveCapacity(entries.count)
    for (offset, entry) in entries.enumerated() {
      if offset % 256 == 0 { try checkCancellation() }
      if entry.isDirectory {
        result.append(entry.replacingSize(0))
      } else {
        guard let size = values[entry.id] else {
          throw EngineFailure(L10n.text("目录内容已变化或大小信息不完整，请刷新后重试。"))
        }
        result.append(entry.replacingSize(size))
      }
    }
    return result
  }
}
