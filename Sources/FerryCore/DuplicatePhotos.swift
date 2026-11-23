import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO

private struct DuplicateStamp: Equatable, Sendable {
  let device: Int32
  let inode: UInt64
  let size: Int64
  let modifiedSeconds: Int
  let modifiedNanos: Int
  let changedSeconds: Int
  let changedNanos: Int
  init(_ value: stat) {
    device = value.st_dev
    inode = value.st_ino
    size = value.st_size
    modifiedSeconds = value.st_mtimespec.tv_sec
    modifiedNanos = value.st_mtimespec.tv_nsec
    changedSeconds = value.st_ctimespec.tv_sec
    changedNanos = value.st_ctimespec.tv_nsec
  }
}

public struct DuplicatePhoto: Identifiable, Sendable {
  public let relativePath: String
  public let size: Int64
  public let modified: Date
  public let created: Date?
  public var id: String { relativePath }
  fileprivate let parts: [String]
  fileprivate let stamp: DuplicateStamp
}

public struct DuplicatePhotoGroup: Identifiable, Sendable {
  public let id: String
  public let hash: String
  public let photos: [DuplicatePhoto]
  public let duplicateBytes: Int64
}

public struct DuplicateScanSummary: Sendable {
  public var images = 0
  public var hashed = 0
  public var skipped = 0
  public var failed = 0
  public var duplicateCopies = 0
  public var duplicateBytes: Int64 = 0
  public init() {}
}

public struct DuplicatePhotoPlan: Sendable {
  public let folder: URL
  public let groups: [DuplicatePhotoGroup]
  public let summary: DuplicateScanSummary
  fileprivate let device: Int32
  fileprivate let inode: UInt64
}

public struct DuplicateKeepChoice: Sendable {
  public let groupID: String
  public let keepID: String
  public init(groupID: String, keepID: String) {
    self.groupID = groupID
    self.keepID = keepID
  }
}

public struct DuplicatePhotoProgress: Sendable {
  public enum Stage: Sendable { case enumerating, hashing, trashing }
  public var stage: Stage = .enumerating
  public var processed = 0
  public var total = 0
  public var currentPath = ""
  public init() {}
}

public struct DuplicateCleanupResult: Sendable {
  public var moved = 0
  public var skipped = 0
  public var failed = 0
  public var cancelled = false
  public var issues: [PhotoRepairIssue] = []
  public init() {}
}

public enum DuplicatePhotos {
  private static var changedError: Error { EngineFailure(L10n.text("文件或保留项已变化，已跳过；请重新扫描。")) }
  private static func validate(_ fd: Int32, item: DuplicatePhoto) throws {
    let value = try LocalImageFiles.checkedStat(fd)
    guard value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1,
      DuplicateStamp(value) == item.stamp
    else { throw changedError }
  }

