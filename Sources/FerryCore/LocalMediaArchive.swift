import Darwin
import Foundation

public enum LocalMediaOperation: Sendable { case archive, renameMedia }

public struct MediaArchiveMonth: Hashable, Sendable {
  public let year: Int
  public let month: Int
  public var id: String { year > 0 ? String(format: "%04d/%02d月", year, month) : "日期未知" }
}

public enum MediaArchiveDateSource: Sendable {
  case exif, videoMetadata, embeddedCreation, filename, creation, unknown
  public var title: String {
    switch self {
    case .exif: return L10n.text("EXIF 拍摄时间")
    case .videoMetadata: return L10n.text("视频拍摄元数据")
    case .embeddedCreation: return L10n.text("内嵌创建时间")
    case .filename: return L10n.text("文件名日期")
    case .creation: return L10n.text("文件创建日期")
    case .unknown: return L10n.text("日期未知")
    }
  }
}

private struct ArchiveStamp: Equatable, Sendable {
  let device: Int32
  let inode: UInt64
  let size: Int64
  let modifiedSeconds: Int
  let modifiedNanos: Int
  let createdSeconds: Int
  let createdNanos: Int
  let changedSeconds: Int
  let changedNanos: Int
  init(_ value: stat) {
    device = value.st_dev
    inode = value.st_ino
    size = value.st_size
    modifiedSeconds = value.st_mtimespec.tv_sec
    modifiedNanos = value.st_mtimespec.tv_nsec
    createdSeconds = value.st_birthtimespec.tv_sec
    createdNanos = value.st_birthtimespec.tv_nsec
    changedSeconds = value.st_ctimespec.tv_sec
    changedNanos = value.st_ctimespec.tv_nsec
  }
  func matchesDatesAndSize(_ other: Self, tolerance: Double) -> Bool {
    size == other.size
      && ArchiveFileMove.sameDate(
        timespec(tv_sec: modifiedSeconds, tv_nsec: modifiedNanos),
        timespec(tv_sec: other.modifiedSeconds, tv_nsec: other.modifiedNanos), tolerance: tolerance)
      && ArchiveFileMove.sameDate(
        timespec(tv_sec: createdSeconds, tv_nsec: createdNanos),
        timespec(tv_sec: other.createdSeconds, tv_nsec: other.createdNanos), tolerance: tolerance)
  }
}

public struct MediaArchiveItem: Identifiable, Sendable {
  public let relativePath: String
  public let month: MediaArchiveMonth
  public let source: MediaArchiveDateSource
  public let isVideo: Bool
  public let targetName: String?
  public let captureDate: Date?
  public let needsDateRepair: Bool
  public var creationDate: Date {
    Date(timeIntervalSince1970: Double(stamp.createdSeconds) + Double(stamp.createdNanos) / 1e9)
  }
  public var modificationDate: Date {
    Date(timeIntervalSince1970: Double(stamp.modifiedSeconds) + Double(stamp.modifiedNanos) / 1e9)
  }
  public var id: String { relativePath }
  fileprivate let parts: [String]
  fileprivate let stamp: ArchiveStamp
}

public struct MediaArchiveDirectory: Identifiable, Sendable {
  public let month: MediaArchiveMonth
  public let candidates: [String]
  public let proposedPath: String
  public var id: String { month.id }
  public var defaultPath: String? { candidates.count > 1 ? nil : candidates.first ?? proposedPath }
}

public struct MediaArchiveSummary: Sendable {
  public var images = 0
  public var videos = 0
  public var skipped = 0
  public var otherYears = 0
  public var noDate = 0
  public var failed = 0
  public init() {}
}

