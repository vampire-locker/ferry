import CryptoKit
import Darwin
import Foundation

// Same-volume moves: exclusive rename, coordinated reservation, then verified copy.
// The caller explicitly opts into the reservation path inside NSFileCoordinator.
enum ArchiveFileMove {
  struct Snapshot: Equatable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let mode: UInt16
    let links: UInt16
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
      mode = value.st_mode
      links = value.st_nlink
      modifiedSeconds = value.st_mtimespec.tv_sec
      modifiedNanos = value.st_mtimespec.tv_nsec
      createdSeconds = value.st_birthtimespec.tv_sec
      createdNanos = value.st_birthtimespec.tv_nsec
      changedSeconds = value.st_ctimespec.tv_sec
      changedNanos = value.st_ctimespec.tv_nsec
    }
  }
  struct FileDates {
    var created: timespec
    var modified: timespec
  }
  typealias Rename = (Int32, String, Int32, String) throws -> Void

  static func exclusiveRename(_ from: Int32, _ name: String, _ to: Int32, _ target: String) throws {
    guard renameatx_np(from, name, to, target, UInt32(RENAME_EXCL)) == 0 else {
      if errno == EEXIST || errno == ENOTEMPTY {
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError)
      }
      throw LocalImageFiles.systemError()
    }
  }

  static func move(
    sourceParent: Int32, sourceName: String, sourceFD: Int32,
    destinationParent: Int32, destinationName: String,
    cancellation: PhotoRepairCancellation, allowReservedRename: Bool = false,
    rename: Rename = exclusiveRename, reservedRename: Rename = plainRename,
    validatePaths: () throws -> Void,
    progress: (Int64, Int64, Bool) -> Void = { _, _, _ in }
  ) throws {
    guard
      [sourceName, destinationName].allSatisfy({
        !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\0")
      })
    else { throw EngineFailure(L10n.text("文件路径超出安全范围。")) }
    if cancellation.isCancelled { throw CancellationError() }
    do {
      try rename(sourceParent, sourceName, destinationParent, destinationName)
    } catch let error as POSIXError where [.ENOTSUP, .ENOSYS, .EINVAL].contains(error.code) {
      if allowReservedRename {
        do {
          try moveUsingReservation(
            sourceParent: sourceParent, sourceName: sourceName, sourceFD: sourceFD,
            destinationParent: destinationParent, destinationName: destinationName,
            cancellation: cancellation, rename: reservedRename, validatePaths: validatePaths)
          return
        } catch ReservationFailure.unsupported {
          // Only an unsupported ordinary rename falls back to the verified copy.
        }
      }
      try copyAndRemove(
        sourceParent: sourceParent, sourceName: sourceName, sourceFD: sourceFD,
        destinationParent: destinationParent, destinationName: destinationName,
        cancellation: cancellation, validatePaths: validatePaths, progress: progress)
    }
  }

  private enum ReservationFailure: Error { case unsupported }

  static func plainRename(_ from: Int32, _ name: String, _ to: Int32, _ target: String) throws {
    guard renameat(from, name, to, target) == 0 else { throw LocalImageFiles.systemError() }
  }

  // Called within the file coordinator. Claim the destination before the ordinary rename.
  // This is a coordinated best-effort path, not a kernel-level RENAME_EXCL guarantee.
  private static func moveUsingReservation(
    sourceParent: Int32, sourceName: String, sourceFD: Int32,
    destinationParent: Int32, destinationName: String, cancellation: PhotoRepairCancellation,
    rename: Rename, validatePaths: () throws -> Void
  ) throws {
    try validatePaths()
    let source = try LocalImageFiles.checkedStat(sourceFD)
    let expected = Snapshot(source)
    guard source.st_mode & S_IFMT == S_IFREG, source.st_nlink == 1,
      try LocalImageFiles.checkedStat(destinationParent).st_dev == source.st_dev
    else { throw EngineFailure(L10n.text("归档目录不能跨越其他磁盘或链接。")) }
    try validateSource(sourceFD, parent: sourceParent, name: sourceName, expected: expected)
    if cancellation.isCancelled { throw CancellationError() }
    let placeholder = openat(
      destinationParent, destinationName,
      O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard placeholder >= 0 else {
      if errno == EEXIST {
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError)
      }
      throw LocalImageFiles.systemError()
    }
    defer { close(placeholder) }
    let claimed = Snapshot(try LocalImageFiles.checkedStat(placeholder))
    func ownsEmptyPlaceholder() -> Bool {
      var atPath = stat()
      return fstatat(destinationParent, destinationName, &atPath, AT_SYMLINK_NOFOLLOW) == 0
        && Snapshot(atPath) == claimed && atPath.st_size == 0
        && (try? LocalImageFiles.checkedStat(placeholder)).map(Snapshot.init) == claimed
    }
    do {
      try validatePaths()
      try validateSource(sourceFD, parent: sourceParent, name: sourceName, expected: expected)
      guard ownsEmptyPlaceholder() else {
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError)
      }
      if cancellation.isCancelled { throw CancellationError() }
      do {
        try rename(sourceParent, sourceName, destinationParent, destinationName)
      } catch let error as POSIXError where [.ENOTSUP, .ENOSYS, .EINVAL].contains(error.code) {
        throw ReservationFailure.unsupported
      }
    } catch {
      // Never remove a name or empty file that another process has replaced or modified.
      if ownsEmptyPlaceholder(), unlinkat(destinationParent, destinationName, 0) != 0 {
        throw EngineFailure(
          L10n.text("快速归档未完成，源文件未移动；占位文件清理失败：\(destinationName)。原因：\(error.localizedDescription)"))
      }
      throw error
    }
  }

  private static func copyAndRemove(
    sourceParent: Int32, sourceName: String, sourceFD: Int32,
    destinationParent: Int32, destinationName: String, cancellation: PhotoRepairCancellation,
    validatePaths: () throws -> Void, progress: (Int64, Int64, Bool) -> Void
  ) throws {
    let source = try LocalImageFiles.checkedStat(sourceFD)
    let expected = Snapshot(source)
    guard source.st_mode & S_IFMT == S_IFREG, source.st_nlink == 1, source.st_size >= 0,
      try LocalImageFiles.checkedStat(destinationParent).st_dev == source.st_dev
    else { throw EngineFailure(L10n.text("归档目录不能跨越其他磁盘或链接。")) }
    try validatePaths()
    try validateSource(sourceFD, parent: sourceParent, name: sourceName, expected: expected)
    try checkSpace(destinationParent, needed: source.st_size)
    if cancellation.isCancelled { throw CancellationError() }
    let output = openat(
      destinationParent, destinationName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard output >= 0 else {
      if errno == EEXIST {
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError)
      }
      throw LocalImageFiles.systemError()
    }
    defer { close(output) }
    do {
      var buffer = [UInt8](repeating: 0, count: 1 << 20)
      var hasher = SHA256()
      var offset: Int64 = 0
      progress(0, source.st_size, false)
      while offset < source.st_size {
        if cancellation.isCancelled { throw CancellationError() }
        let requested = Int(min(Int64(buffer.count), source.st_size - offset))
        let count = buffer.withUnsafeMutableBytes { bytes -> Int in
          var count: Int
          repeat {
            count = pread(sourceFD, bytes.baseAddress, requested, off_t(offset))
          } while count < 0 && errno == EINTR
          return count
        }
        guard count > 0 else {
          if count < 0 { throw LocalImageFiles.systemError() }
          throw EngineFailure(L10n.text("本地文件复制校验失败，源文件已保留。"))
        }
        try checkSpace(destinationParent, needed: Int64(count))
        try buffer.withUnsafeBytes { bytes in
          hasher.update(
            bufferPointer: UnsafeRawBufferPointer(start: bytes.baseAddress, count: count))
          var written = 0
          while written < count {
            if cancellation.isCancelled { throw CancellationError() }
            var amount: Int
            repeat {
              amount = write(output, bytes.baseAddress!.advanced(by: written), count - written)
            } while amount < 0 && errno == EINTR
            guard amount > 0 else { throw LocalImageFiles.systemError() }
            written += amount
          }
        }
        offset += Int64(count)
        progress(offset, source.st_size, false)
      }
      try validateSource(sourceFD, parent: sourceParent, name: sourceName, expected: expected)
      guard fchmod(output, source.st_mode & 0o777) == 0 else { throw LocalImageFiles.systemError() }
      var attributes = attrlist()
      attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
      attributes.commonattr = UInt32(ATTR_CMN_CRTIME) | UInt32(ATTR_CMN_MODTIME)
      var dates = FileDates(created: source.st_birthtimespec, modified: source.st_mtimespec)
      guard fsetattrlist(output, &attributes, &dates, MemoryLayout<FileDates>.size, 0) == 0,
        fsync(output) == 0
      else { throw LocalImageFiles.systemError() }
      let beforeHash = try LocalImageFiles.checkedStat(output)
      let tolerance = try dateTolerance(output)
      guard beforeHash.st_size == source.st_size,
        sameDate(beforeHash.st_birthtimespec, source.st_birthtimespec, tolerance: tolerance),
        sameDate(beforeHash.st_mtimespec, source.st_mtimespec, tolerance: tolerance)
      else { throw EngineFailure(L10n.text("文件系统未能保留原文件日期，源文件已保留。")) }
      let verificationTotal = source.st_size.multipliedReportingOverflow(by: 2)
      guard !verificationTotal.overflow else {
        throw EngineFailure(L10n.text("本地文件复制校验失败，源文件已保留。"))
      }
      func digest(_ fd: Int32, start: Int64) throws -> SHA256.Digest {
        var hash = SHA256()
        var position: Int64 = 0
        progress(start, verificationTotal.partialValue, true)
        while position < source.st_size {
          if cancellation.isCancelled { throw CancellationError() }
          let requested = Int(min(Int64(buffer.count), source.st_size - position))
          let count = buffer.withUnsafeMutableBytes { bytes -> Int in
            var count: Int
            repeat {
              count = pread(fd, bytes.baseAddress, requested, off_t(position))
            } while count < 0 && errno == EINTR
            return count
          }
          guard count > 0 else { throw EngineFailure(L10n.text("本地文件复制校验失败，源文件已保留。")) }
          buffer.withUnsafeBytes { bytes in
            hash.update(
              bufferPointer: UnsafeRawBufferPointer(start: bytes.baseAddress, count: count))
          }
          position += Int64(count)
          progress(start + position, verificationTotal.partialValue, true)
        }
        return hash.finalize()
      }
      let expectedHash = hasher.finalize()
      guard try digest(output, start: 0) == expectedHash,
        try digest(sourceFD, start: source.st_size) == expectedHash,
        Snapshot(try LocalImageFiles.checkedStat(output)) == Snapshot(beforeHash)
      else { throw EngineFailure(L10n.text("本地文件复制校验失败，源文件已保留。")) }
      try validatePaths()
      try validateSource(sourceFD, parent: sourceParent, name: sourceName, expected: expected)
      var atTarget = stat()
      guard fstatat(destinationParent, destinationName, &atTarget, AT_SYMLINK_NOFOLLOW) == 0,
        Snapshot(atTarget) == Snapshot(beforeHash)
      else { throw EngineFailure(L10n.text("归档目标在复制期间发生变化，源文件已保留。")) }
      if cancellation.isCancelled { throw CancellationError() }
      guard unlinkat(sourceParent, sourceName, 0) == 0 else { throw LocalImageFiles.systemError() }
    } catch {
      var current = stat()
      if let owned = try? LocalImageFiles.checkedStat(output),
        fstatat(destinationParent, destinationName, &current, AT_SYMLINK_NOFOLLOW) == 0,
        current.st_dev == owned.st_dev, current.st_ino == owned.st_ino
      {
        // This is our new copy; clear its read-only mode before rollback on FAT-like volumes.
        _ = fchmod(output, 0o600)
        if unlinkat(destinationParent, destinationName, 0) != 0 {
          throw EngineFailure(
            L10n.text("归档未完成，源文件已保留；副本清理失败：\(destinationName)。原因：\(error.localizedDescription)"))
        }
      }
      throw error
    }
  }

  private static func validateSource(_ fd: Int32, parent: Int32, name: String, expected: Snapshot)
    throws
  {
    var current = stat()
    guard Snapshot(try LocalImageFiles.checkedStat(fd)) == expected,
      fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
      Snapshot(current) == expected
    else { throw EngineFailure(L10n.text("扫描后文件已变化，已跳过。")) }
  }
  static func dateTolerance(_ fd: Int32) throws -> Double {
    var info = statfs()
    guard fstatfs(fd, &info) == 0 else { throw LocalImageFiles.systemError() }
    let name = withUnsafeBytes(of: info.f_fstypename) { bytes in
      String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }.lowercased()
    return ["exfat", "msdos", "fat", "vfat"].contains(name) ? 2 : 0
  }
  static func sameDate(_ a: timespec, _ b: timespec, tolerance: Double = 0) -> Bool {
    if a.tv_sec == b.tv_sec && a.tv_nsec == b.tv_nsec { return true }
    guard tolerance > 0 else { return false }
    let delta = Double(a.tv_sec) - Double(b.tv_sec) + Double(a.tv_nsec - b.tv_nsec) / 1e9
    return abs(delta) <= tolerance
  }
  private static func checkSpace(_ fd: Int32, needed: Int64) throws {
    var info = statfs()
    guard fstatfs(fd, &info) == 0 else { throw LocalImageFiles.systemError() }
    let (available, overflow) = UInt64(info.f_bavail).multipliedReportingOverflow(
      by: UInt64(info.f_bsize))
    let required = UInt64(max(0, needed)).addingReportingOverflow(64 << 20)
    guard !overflow, !required.overflow, available >= required.partialValue else {
      throw EngineFailure(L10n.text("空间不足，兼容归档需要额外的文件副本空间和 64 MiB 预留。"))
    }
  }
}