  private static func hash(_ fd: Int32, item: DuplicatePhoto, cancellation: PhotoRepairCancellation)
    throws -> String
  {
    try validate(fd, item: item)
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 1 << 20)
    var total: Int64 = 0
    guard lseek(fd, 0, SEEK_SET) == 0 else { throw LocalImageFiles.systemError() }
    while true {
      if cancellation.isCancelled { throw CancellationError() }
      let remaining = item.size - total
      let requested = remaining >= buffer.count ? buffer.count : Int(remaining) + 1
      let count = buffer.withUnsafeMutableBytes { bytes -> Int in
        var count: Int
        repeat { count = read(fd, bytes.baseAddress, requested) } while count < 0 && errno == EINTR
        if count > 0 {
          hasher.update(
            bufferPointer: UnsafeRawBufferPointer(start: bytes.baseAddress, count: count))
        }
        return count
      }
      guard count >= 0 else { throw LocalImageFiles.systemError() }
      if count == 0 { break }
      total += Int64(count)
      guard total <= item.size else { throw changedError }
    }
    guard total == item.size else { throw changedError }
    try validate(fd, item: item)
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  public static func scan(
    folder: URL, recursive: Bool, cancellation: PhotoRepairCancellation,
    progress: @Sendable (DuplicatePhotoProgress) -> Void = { _ in }
  ) throws -> DuplicatePhotoPlan {
    let access = folder.startAccessingSecurityScopedResource()
    defer { if access { folder.stopAccessingSecurityScopedResource() } }
    let root = try LocalImageFiles.openRoot(folder)
    defer { close(root) }
    let rootInfo = try LocalImageFiles.checkedStat(root)
    let rootParts = folder.standardizedFileURL.pathComponents
    var summary = DuplicateScanSummary()
    var sizes: [Int64: [DuplicatePhoto]] = [:]
    guard
      let enumerator = FileManager.default.enumerator(
        at: folder,
        includingPropertiesForKeys: [
          .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isAliasFileKey,
        ],
        options: [.skipsHiddenFiles, .skipsPackageDescendants],
        errorHandler: { _, _ in
          summary.failed += 1
          return true
        })
    else { throw EngineFailure(L10n.text("无法读取所选文件夹。")) }
    var lastPublish = -Double.infinity
    for case let url as URL in enumerator {
      if cancellation.isCancelled { throw CancellationError() }
      let components = url.standardizedFileURL.pathComponents
      guard components.starts(with: rootParts) else { continue }
      let parts = Array(components.dropFirst(rootParts.count))
      defer {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastPublish >= 0.1 {
          var update = DuplicatePhotoProgress()
          update.processed = summary.images
          update.currentPath = parts.joined(separator: "/")
          progress(update)
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
          summary.skipped += 1
          enumerator.skipDescendants()
          continue
        }
        if values.isDirectory == true {
          if !recursive {
            enumerator.skipDescendants()
            continue
          }
          let fd = try LocalImageFiles.openItem(root, parts, directory: true)
          defer { close(fd) }
          if try LocalImageFiles.checkedStat(fd).st_dev != rootInfo.st_dev {
            summary.skipped += 1
            enumerator.skipDescendants()
          }
          continue
        }
        guard RemoteEntry.isImageFilename(url.lastPathComponent) else { continue }
        summary.images += 1
        if summary.images > 1_000_000 { throw changedError }
        let fd = try LocalImageFiles.openItem(root, parts)
        defer { close(fd) }
        let info = try LocalImageFiles.checkedStat(fd)
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size > 0,
          info.st_dev == rootInfo.st_dev
        else {
          summary.skipped += 1
          continue
        }
        let item = DuplicatePhoto(
          relativePath: parts.joined(separator: "/"), size: info.st_size,
          modified: Date(
            timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(
              info.st_mtimespec.tv_nsec) / 1e9),
          created: info.st_birthtimespec.tv_sec > 0
            ? Date(timeIntervalSince1970: Double(info.st_birthtimespec.tv_sec)) : nil,
          parts: parts, stamp: DuplicateStamp(info))
        sizes[item.size, default: []].append(item)
      } catch {
        summary.failed += 1
        if parts.count > 128 { enumerator.skipDescendants() }
      }
      if summary.images > 1_000_000 { throw EngineFailure(L10n.text("图片数量超过安全限制，请分批选择文件夹。")) }
    }
    let candidates = sizes.values.filter { $0.count > 1 }.flatMap { $0 }.sorted {
      $0.relativePath < $1.relativePath
    }
    sizes.removeAll()
    var hashes: [String: [DuplicatePhoto]] = [:]
    for (index, item) in candidates.enumerated() {
      if cancellation.isCancelled { throw CancellationError() }
      do {
        let fd = try LocalImageFiles.openItem(root, item.parts)
        defer { close(fd) }
        let digest = try hash(fd, item: item, cancellation: cancellation)
        hashes[digest, default: []].append(item)
        summary.hashed += 1
      } catch is CancellationError { throw CancellationError() } catch { summary.failed += 1 }
      let now = ProcessInfo.processInfo.systemUptime
      if now - lastPublish >= 0.1 || index == candidates.count - 1 {
        var update = DuplicatePhotoProgress()
        update.stage = .hashing
        update.processed = index + 1
        update.total = candidates.count
        update.currentPath = item.relativePath
        progress(update)
        lastPublish = now
      }
    }
    if cancellation.isCancelled { throw CancellationError() }
    var groups: [DuplicatePhotoGroup] = []
    for (digest, photos) in hashes where photos.count > 1 {
      let sorted = photos.sorted {
        $0.parts.count == $1.parts.count
          ? $0.relativePath < $1.relativePath : $0.parts.count < $1.parts.count
      }
      let bytes = photos[0].size.multipliedReportingOverflow(by: Int64(photos.count - 1))
      let sum = summary.duplicateBytes.addingReportingOverflow(bytes.partialValue)
      guard !bytes.overflow, !sum.overflow else {
        throw EngineFailure(L10n.text("图片总大小超过安全范围，请分批扫描。"))
      }
      summary.duplicateBytes = sum.partialValue
      summary.duplicateCopies += photos.count - 1
      groups.append(
        .init(id: digest, hash: digest, photos: sorted, duplicateBytes: bytes.partialValue))
    }
    groups.sort { $0.photos[0].relativePath < $1.photos[0].relativePath }
    return DuplicatePhotoPlan(
      folder: folder, groups: groups, summary: summary, device: rootInfo.st_dev,
      inode: rootInfo.st_ino)
  }