public struct MediaArchivePlan: Sendable {
  public let operation: LocalMediaOperation
  public let folder: URL
  public let items: [MediaArchiveItem]
  public let directories: [MediaArchiveDirectory]
  public let summary: MediaArchiveSummary
  public let folderYear: Int?
  public let skippedYearItems: [PhotoRepairIssue]
  fileprivate let device: Int32
  fileprivate let inode: UInt64
  fileprivate let byMonth: [String: MediaArchiveDirectory]
  public func destination(_ item: MediaArchiveItem, choices: [String: String]) -> String? {
    if operation == .renameMedia, let name = item.targetName {
      return (Array(item.parts.dropLast()) + [name]).joined(separator: "/")
    }
    let directory = byMonth[item.month.id]
    guard let path = choices[item.month.id] ?? directory?.defaultPath else { return nil }
    return path + "/" + item.parts.last!
  }
  public func needsProcessing(_ item: MediaArchiveItem, choices: [String: String]) -> Bool {
    destination(item, choices: choices) != item.relativePath
      || (operation == .renameMedia && item.needsDateRepair)
  }
}

public struct MediaArchiveProgress: Sendable {
  public var processed = 0
  public var total = 0
  public var currentPath = ""
  public var localCopyBytes: Int64 = 0
  public var localCopyTotal: Int64 = 0
  public var verifyingCopy = false
  public init() {}
}

public struct MediaArchiveConflict: Identifiable, Sendable {
  public let file: DownloadConflict
  public let sourcePath: String
  public let targetChanged: Bool
  public let replacementBlockedReason: String?
  public var id: String { file.id }
}

public struct MediaArchiveMove: Identifiable, Sendable {
  public let original: String
  public let destination: String
  public let replaced: Bool
  public var id: String { original }
}

public struct MediaArchiveResult: Sendable {
  public var moved = 0
  public var already = 0
  public var skipped = 0
  public var replaced = 0
  public var datesUpdated = 0
  public var failed = 0
  public var cancelled = false
  public var moves: [MediaArchiveMove] = []
  public var issues: [PhotoRepairIssue] = []
  public init() {}
}

public enum LocalMediaArchive {
  /// A selected year folder already supplies the year component of the archive path.
  public static func yearFolder(_ folder: URL) -> Int? {
    let name = folder.lastPathComponent
    guard name.utf8.count == 4, name.utf8.allSatisfy({ (48...57).contains($0) }),
      let year = Int(name), (1...9999).contains(year)
    else { return nil }
    return year
  }

