import CoreGraphics
import Darwin
import Foundation
import ImageIO

public final class PhotoRepairCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var stopped = false
  public init() {}
  public func cancel() {
    lock.lock()
    stopped = true
    lock.unlock()
  }
  public var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }
}

public enum PhotoRepairDateSource: Sendable, Equatable {
  case exif, videoMetadata, filenameTime, filenameDay
  public var title: String {
    switch self {
    case .exif: return L10n.text("EXIF 拍摄时间")
    case .videoMetadata: return L10n.text("视频拍摄元数据")
    case .filenameTime: return L10n.text("文件名日期时间")
    case .filenameDay: return L10n.text("文件名仅含日期（00:00）")
    }
  }
}

private struct PhotoFileStamp: Equatable, Sendable {
  let device: Int32
  let inode: UInt64
  let size: Int64
  let modified: timespec
  let created: timespec
  let changed: timespec
  init(_ value: stat) {
    device = value.st_dev
    inode = value.st_ino
    size = value.st_size
    modified = value.st_mtimespec
    created = value.st_birthtimespec
    changed = value.st_ctimespec
  }
  static func == (a: Self, b: Self) -> Bool {
    a.device == b.device && a.inode == b.inode && a.size == b.size
      && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
      && a.created.tv_sec == b.created.tv_sec && a.created.tv_nsec == b.created.tv_nsec
      && a.changed.tv_sec == b.changed.tv_sec && a.changed.tv_nsec == b.changed.tv_nsec
  }
  var modificationDate: Date {
    Date(timeIntervalSince1970: Double(modified.tv_sec) + Double(modified.tv_nsec) / 1e9)
  }
  var creationDate: Date {
    Date(timeIntervalSince1970: Double(created.tv_sec) + Double(created.tv_nsec) / 1e9)
  }
}

public struct PhotoRepairItem: Identifiable, Sendable {
  public let relativePath: String
  public let isVideo: Bool
  public let originalDate: Date
  public let originalModificationDate: Date
  public let targetDate: Date
  public let source: PhotoRepairDateSource
  public var id: String { relativePath }
  fileprivate let parts: [String]
  fileprivate let stamp: PhotoFileStamp
}

public struct PhotoRepairSummary: Sendable {
  public var images = 0
  public var videos = 0
  public var mediaCount: Int { images + videos }
  public var unchanged = 0
  public var noDate = 0
  public var linksOrContainers = 0
  public var failures = 0
  public var fromExif = 0
  public var fromVideoMetadata = 0
  public var fromFilenameTime = 0
  public var fromFilenameDay = 0
  public init() {}
}

public struct PhotoRepairPlan: Sendable {
  public let folder: URL
  public let items: [PhotoRepairItem]
  public let summary: PhotoRepairSummary
  public let repairModificationDate: Bool
  fileprivate let rootDevice: Int32
  fileprivate let rootInode: UInt64
  fileprivate let tolerance: TimeInterval
}

public struct PhotoRepairIssue: Identifiable, Sendable {
  public let path: String
  public let message: String
  public var id: String { path }
}

public struct PhotoRepairProgress: Sendable {
  public var processed = 0
  public var total = 0
  public var repaired = 0
  public var failed = 0
  public var currentPath = ""
  public init() {}
}

public struct PhotoRepairResult: Sendable {
  public var repaired = 0
  public var changed = 0
  public var failed = 0
  public var cancelled = false
  public var issues: [PhotoRepairIssue] = []
  public init() {}
}

public enum PhotoDateRepair {
  private static func isContainer(_ url: URL, flagged: Bool?) -> Bool {
    LocalImageFiles.isContainer(url, flagged: flagged)
  }
  private static func checkedStat(_ fd: Int32) throws -> stat {
    try LocalImageFiles.checkedStat(fd)
  }
  private static func systemError() -> Error { LocalImageFiles.systemError() }
  private static func openRoot(_ folder: URL) throws -> Int32 {
    try LocalImageFiles.openRoot(folder)
  }
  private static func openItem(_ root: Int32, _ parts: [String], directory: Bool = false) throws
    -> Int32
  {
    try LocalImageFiles.openItem(root, parts, directory: directory)
  }