  public static func moveToTrash(
    _ plan: DuplicatePhotoPlan, choices: [DuplicateKeepChoice],
    cancellation: PhotoRepairCancellation,
    trash: (@Sendable (URL) throws -> Void)? = nil,
    progress: @Sendable (DuplicatePhotoProgress) -> Void = { _ in }
  ) throws -> DuplicateCleanupResult {
    let byID = Dictionary(uniqueKeysWithValues: plan.groups.map { ($0.id, $0) })
    guard Set(choices.map(\.groupID)).count == choices.count,
      choices.allSatisfy({ choice in
        byID[choice.groupID]?.photos.contains { $0.id == choice.keepID } == true
      })
    else { throw EngineFailure(L10n.text("清理选择无效，请重新扫描并选择每组保留项。")) }
    let access = plan.folder.startAccessingSecurityScopedResource()
    defer { if access { plan.folder.stopAccessingSecurityScopedResource() } }
    let root = try checkedRoot(plan)
    defer { close(root) }
    let total = choices.reduce(0) { $0 + byID[$1.groupID]!.photos.count - 1 }
    var result = DuplicateCleanupResult()
    var done = 0
    var lastPublish = -Double.infinity
    func publish(_ path: String) {
      let now = ProcessInfo.processInfo.systemUptime
      guard now - lastPublish >= 0.1 || done == total else { return }
      var update = DuplicatePhotoProgress()
      update.stage = .trashing
      update.processed = done
      update.total = total
      update.currentPath = path
      progress(update)
      lastPublish = now
    }
    func issue(_ path: String, _ error: Error) {
      if result.issues.count < 50 {
        result.issues.append(.init(path: path, message: error.localizedDescription))
      }
    }
    for choice in choices {
      if cancellation.isCancelled {
        result.cancelled = true
        break
      }
      let group = byID[choice.groupID]!
      let keep = group.photos.first { $0.id == choice.keepID }!
      let copies = group.photos.filter { $0.id != choice.keepID }
      do {
        let keptFD = try LocalImageFiles.openItem(root, keep.parts)
        defer { close(keptFD) }
        guard try hash(keptFD, item: keep, cancellation: cancellation) == group.hash else {
          throw changedError
        }
        for item in copies {
          if cancellation.isCancelled {
            result.cancelled = true
            break
          }
          do {
            let fd = try LocalImageFiles.openItem(root, item.parts)
            defer { close(fd) }
            guard try hash(fd, item: item, cancellation: cancellation) == group.hash else {
              throw changedError
            }
            if cancellation.isCancelled {
              result.cancelled = true
              break
            }
            let url = plan.folder.appendingPathComponent(item.relativePath)
            let check = {
              let currentRoot = try checkedRoot(plan)
              defer { close(currentRoot) }
              for value in [keep, item] {
                let current = try LocalImageFiles.openItem(currentRoot, value.parts)
                defer { close(current) }
                try validate(current, item: value)
              }
              try validate(keptFD, item: keep)
              try validate(fd, item: item)
              if cancellation.isCancelled { throw CancellationError() }
            }
            if let trash {
              try check()
              try trash(url)
            } else {
              try systemTrash(url, check: check)
            }
            result.moved += 1
          } catch is CancellationError {
            result.cancelled = true
            break
          } catch {
            result.failed += 1
            issue(item.relativePath, error)
          }
          done += 1
          publish(item.relativePath)
        }
      } catch is CancellationError {
        result.cancelled = true
        break
      } catch {
        result.skipped += copies.count
        done += copies.count
        issue(keep.relativePath, error)
        publish(keep.relativePath)
      }
      if result.cancelled { break }
    }
    return result
  }