  public static func scan(
    folder: URL, recursive: Bool, images: Bool, videos: Bool,
    operation: LocalMediaOperation = .archive,
    cancellation: PhotoRepairCancellation,
    progress: @Sendable (MediaArchiveProgress) -> Void = { _ in }
  ) async throws -> MediaArchivePlan {
    let access = folder.startAccessingSecurityScopedResource()
    defer { if access { folder.stopAccessingSecurityScopedResource() } }
    guard images || videos else { throw EngineFailure(L10n.text("请至少选择图片或视频。")) }
    let root = try LocalImageFiles.openRoot(folder)
    defer { close(root) }
    let rootInfo = try LocalImageFiles.checkedStat(root)
    let rootParts = folder.standardizedFileURL.pathComponents
    let folderYear = operation == .archive ? yearFolder(folder) : nil
    let dateTolerance = max(0.000001, try ArchiveFileMove.dateTolerance(root))
    // Existing month directories are already organized; only collect loose root files.
    let scanRecursively = recursive && folderYear == nil
    var skippedYearItems: [PhotoRepairIssue] = []
    let zone = TimeZone.current
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    var summary = MediaArchiveSummary()
    var items: [MediaArchiveItem] = []
    guard
      let enumerator = FileManager.default.enumerator(
        at: folder,
        includingPropertiesForKeys: [
          .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isAliasFileKey,
        ],
        options: [.skipsHiddenFiles],
        errorHandler: { _, _ in
          summary.failed += 1
          return true
        })
    else { throw EngineFailure(L10n.text("无法读取所选文件夹。")) }
    var lastPublish = -Double.infinity
    while let url = enumerator.nextObject() as? URL {
      if cancellation.isCancelled { throw CancellationError() }
      let path = url.standardizedFileURL.pathComponents
      guard path.starts(with: rootParts) else { continue }
      let parts = Array(path.dropFirst(rootParts.count))
      defer {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastPublish >= 0.1 {
          var value = MediaArchiveProgress()
          value.processed = summary.images + summary.videos
          value.currentPath = parts.joined(separator: "/")
          progress(value)
          lastPublish = now
        }
      }
      do {
        let values = try url.resourceValues(forKeys: [
          .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isAliasFileKey,
        ])
        if values.isSymbolicLink == true || values.isAliasFile == true
          || LocalImageFiles.isContainer(url, flagged: values.isPackage)
        {
          if values.isDirectory == true && values.isSymbolicLink != true
            && values.isAliasFile != true
          {
            enumerator.skipDescendants()
          }
          summary.skipped += 1
          continue
        }
        if values.isDirectory == true {
          if !scanRecursively {
            enumerator.skipDescendants()
            continue
          }
          let fd = try LocalImageFiles.openItem(root, parts, directory: true)
          defer { close(fd) }
          if try LocalImageFiles.checkedStat(fd).st_dev != rootInfo.st_dev {
            enumerator.skipDescendants()
            summary.skipped += 1
          }
          continue
        }
        let video = RemoteEntry.isVideoFilename(url.lastPathComponent)
        guard video ? videos : images && RemoteEntry.isImageFilename(url.lastPathComponent) else {
          continue
        }
        if video { summary.videos += 1 } else { summary.images += 1 }
        if summary.images + summary.videos > 1_000_000 {
          throw EngineFailure(L10n.text("媒体数量超过安全限制，请分批选择文件夹。"))
        }
        let fd = try LocalImageFiles.openItem(root, parts)
        defer { close(fd) }
        let info = try LocalImageFiles.checkedStat(fd)
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_dev == rootInfo.st_dev
        else {
          summary.skipped += 1
          continue
        }
        let stamp = ArchiveStamp(info)
        var month: MediaArchiveMonth?
        var source: MediaArchiveDateSource = .unknown
        var capture: MediaCaptureTimestamp?
        var targetName: String?
        var needsDateRepair = false
        if video {
          capture = await MediaCaptureTimestamp.video(
            url, timeZone: zone, cancellation: cancellation)
          if let capture {
            month = .init(year: capture.year, month: capture.month)
            source = .videoMetadata
          }
        } else if operation == .renameMedia {
          if let embedded = PhotoDateRepair.captureMetadata(
            fd, cancellation: cancellation, timeZone: zone)
          {
            capture = embedded.time
            source = embedded.source
            month = .init(year: embedded.time.year, month: embedded.time.month)
          }
        } else if let exif = PhotoDateRepair.archiveExifMonth(
          fd, cancellation: cancellation, timeZone: zone)
        {
          month = .init(year: exif.year, month: exif.month)
          source = .exif
        }
        if operation == .renameMedia {
          if capture == nil,
            let filename = PhotoDateRepair.dateFromFilename(
              url.lastPathComponent, allowDateOnly: false, timeZone: zone),
            let time = MediaCaptureTimestamp.from(filename.date, timeZone: zone)
          {
            capture = time
            source = .filename
            month = .init(year: time.year, month: time.month)
          }
          guard let capture else {
            summary.noDate += 1
            summary.skipped += 1
            continue
          }
          targetName = capture.filename(original: url.lastPathComponent, video: video)
          let created =
            Double(info.st_birthtimespec.tv_sec) + Double(info.st_birthtimespec.tv_nsec) / 1e9
          let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
          needsDateRepair =
            abs(created - capture.date.timeIntervalSince1970) > dateTolerance
            || abs(modified - capture.date.timeIntervalSince1970) > dateTolerance
        }
        if operation == .archive, month == nil,
          let filename = PhotoDateRepair.dateFromFilename(
            url.lastPathComponent, allowDateOnly: true, timeZone: zone)
        {
          month = .init(
            year: calendar.component(.year, from: filename.date),
            month: calendar.component(.month, from: filename.date))
          source = .filename
        }
        if operation == .archive, month == nil,
          info.st_birthtimespec.tv_sec != 0 || info.st_birthtimespec.tv_nsec != 0
        {
          let date = Date(timeIntervalSince1970: Double(info.st_birthtimespec.tv_sec))
          let year = calendar.component(.year, from: date)
          let number = calendar.component(.month, from: date)
          if (1...9999).contains(year), (1...12).contains(number) {
            month = .init(year: year, month: number)
            source = .creation
          }
        }
        guard stamp == ArchiveStamp(try LocalImageFiles.checkedStat(fd)) else {
          summary.failed += 1
          continue
        }
        if let folderYear, let month, month.year != folderYear {
          summary.otherYears += 1
          summary.skipped += 1
          if skippedYearItems.count < 50 {
            skippedYearItems.append(
              .init(
                path: parts.joined(separator: "/"),
                message:
                  L10n.text("识别年月为 \(month.id)，与目录年份 \(folderYear) 不符，保留原位。")))
          }
          continue
        }
        items.append(
          .init(
            relativePath: parts.joined(separator: "/"), month: month ?? .init(year: 0, month: 0),
            source: source, isVideo: video, targetName: targetName,
            captureDate: operation == .renameMedia ? capture?.date : nil,
            needsDateRepair: needsDateRepair, parts: parts, stamp: stamp))
      } catch {
        summary.failed += 1
        if parts.count > 128 { enumerator.skipDescendants() }
      }
      if summary.images + summary.videos > 1_000_000 {
        throw EngineFailure(L10n.text("媒体数量超过安全限制，请分批选择文件夹。"))
      }
    }
    if cancellation.isCancelled { throw CancellationError() }
    let months = operation == .archive ? Set(items.map(\.month)).sorted { $0.id < $1.id } : []
    let directories = try months.map { month -> MediaArchiveDirectory in
      guard month.year > 0 else {
        return .init(month: month, candidates: [], proposedPath: month.id)
      }
      let names = [
        String(format: "%02d月", month.month), "\(month.month)月",
        String(format: "%02d", month.month), "\(month.month)",
      ]
      let prefix = folderYear == month.year ? "" : String(format: "%04d/", month.year)
      var seen = Set<String>()
      var candidates: [String] = []
      for name in names {
        let relative = prefix + name
        guard seen.insert(relative).inserted else { continue }
        if let directory = try? LocalImageFiles.openItem(
          root, relative.split(separator: "/").map(String.init), directory: true)
        {
          defer { close(directory) }
          if try LocalImageFiles.checkedStat(directory).st_dev == rootInfo.st_dev {
            candidates.append(relative)
          }
        }
      }
      return .init(month: month, candidates: candidates, proposedPath: prefix + names[0])
    }
    return .init(
      operation: operation, folder: folder, items: items, directories: directories,
      summary: summary,
      folderYear: folderYear, skippedYearItems: skippedYearItems,
      device: rootInfo.st_dev, inode: rootInfo.st_ino,
      byMonth: Dictionary(uniqueKeysWithValues: directories.map { ($0.id, $0) }))
  }