  public static func scan(
    folder: URL, recursive: Bool, allowFilename: Bool, allowDateOnly: Bool,
    repairModificationDate: Bool = false, images: Bool = true, videos: Bool = true,
    cancellation: PhotoRepairCancellation,
    progress: @Sendable (PhotoRepairProgress) -> Void = { _ in }
  ) async throws -> PhotoRepairPlan {
    let access = folder.startAccessingSecurityScopedResource()
    defer { if access { folder.stopAccessingSecurityScopedResource() } }
    if try isContainer(folder, flagged: folder.resourceValues(forKeys: [.isPackageKey]).isPackage) {
      throw EngineFailure(L10n.text("请选择普通文件夹，不处理照片资料库或应用包。"))
    }
    guard images || videos else { throw EngineFailure(L10n.text("请至少选择图片或视频。")) }
    let root = try openRoot(folder)
    defer { close(root) }
    let rootInfo = try checkedStat(root)
    let timeZone = TimeZone.current
    var fs = statfs()
    var tolerance = 0.001
    if fstatfs(root, &fs) == 0 {
      let kind = withUnsafeBytes(of: &fs.f_fstypename) {
        String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
      }
      if kind == "exfat" || kind == "msdos" { tolerance = 2 }
    }
    var summary = PhotoRepairSummary()
    guard
      let enumerator = FileManager.default.enumerator(
        at: folder,
        includingPropertiesForKeys: [
          .isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey, .isPackageKey,
        ],
        options: [.skipsHiddenFiles],
        errorHandler: { _, _ in
          summary.failures += 1
          return true
        })
    else { throw EngineFailure(L10n.text("无法读取所选文件夹。")) }
    let rootParts = folder.standardizedFileURL.pathComponents
    var items: [PhotoRepairItem] = []
    var lastPublish = -Double.infinity
    while let url = enumerator.nextObject() as? URL {
      if cancellation.isCancelled { throw CancellationError() }
      let components = url.standardizedFileURL.pathComponents
      guard components.starts(with: rootParts) else { continue }
      let parts = Array(components.dropFirst(rootParts.count))
      defer {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastPublish >= 0.1 {
          var update = PhotoRepairProgress()
          update.processed = summary.mediaCount
          update.total = items.count
          update.failed = summary.failures
          update.currentPath = parts.joined(separator: "/")
          progress(update)
          lastPublish = now
        }
      }
      do {
        let values = try url.resourceValues(forKeys: [
          .isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey, .isPackageKey,
        ])
        if values.isSymbolicLink == true || values.isAliasFile == true
          || isContainer(url, flagged: values.isPackage)
        {
          if values.isDirectory == true && values.isSymbolicLink != true
            && values.isAliasFile != true
          {
            enumerator.skipDescendants()
          }
          summary.linksOrContainers += 1
          continue
        }
        if values.isDirectory == true {
          if !recursive {
            enumerator.skipDescendants()
            continue
          }
          let fd = try openItem(root, parts, directory: true)
          let info: stat
          do { info = try checkedStat(fd) } catch {
            close(fd)
            throw error
          }
          close(fd)
          if info.st_dev != rootInfo.st_dev {
            enumerator.skipDescendants()
            summary.linksOrContainers += 1
          }
          continue
        }
        let video = RemoteEntry.isVideoFilename(url.lastPathComponent)
        guard video ? videos : images && RemoteEntry.isImageFilename(url.lastPathComponent) else {
          continue
        }
        if video { summary.videos += 1 } else { summary.images += 1 }
        if summary.mediaCount > 1_000_000 { throw EngineFailure(L10n.text("媒体数量超过安全限制，请分批选择文件夹。")) }
        let fd = try openItem(root, parts)
        defer { close(fd) }
        let info = try checkedStat(fd)
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_dev == rootInfo.st_dev
        else {
          summary.linksOrContainers += 1
          continue
        }
        let before = PhotoFileStamp(info)
        let captured: Date?
        if video {
          captured = await MediaCaptureTimestamp.video(
            url, timeZone: timeZone, cancellation: cancellation)?.date
        } else {
          captured = readExif(fd, cancellation: cancellation, timeZone: timeZone)
        }
        let inferred =
          captured == nil && allowFilename
          ? dateFromFilename(
            url.lastPathComponent, allowDateOnly: allowDateOnly, timeZone: timeZone) : nil
        guard let date = captured ?? inferred?.date else {
          summary.noDate += 1
          continue
        }
        guard before == PhotoFileStamp(try checkedStat(fd)) else {
          summary.failures += 1
          continue
        }
        if abs(before.creationDate.timeIntervalSince(date)) < tolerance
          && (!repairModificationDate
            || abs(before.modificationDate.timeIntervalSince(date)) < tolerance)
        {
          summary.unchanged += 1
          continue
        }
        let source: PhotoRepairDateSource =
          captured != nil ? (video ? .videoMetadata : .exif) : inferred!.source
        switch source {
        case .exif: summary.fromExif += 1
        case .videoMetadata: summary.fromVideoMetadata += 1
        case .filenameTime: summary.fromFilenameTime += 1
        case .filenameDay: summary.fromFilenameDay += 1
        }
        items.append(
          PhotoRepairItem(
            relativePath: parts.joined(separator: "/"), isVideo: video,
            originalDate: before.creationDate,
            originalModificationDate: before.modificationDate,
            targetDate: date, source: source, parts: parts, stamp: before))
      } catch {
        if parts.count > 128 { enumerator.skipDescendants() }
        summary.failures += 1
      }
      if summary.mediaCount > 1_000_000 { throw EngineFailure(L10n.text("媒体数量超过安全限制，请分批选择文件夹。")) }
    }
    if cancellation.isCancelled { throw CancellationError() }
    return PhotoRepairPlan(
      folder: folder, items: items, summary: summary,
      repairModificationDate: repairModificationDate,
      rootDevice: rootInfo.st_dev, rootInode: rootInfo.st_ino, tolerance: tolerance)
  }

