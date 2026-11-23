import Foundation

/// Persistent directory identity uses names, never session-specific MTP IDs.
public struct FrequentDirectory: Codable, Identifiable, Hashable, Sendable {
  public let id: UUID
  public let deviceID: String
  public let storageID: UInt32
  public let storageName: String
  public let components: [String]
  public let visits: Int
  public let lastVisited: Date

  public init(
    id: UUID = UUID(), deviceID: String, storageID: UInt32, storageName: String,
    components: [String], visits: Int, lastVisited: Date
  ) {
    self.id = id
    self.deviceID = deviceID
    self.storageID = storageID
    self.storageName = storageName
    self.components = components
    self.visits = visits
    self.lastVisited = lastVisited
  }

  public var name: String { components.last ?? "" }
  public var pathDescription: String { ([storageName] + components).joined(separator: "/") }
}

public struct FrequentDirectoryHistory: Sendable {
  private static let maximumEntries = 200

  // String equality normalizes canonically equivalent Unicode spellings.
  // MTP names are opaque path components, so use their exact UTF-8 bytes here.
  private struct PathKey: Hashable {
    let deviceID: Data
    let storageID: UInt32
    let components: [Data]

    init(deviceID: String, storageID: UInt32, components: [String]) {
      self.deviceID = Data(deviceID.utf8)
      self.storageID = storageID
      self.components = components.map { Data($0.utf8) }
    }

    init(_ entry: FrequentDirectory) {
      self.init(deviceID: entry.deviceID, storageID: entry.storageID, components: entry.components)
    }
  }

  private var records: [FrequentDirectory] = []

  public init(data: Data? = nil) {
    guard let data, let decoded = try? JSONDecoder().decode([FrequentDirectory].self, from: data)
    else { return }
    var unique: [PathKey: FrequentDirectory] = [:]
    for entry in decoded where Self.isValid(entry) {
      let key = PathKey(entry)
      if let previous = unique[key] {
        let latest = Self.recentFirst(entry, previous) ? entry : previous
        unique[key] = FrequentDirectory(
          id: latest.id, deviceID: latest.deviceID, storageID: latest.storageID,
          storageName: latest.storageName, components: latest.components,
          visits: max(entry.visits, previous.visits), lastVisited: latest.lastVisited)
      } else {
        unique[key] = entry
      }
    }
    var seenIDs = Set<UUID>()
    records = unique.values.sorted(by: Self.recentFirst).filter { seenIDs.insert($0.id).inserted }
    retainRecentEntries()
  }

  public mutating func record(
    deviceID: String, storageID: UInt32, storageName: String, components: [String],
    at date: Date = Date()
  ) {
    let candidate = FrequentDirectory(
      deviceID: deviceID, storageID: storageID, storageName: storageName,
      components: components, visits: 1, lastVisited: date)
    guard Self.isValid(candidate) else { return }
    let key = PathKey(candidate)
    if let index = records.firstIndex(where: { PathKey($0) == key }) {
      let old = records[index]
      records[index] = FrequentDirectory(
        id: old.id, deviceID: deviceID, storageID: storageID, storageName: storageName,
        components: components, visits: old.visits == Int.max ? Int.max : old.visits + 1,
        lastVisited: date)
    } else {
      records.append(candidate)
    }
    retainRecentEntries()
  }

  public func entries(for deviceID: String, includeHidden: Bool, limit: Int = 8)
    -> [FrequentDirectory]
  {
    guard limit > 0 else { return [] }
    let identity = Data(deviceID.utf8)
    return Array(
      records.filter {
        Data($0.deviceID.utf8) == identity
          && (includeHidden || !$0.components.contains(where: { $0.hasPrefix(".") }))
      }.sorted(by: Self.rankedFirst).prefix(limit))
  }

  public mutating func remove(id: UUID) { records.removeAll { $0.id == id } }

  public func encoded() -> Data? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try? encoder.encode(records)
  }

  private mutating func retainRecentEntries() {
    records = Array(records.sorted(by: Self.recentFirst).prefix(Self.maximumEntries))
  }

  private static func isValid(_ entry: FrequentDirectory) -> Bool {
    guard !entry.deviceID.isEmpty, !entry.deviceID.contains("\0"), entry.storageID != 0,
      !entry.storageName.isEmpty, !entry.storageName.contains("\0"), entry.visits > 0,
      entry.lastVisited.timeIntervalSinceReferenceDate.isFinite,
      !entry.components.isEmpty, entry.components.count <= 128
    else { return false }
    return entry.components.allSatisfy {
      !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\0")
    }
  }

  private static func rankedFirst(_ first: FrequentDirectory, _ second: FrequentDirectory) -> Bool {
    if first.visits != second.visits { return first.visits > second.visits }
    if first.lastVisited != second.lastVisited { return first.lastVisited > second.lastVisited }
    return stableFirst(first, second)
  }

  private static func recentFirst(_ first: FrequentDirectory, _ second: FrequentDirectory) -> Bool {
    if first.lastVisited != second.lastVisited { return first.lastVisited > second.lastVisited }
    if first.visits != second.visits { return first.visits > second.visits }
    return stableFirst(first, second)
  }

  private static func stableFirst(_ first: FrequentDirectory, _ second: FrequentDirectory) -> Bool {
    let firstPath = Data(first.pathDescription.utf8)
    let secondPath = Data(second.pathDescription.utf8)
    if firstPath != secondPath {
      return firstPath.lexicographicallyPrecedes(secondPath)
    }
    if first.storageID != second.storageID { return first.storageID < second.storageID }
    let firstScope = Data(first.deviceID.utf8)
    let secondScope = Data(second.deviceID.utf8)
    if firstScope != secondScope {
      return firstScope.lexicographicallyPrecedes(secondScope)
    }
    let firstComponents = Data(first.components.joined(separator: "/").utf8)
    let secondComponents = Data(second.components.joined(separator: "/").utf8)
    if firstComponents != secondComponents {
      return firstComponents.lexicographicallyPrecedes(secondComponents)
    }
    return first.id.uuidString < second.id.uuidString
  }
}