  public static func apply(
    _ plan: MediaArchivePlan, choices: [String: String], selectedIDs: Set<String>? = nil,
    cancellation: PhotoRepairCancellation,
    resolveConflict: @Sendable (MediaArchiveConflict) throws -> DownloadConflictDecision = {
      .init(id: $0.id, choice: "keepBoth")
    },
    progress: @Sendable (MediaArchiveProgress) -> Void = { _ in }
  ) throws -> MediaArchiveResult {
    let items: [MediaArchiveItem]
    if let selectedIDs {
      items = plan.items.filter { selectedIDs.contains($0.id) }
      guard items.count == selectedIDs.count else {
        throw EngineFailure(L10n.text("所选文件不在当前扫描计划中，请重新扫描。"))
      }
    } else {
      items = plan.items
    }
    let neededMonths = Set(items.map { $0.month.id })
    let allowed = Dictionary(uniqueKeysWithValues: plan.directories.map { ($0.id, $0) })
    guard choices.allSatisfy({ id, path in allowed[id]?.candidates.contains(path) == true }),
      plan.directories.filter({ neededMonths.contains($0.id) })
        .allSatisfy({ choices[$0.id] != nil || $0.defaultPath != nil })
    else { throw EngineFailure(L10n.text("请先选择每个月份的归档目录。")) }
    if items.isEmpty { return MediaArchiveResult() }
    let access = plan.folder.startAccessingSecurityScopedResource()
    defer { if access { plan.folder.stopAccessingSecurityScopedResource() } }
    let root = try checkedRoot(plan)
    defer { close(root) }
    let dateTolerance = try ArchiveFileMove.dateTolerance(root)
    var result = MediaArchiveResult()
    let protectedSources: Set<UInt64> =
      plan.operation == .renameMedia
      ? Set(
        items.filter { plan.destination($0, choices: choices) != $0.relativePath }.map {
          $0.stamp.inode
        }) : []
    var supersededSources: Set<UInt64> = []
    var allConflicts: String?
    var lastPublish = -Double.infinity
    for (index, item) in items.enumerated() {
      if cancellation.isCancelled {
        result.cancelled = true
        break
      }
      defer {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastPublish >= 0.1 || index == items.count - 1 {
          var value = MediaArchiveProgress()
          value.processed = index + 1
          value.total = items.count
          value.currentPath = item.relativePath
          progress(value)
          lastPublish = now
        }
      }
      if supersededSources.contains(item.stamp.inode) {
        result.skipped += 1
        continue
      }
      do {
        let base = plan.destination(item, choices: choices)!
        if !plan.needsProcessing(item, choices: choices) {
          result.already += 1
          continue
        }
        let fd = try LocalImageFiles.openItem(root, item.parts)
        defer { close(fd) }
        try validate(fd, item)
        if base == item.relativePath, let date = item.captureDate {
          try PhotoDateRepair.synchronizeDates(fd, date: date, tolerance: dateTolerance)
          result.datesUpdated += 1
          if result.moves.count < 100 {
            result.moves.append(
              .init(original: item.relativePath, destination: base, replaced: false))
          }
          continue
        }
        let parent = Array(base.split(separator: "/").dropLast()).map(String.init)
        let destinationRoot =
          plan.operation == .renameMedia
          ? (parent.isEmpty
            ? dup(root) : try LocalImageFiles.openItem(root, parent, directory: true))
          : try ensureDirectory(root, parts: parent, device: plan.device)
        guard destinationRoot >= 0 else { throw LocalImageFiles.systemError() }
        defer { close(destinationRoot) }
        let name = (base as NSString).lastPathComponent
        var actual: String?
        var committed: ArchiveStamp?
        var numberedNames = false
        var number = 0
        var didSkip = false
        var didReplace = false
        var targetChanged = false
        attempts: for _ in 0..<1_000_000 {
          if cancellation.isCancelled {
            result.cancelled = true
            break
          }
          let filename = numbered(name, number)
          let target = (parent + [filename]).joined(separator: "/")
          var existing = stat()
          let occupied = fstatat(destinationRoot, filename, &existing, AT_SYMLINK_NOFOLLOW) == 0
          guard occupied || errno == ENOENT else { throw LocalImageFiles.systemError() }
          var replacement: ArchiveStamp?
          let sameSource =
            occupied && plan.operation == .renameMedia
            && existing.st_dev == item.stamp.device && existing.st_ino == item.stamp.inode
            && existing.st_nlink == 1
          if sameSource {
            replacement = ArchiveStamp(existing)
          } else if occupied {
            if numberedNames {
              number += 1
              continue
            }
            let canReplace =
              existing.st_mode & S_IFMT == S_IFREG && existing.st_nlink == 1
              && existing.st_dev == plan.device && existing.st_ino != item.stamp.inode
              && !protectedSources.contains(existing.st_ino)
            let prompt = MediaArchiveConflict(
              file: .init(
                id: UUID().uuidString, kind: "file",
                targetPath: plan.folder.appendingPathComponent(target).path, name: name,
                existingSize: existing.st_size,
                existingModified: Int64(existing.st_mtimespec.tv_sec),
                incomingSize: item.stamp.size, incomingModified: Int64(item.stamp.modifiedSeconds),
                canReplace: canReplace, candidates: nil),
              sourcePath: plan.folder.appendingPathComponent(item.relativePath).path,
              targetChanged: targetChanged,
              replacementBlockedReason: protectedSources.contains(existing.st_ino)
                ? L10n.text("目标也是本次待重命名文件，请选择保留两者或跳过。") : nil)
            let decision: DownloadConflictDecision
            if !targetChanged, let policy = allConflicts, policy != "replace" || canReplace {
              decision = .init(id: prompt.id, choice: policy)
            } else {
              decision = try resolveConflict(prompt)
            }
            if cancellation.isCancelled {
              result.cancelled = true
              break
            }
            guard decision.id == prompt.id,
              ["keepBoth", "skip", "replace"].contains(decision.choice)
            else {
              throw EngineFailure(L10n.text("同名处理选择已失效，未移动文件，请重新扫描。"))
            }
            if decision.applyToAll { allConflicts = decision.choice }
            switch decision.choice {
            case "skip":
              result.skipped += 1
              didSkip = true
              break attempts
            case "keepBoth":
              numberedNames = true
              number = 1
              continue
            default:
              guard canReplace else {
                throw EngineFailure(L10n.text("目标是文件夹、链接或特殊文件，不能替换。"))
              }
              replacement = ArchiveStamp(existing)
            }
          }
          do {
            committed = try coordinatedMove(
              plan, item: item, target: target, sourceFD: fd, destinationFD: destinationRoot,
              replacement: replacement, cancellation: cancellation,
              copyProgress: { bytes, total, verifying in
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastPublish >= 0.1 || bytes == 0 || bytes == total {
                  var value = MediaArchiveProgress()
                  value.processed = index
                  value.total = items.count
                  value.currentPath = item.relativePath
                  value.localCopyBytes = bytes
                  value.localCopyTotal = total
                  value.verifyingCopy = verifying
                  progress(value)
                  lastPublish = now
                }
              })
            actual = target
            didReplace = replacement != nil && !sameSource
            if plan.operation == .renameMedia, didReplace, let replacement {
              supersededSources.insert(replacement.inode)
            }
            break
          } catch MoveFailure.targetChanged {
            targetChanged = true
          } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError
          {
            targetChanged = true
            if numberedNames { number += 1 }
          }
        }
        if result.cancelled { break }
        if didSkip { continue }
        guard let actual else { throw EngineFailure(L10n.text("同名文件过多，无法生成归档名称。")) }
        result.moved += 1
        if didReplace { result.replaced += 1 }
        if result.moves.count < 100 {
          result.moves.append(
            .init(original: item.relativePath, destination: actual, replaced: didReplace))
        }
        let finalFD = try LocalImageFiles.openItem(
          root, actual.split(separator: "/").map(String.init))
        defer { close(finalFD) }
        if !item.stamp.matchesDatesAndSize(
          ArchiveStamp(try LocalImageFiles.checkedStat(finalFD)), tolerance: dateTolerance)
        {
          if result.issues.count < 50 {
            result.issues.append(
              .init(path: actual, message: L10n.text("文件已归档，但文件系统报告的日期发生变化，请检查。")))
          }
        }
        if let date = item.captureDate {
          do {
            let current = try LocalImageFiles.checkedStat(finalFD)
            guard let committed, ArchiveStamp(current) == committed,
              current.st_mode & S_IFMT == S_IFREG, current.st_nlink == 1
            else {
              throw EngineFailure(L10n.text("目标在重命名后发生变化，未同步日期，请重新扫描。"))
            }
            try PhotoDateRepair.synchronizeDates(finalFD, date: date, tolerance: dateTolerance)
            result.datesUpdated += 1
          } catch {
            result.failed += 1
            if result.issues.count < 50 {
              result.issues.append(
                .init(path: actual, message: L10n.text("文件已重命名，但\(error.localizedDescription)")))
            }
          }
        }
      } catch is CancellationError {
        result.cancelled = true
        break
      } catch {
        result.cancelled = result.cancelled || cancellation.isCancelled
        result.failed += 1
        if result.issues.count < 50 {
          result.issues.append(.init(path: item.relativePath, message: error.localizedDescription))
        }
      }
    }
    return result
  }