  public static func apply(
    _ plan: PhotoRepairPlan, cancellation: PhotoRepairCancellation,
    progress: @Sendable (PhotoRepairProgress) -> Void = { _ in }
  ) throws -> PhotoRepairResult {
    let access = plan.folder.startAccessingSecurityScopedResource()
    defer { if access { plan.folder.stopAccessingSecurityScopedResource() } }
    let root = try openRoot(plan.folder)
    defer { close(root) }
    let rootInfo = try checkedStat(root)
    guard rootInfo.st_dev == plan.rootDevice, rootInfo.st_ino == plan.rootInode else {
      throw EngineFailure(L10n.text("所选文件夹已变化，请重新扫描。"))
    }
    var result = PhotoRepairResult()
    var lastPublish = -Double.infinity
    for (index, item) in plan.items.enumerated() {
      if cancellation.isCancelled {
        result.cancelled = true
        break
      }
      defer {
        let now = ProcessInfo.processInfo.systemUptime
        if !result.cancelled && (now - lastPublish >= 0.1 || index == plan.items.count - 1) {
          var update = PhotoRepairProgress()
          update.processed = index + 1
          update.total = plan.items.count
          update.repaired = result.repaired
          update.failed = result.failed
          update.currentPath = item.relativePath
          progress(update)
          lastPublish = now
        }
      }
      do {
        let fd = try openItem(root, item.parts)
        defer { close(fd) }
        let before = try checkedStat(fd)
        guard before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
          PhotoFileStamp(before) == item.stamp
        else {
          result.changed += 1
          if result.issues.count < 50 {
            result.issues.append(
              .init(path: item.relativePath, message: L10n.text("扫描后文件已变化，已跳过。")))
          }
          continue
        }
        if cancellation.isCancelled {
          result.cancelled = true
          break
        }
        let epoch = item.targetDate.timeIntervalSince1970
        let seconds = floor(epoch)
        let nanos = Int(((epoch - seconds) * 1e9).rounded())
        let target = timespec(
          tv_sec: Int(seconds) + nanos / 1_000_000_000, tv_nsec: nanos % 1_000_000_000)
        if plan.repairModificationDate {
          try setDates(fd, created: target, modified: target)
        } else {
          try setCreationDate(fd, target)
        }
        let after = PhotoFileStamp(try checkedStat(fd))
        let modificationValid =
          plan.repairModificationDate
          ? abs(after.modificationDate.timeIntervalSince(item.targetDate)) <= plan.tolerance
          : after.modified.tv_sec == item.stamp.modified.tv_sec
            && after.modified.tv_nsec == item.stamp.modified.tv_nsec
        guard modificationValid,
          abs(after.creationDate.timeIntervalSince(item.targetDate)) <= plan.tolerance
        else {
          try? setDates(fd, created: item.stamp.created, modified: item.stamp.modified)
          throw EngineFailure(L10n.text("文件系统未能保留所需日期，已尝试恢复原日期。"))
        }
        result.repaired += 1
      } catch {
        result.failed += 1
        if result.issues.count < 50 {
          result.issues.append(.init(path: item.relativePath, message: error.localizedDescription))
        }
      }
    }
    return result
  }