  private static func checkedRoot(_ plan: DuplicatePhotoPlan) throws -> Int32 {
    let fd = try LocalImageFiles.openRoot(plan.folder)
    do {
      let info = try LocalImageFiles.checkedStat(fd)
      guard info.st_dev == plan.device, info.st_ino == plan.inode else { throw changedError }
      return fd
    } catch {
      close(fd)
      throw error
    }
  }

  private static func systemTrash(_ url: URL, check: @escaping () throws -> Void) throws {
    var coordinationError: NSError?
    var failure: Error?
    NSFileCoordinator(filePresenter: nil).coordinate(
      writingItemAt: url, options: .forDeleting, error: &coordinationError
    ) { coordinated in
      do {
        guard coordinated.standardizedFileURL == url.standardizedFileURL else { throw changedError }
        try check()
        try FileManager.default.trashItem(at: coordinated, resultingItemURL: nil)
      } catch { failure = error }
    }
    if let failure { throw failure }
    if let coordinationError { throw coordinationError }
  }

  public static func thumbnail(
    _ item: DuplicatePhoto, plan: DuplicatePhotoPlan, cancellation: PhotoRepairCancellation
  ) -> CGImage? {
    let access = plan.folder.startAccessingSecurityScopedResource()
    defer { if access { plan.folder.stopAccessingSecurityScopedResource() } }
    guard let root = try? checkedRoot(plan) else { return nil }
    defer { close(root) }
    guard let fd = try? LocalImageFiles.openItem(root, item.parts) else { return nil }
    defer { close(fd) }
    guard (try? validate(fd, item: item)) != nil else { return nil }
    let reader = ThumbnailReader(fd: fd, cancellation: cancellation)
    let info = Unmanaged.passRetained(reader).toOpaque()
    var callbacks = CGDataProviderDirectCallbacks(
      version: 0, getBytePointer: nil, releaseBytePointer: nil,
      getBytesAtPosition: { info, buffer, offset, count in
        guard let info else { return 0 }
        return Unmanaged<ThumbnailReader>.fromOpaque(info).takeUnretainedValue().read(
          buffer, offset, count)
      },
      releaseInfo: { info in if let info { Unmanaged<ThumbnailReader>.fromOpaque(info).release() } }
    )
    guard let provider = CGDataProvider(directInfo: info, size: item.size, callbacks: &callbacks)
    else {
      Unmanaged<ThumbnailReader>.fromOpaque(info).release()
      return nil
    }
    guard
      let source = CGImageSourceCreateWithDataProvider(
        provider, [kCGImageSourceShouldCache: false] as CFDictionary), !cancellation.isCancelled
    else { return nil }
    let image = CGImageSourceCreateThumbnailAtIndex(
      source, 0,
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 144,
        kCGImageSourceShouldCacheImmediately: true,
      ] as CFDictionary)
    guard let image, (try? validate(fd, item: item)) != nil, !cancellation.isCancelled,
      let bitmap = CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return bitmap.makeImage()
  }

  private final class ThumbnailReader {
    let fd: Int32
    let cancellation: PhotoRepairCancellation
    let lock = NSLock()
    var bytes = 0
    init(fd: Int32, cancellation: PhotoRepairCancellation) {
      self.fd = fd
      self.cancellation = cancellation
    }
    func read(_ buffer: UnsafeMutableRawPointer, _ offset: off_t, _ count: Int) -> Int {
      lock.lock()
      defer { lock.unlock() }
      guard !cancellation.isCancelled, offset >= 0, count >= 0, count <= (64 << 20) - bytes else {
        return 0
      }
      let result = pread(fd, buffer, count, offset)
      bytes += max(0, result)
      return max(0, result)
    }
  }
}