  private static func checkedRoot(_ plan: MediaArchivePlan) throws -> Int32 {
    let fd = try LocalImageFiles.openRoot(plan.folder)
    do {
      let info = try LocalImageFiles.checkedStat(fd)
      guard info.st_dev == plan.device, info.st_ino == plan.inode else {
        throw EngineFailure(L10n.text("所选文件夹已变化，请重新扫描。"))
      }
      return fd
    } catch {
      close(fd)
      throw error
    }
  }
  private static func validate(_ fd: Int32, _ item: MediaArchiveItem) throws {
    let info = try LocalImageFiles.checkedStat(fd)
    guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, ArchiveStamp(info) == item.stamp
    else { throw EngineFailure(L10n.text("扫描后文件已变化，已跳过。")) }
  }
  private static func ensureDirectory(_ root: Int32, parts: [String], device: Int32) throws -> Int32
  {
    var fd = dup(root)
    guard fd >= 0 else { throw LocalImageFiles.systemError() }
    for name in parts {
      if mkdirat(fd, name, 0o700) != 0 && errno != EEXIST {
        close(fd)
        throw LocalImageFiles.systemError()
      }
      let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      close(fd)
      guard next >= 0 else { throw LocalImageFiles.systemError() }
      fd = next
      do {
        guard try LocalImageFiles.checkedStat(fd).st_dev == device else {
          throw EngineFailure(L10n.text("归档目录不能跨越其他磁盘或链接。"))
        }
      } catch {
        close(fd)
        throw error
      }
    }
    return fd
  }
  private static func numbered(_ name: String, _ number: Int) -> String {
    guard number > 0 else { return name }
    let url = name as NSString
    let ext = url.pathExtension
    return url.deletingPathExtension + " (\(number))" + (ext.isEmpty ? "" : "." + ext)
  }
  private enum MoveFailure: Error { case targetChanged }