  private struct FileDates {
    var created: timespec
    var modified: timespec
  }
  private static func setCreationDate(_ fd: Int32, _ date: timespec) throws {
    var attributes = attrlist()
    attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
    attributes.commonattr = UInt32(ATTR_CMN_CRTIME)
    var date = date
    guard fsetattrlist(fd, &attributes, &date, MemoryLayout<timespec>.size, 0) == 0 else {
      throw systemError()
    }
  }
  private static func setDates(_ fd: Int32, created: timespec, modified: timespec) throws {
    var attributes = attrlist()
    attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
    attributes.commonattr = UInt32(ATTR_CMN_CRTIME) | UInt32(ATTR_CMN_MODTIME)
    var values = FileDates(created: created, modified: modified)
    guard fsetattrlist(fd, &attributes, &values, MemoryLayout<FileDates>.size, 0) == 0 else {
      throw systemError()
    }
  }

  // Both EXIF and filename dates use the same strict Gregorian validation.
  // An explicit EXIF offset wins; otherwise interpret wall time on this Mac.
  public static func parseDate(
    _ original: String, offset: String? = nil, subsecond: String? = nil,
    timeZone: TimeZone = .current
  ) -> Date? {
    let text = original.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.count == 19 else { return nil }
    let parts = text.components(separatedBy: CharacterSet(charactersIn: ":- T"))
    guard parts.count == 6, parts.map(\.count) == [4, 2, 2, 2, 2, 2],
      parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) })
    else { return nil }
    let numbers = parts.compactMap(Int.init)
    guard numbers.count == 6, (1...9999).contains(numbers[0]) else { return nil }
    var zone = timeZone
    if let offset, !offset.isEmpty {
      let value = Array(offset.trimmingCharacters(in: .whitespacesAndNewlines))
      guard value.count == 6, value[0] == "+" || value[0] == "-", value[3] == ":",
        [value[1], value[2], value[4], value[5]].allSatisfy({ $0.isASCII && $0.isNumber }),
        let h = Int(String(value[1...2])), let m = Int(String(value[4...5])), h <= 23, m <= 59,
        let fixed = TimeZone(secondsFromGMT: (value[0] == "-" ? -1 : 1) * (h * 3600 + m * 60))
      else { return nil }
      zone = fixed
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    var components = DateComponents()
    components.year = numbers[0]
    components.month = numbers[1]
    components.day = numbers[2]
    components.hour = numbers[3]
    components.minute = numbers[4]
    components.second = numbers[5]
    guard let date = calendar.date(from: components) else { return nil }
    let verified = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second], from: date)
    guard verified.year == components.year, verified.month == components.month,
      verified.day == components.day,
      verified.hour == components.hour, verified.minute == components.minute,
      verified.second == components.second
    else { return nil }
    var fraction = 0.0
    if let subsecond, !subsecond.isEmpty {
      guard subsecond.allSatisfy(\.isASCII), subsecond.allSatisfy(\.isNumber),
        let value = Double("0." + subsecond.prefix(9))
      else { return nil }
      fraction = value
    }
    return date.addingTimeInterval(fraction)
  }

  public static func dateFromFilename(
    _ name: String, allowDateOnly: Bool, timeZone: TimeZone = .current
  ) -> (date: Date, source: PhotoRepairDateSource)? {
    let name = (name as NSString).deletingPathExtension as NSString
    let matches = filenameClock.matches(
      in: name as String, range: NSRange(location: 0, length: name.length))
    func build(_ match: NSTextCheckingResult, timed: Bool) -> Date? {
      let fields = (1...(timed ? 6 : 3)).map { name.substring(with: match.range(at: $0)) }
      let date = fields.prefix(3).joined(separator: ":")
      let clock = timed ? fields.suffix(3).joined(separator: ":") : "00:00:00"
      return parseDate(date + " " + clock, timeZone: timeZone)
    }
    let days = filenameDay.matches(
      in: name as String, range: NSRange(location: 0, length: name.length))
    let dayDates = days.compactMap { build($0, timed: false) }
    guard dayDates.count == days.count, Set(dayDates).count <= 1 else { return nil }
    if !matches.isEmpty {
      let dates = matches.compactMap { build($0, timed: true) }
      guard dates.count == matches.count, Set(dates).count == 1, let date = dates.first else {
        return nil
      }
      return (date, .filenameTime)
    }
    guard allowDateOnly else { return nil }
    guard !days.isEmpty, let date = dayDates.first else { return nil }
    return (date, .filenameDay)
  }

  private static let filenameClock = try! NSRegularExpression(
    pattern:
      #"(?<!\d)((?:19|20)\d{2})[-_.]?(\d{2})[-_.]?(\d{2})[T _-]*(\d{2})[:._-]?(\d{2})[:._-]?(\d{2})(?!\d)"#
  )
  private static let filenameDay = try! NSRegularExpression(
    pattern: #"(?<!\d)((?:19|20)\d{2})[-_.]?(\d{2})[-_.]?(\d{2})(?!\d)"#)

  private final class MetadataReader {
    let fd: Int32
    let cancellation: PhotoRepairCancellation
    let lock = NSLock()
    var bytes = 0
    init(fd: Int32, cancellation: PhotoRepairCancellation) {
      self.fd = fd
      self.cancellation = cancellation
    }
    func read(_ buffer: UnsafeMutableRawPointer, _ position: off_t, _ count: Int) -> Int {
      lock.lock()
      defer { lock.unlock() }
      guard !cancellation.isCancelled, position >= 0, count >= 0, count <= (8 << 20) - bytes else {
        return 0
      }
      var result: Int
      repeat { result = pread(fd, buffer, count, position) } while result < 0 && errno == EINTR
      bytes += max(0, result)
      return max(0, result)
    }
  }

  private static func readExif(
    _ fd: Int32, cancellation: PhotoRepairCancellation, timeZone: TimeZone
  ) -> Date? {
    guard let exif = readExifProperties(fd, cancellation: cancellation),
      let original = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String
    else { return nil }
    return parseDate(
      original, offset: exif[kCGImagePropertyExifOffsetTimeOriginal as String] as? String,
      subsecond: exif[kCGImagePropertyExifSubsecTimeOriginal as String] as? String,
      timeZone: timeZone)
  }

  static func archiveExifMonth(
    _ fd: Int32, cancellation: PhotoRepairCancellation, timeZone: TimeZone
  ) -> (year: Int, month: Int)? {
    guard let exif = readExifProperties(fd, cancellation: cancellation),
      let original = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String,
      parseDate(
        original, offset: exif[kCGImagePropertyExifOffsetTimeOriginal as String] as? String,
        subsecond: exif[kCGImagePropertyExifSubsecTimeOriginal as String] as? String,
        timeZone: timeZone) != nil
    else { return nil }
    let fields = original.trimmingCharacters(in: .whitespacesAndNewlines).components(
      separatedBy: CharacterSet(charactersIn: ":- T"))
    guard let year = Int(fields[0]), let month = Int(fields[1]) else { return nil }
    return (year, month)
  }

  static func captureMetadata(
    _ fd: Int32, cancellation: PhotoRepairCancellation, timeZone: TimeZone
  )
    -> (time: MediaCaptureTimestamp, source: MediaArchiveDateSource)?
  {
    guard let properties = readImageProperties(fd, cancellation: cancellation) else { return nil }
    if let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
      for (dateKey, offsetKey, subsecondKey, source) in [
        (
          "DateTimeOriginal", "OffsetTimeOriginal", "SubsecTimeOriginal",
          MediaArchiveDateSource.exif
        ),
        (
          "DateTimeDigitized", "OffsetTimeDigitized", "SubsecTimeDigitized",
          MediaArchiveDateSource.embeddedCreation
        ),
      ] {
        if let text = exif[dateKey] as? String,
          let captured = MediaCaptureTimestamp.parse(
            text, offset: exif[offsetKey] as? String,
            subsecond: exif[subsecondKey] as? String, timeZone: timeZone)
        {
          return (captured, source)
        }
      }
    }
    if let png = properties[kCGImagePropertyPNGDictionary as String] as? [String: Any] {
      if let text = png[kCGImagePropertyPNGCreationTime as String] as? String,
        let time = MediaCaptureTimestamp.parse(text, timeZone: timeZone)
      {
        return (time, .embeddedCreation)
      }
      if let date = png[kCGImagePropertyPNGCreationTime as String] as? Date,
        let time = MediaCaptureTimestamp.from(date, timeZone: timeZone)
      {
        return (time, .embeddedCreation)
      }
    }
    if properties[kCGImagePropertyPNGDictionary as String] != nil,
      let time = PNGCreationTime.read(fd, cancellation: cancellation, timeZone: timeZone)
    {
      return (time, .embeddedCreation)
    }
    return nil
  }

  static func synchronizeDates(_ fd: Int32, date: Date, tolerance: Double) throws {
    let before = try checkedStat(fd)
    guard before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1 else {
      throw EngineFailure(L10n.text("扫描后文件已变化，已跳过。"))
    }
    let seconds = floor(date.timeIntervalSince1970)
    let nanos = Int(((date.timeIntervalSince1970 - seconds) * 1e9).rounded())
    let target = timespec(
      tv_sec: Int(seconds) + nanos / 1_000_000_000, tv_nsec: nanos % 1_000_000_000)
    do {
      try setDates(fd, created: target, modified: target)
      let after = try checkedStat(fd)
      guard ArchiveFileMove.sameDate(after.st_birthtimespec, target, tolerance: tolerance),
        ArchiveFileMove.sameDate(after.st_mtimespec, target, tolerance: tolerance)
      else {
        throw EngineFailure(L10n.text("文件系统未能保留所需日期。"))
      }
    } catch {
      try? setDates(fd, created: before.st_birthtimespec, modified: before.st_mtimespec)
      throw EngineFailure(L10n.text("日期同步失败，已尝试恢复原日期：\(error.localizedDescription)"))
    }
  }

  private static func readExifProperties(_ fd: Int32, cancellation: PhotoRepairCancellation)
    -> [String: Any]?
  {
    readImageProperties(fd, cancellation: cancellation)?[kCGImagePropertyExifDictionary as String]
      as? [String: Any]
  }
  private static func readImageProperties(_ fd: Int32, cancellation: PhotoRepairCancellation)
    -> [String: Any]?
  {
    guard let info = try? checkedStat(fd), info.st_size > 0 else { return nil }
    let context = Unmanaged.passRetained(MetadataReader(fd: fd, cancellation: cancellation))
      .toOpaque()
    var callbacks = CGDataProviderDirectCallbacks(
      version: 0, getBytePointer: nil, releaseBytePointer: nil,
      getBytesAtPosition: { info, buffer, position, count in
        guard let info else { return 0 }
        return Unmanaged<MetadataReader>.fromOpaque(info).takeUnretainedValue().read(
          buffer, position, count)
      },
      releaseInfo: { info in if let info { Unmanaged<MetadataReader>.fromOpaque(info).release() } })
    guard
      let provider = CGDataProvider(directInfo: context, size: info.st_size, callbacks: &callbacks)
    else {
      Unmanaged<MetadataReader>.fromOpaque(context).release()
      return nil
    }
    let options = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithDataProvider(provider, options),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [String: Any]
    else { return nil }
    return properties
  }
}