  private static func coordinatedMove(
    _ plan: MediaArchivePlan, item: MediaArchiveItem, target: String, sourceFD: Int32,
    destinationFD: Int32, replacement: ArchiveStamp?, cancellation: PhotoRepairCancellation,
    copyProgress: (Int64, Int64, Bool) -> Void
  ) throws -> ArchiveStamp? {
    let source = plan.folder.appendingPathComponent(item.relativePath)
    let destination = plan.folder.appendingPathComponent(target)
    var coordinationError: NSError?
    var failure: Error?
    var committed: ArchiveStamp?
    let coordinator = NSFileCoordinator(filePresenter: nil)
    coordinator.coordinate(
      writingItemAt: source, options: .forMoving, writingItemAt: destination,
      options: replacement == nil ? [] : .forReplacing,
      error: &coordinationError
    ) { first, second in
      do {
        guard first.standardizedFileURL == source.standardizedFileURL,
          second.standardizedFileURL == destination.standardizedFileURL
        else { throw EngineFailure(L10n.text("所选文件夹已变化，请重新扫描。")) }
        let root = try checkedRoot(plan)
        defer { close(root) }
        let current = try LocalImageFiles.openItem(root, item.parts)
        defer { close(current) }
        try validate(current, item)
        try validate(sourceFD, item)
        let targetParts = Array(target.split(separator: "/").dropLast()).map(String.init)
        let parent =
          targetParts.isEmpty
          ? dup(root) : try LocalImageFiles.openItem(root, targetParts, directory: true)
        guard parent >= 0 else { throw LocalImageFiles.systemError() }
        defer { close(parent) }
        let currentParent = try LocalImageFiles.checkedStat(parent)
        let expectedParent = try LocalImageFiles.checkedStat(destinationFD)
        guard currentParent.st_dev == expectedParent.st_dev,
          currentParent.st_ino == expectedParent.st_ino
        else {
          throw EngineFailure(L10n.text("归档目录已变化，请重新扫描。"))
        }
        let sourceParts = Array(item.parts.dropLast())
        let sourceParent =
          sourceParts.isEmpty
          ? dup(root)
          : try LocalImageFiles.openItem(
            root, sourceParts, directory: true)
        guard sourceParent >= 0 else { throw LocalImageFiles.systemError() }
        defer { close(sourceParent) }
        var atPath = stat()
        guard fstatat(sourceParent, item.parts.last!, &atPath, AT_SYMLINK_NOFOLLOW) == 0,
          ArchiveStamp(atPath) == item.stamp,
          try LocalImageFiles.checkedStat(parent).st_dev == plan.device
        else { throw EngineFailure(L10n.text("扫描后文件已变化，已跳过。")) }
        var atTarget = stat()
        let targetExists =
          fstatat(parent, second.lastPathComponent, &atTarget, AT_SYMLINK_NOFOLLOW) == 0
        guard targetExists || errno == ENOENT else { throw LocalImageFiles.systemError() }
        if let replacement {
          guard targetExists, atTarget.st_mode & S_IFMT == S_IFREG, atTarget.st_nlink == 1,
            ArchiveStamp(atTarget) == replacement
          else { throw MoveFailure.targetChanged }
        } else if targetExists {
          throw MoveFailure.targetChanged
        }
        if cancellation.isCancelled { throw CancellationError() }
        coordinator.item(at: first, willMoveTo: second)
        if replacement == nil {
          try ArchiveFileMove.move(
            sourceParent: sourceParent, sourceName: item.parts.last!, sourceFD: sourceFD,
            destinationParent: parent, destinationName: second.lastPathComponent,
            cancellation: cancellation, allowReservedRename: true,
            validatePaths: {
              let checked = try checkedRoot(plan)
              defer { close(checked) }
              let source = try LocalImageFiles.openItem(checked, item.parts)
              defer { close(source) }
              try validate(source, item)
              let directory =
                targetParts.isEmpty
                ? dup(checked) : try LocalImageFiles.openItem(checked, targetParts, directory: true)
              guard directory >= 0 else { throw LocalImageFiles.systemError() }
              defer { close(directory) }
              let info = try LocalImageFiles.checkedStat(directory)
              guard info.st_dev == currentParent.st_dev, info.st_ino == currentParent.st_ino else {
                throw EngineFailure(L10n.text("归档目录已变化，请重新扫描。"))
              }
            }, progress: copyProgress)
        } else {
          // Explicitly approved replacement stays an atomic same-volume rename.
          guard renameat(sourceParent, item.parts.last!, parent, second.lastPathComponent) == 0
          else {
            throw LocalImageFiles.systemError()
          }
        }
        var committedInfo = stat()
        if fstatat(parent, second.lastPathComponent, &committedInfo, AT_SYMLINK_NOFOLLOW) == 0,
          committedInfo.st_mode & S_IFMT == S_IFREG, committedInfo.st_nlink == 1
        {
          committed = ArchiveStamp(committedInfo)
        }
        coordinator.item(at: first, didMoveTo: second)
      } catch { failure = error }
    }
    if let failure { throw failure }
    if let coordinationError { throw coordinationError }
    return committed
  }

  static func monthFromMetadataString(_ string: String, timeZone: TimeZone) -> MediaArchiveMonth? {
    guard let time = MediaCaptureTimestamp.parse(string, timeZone: timeZone, minimumYear: 1970)
    else { return nil }
    return .init(year: time.year, month: time.month)
  }

}
