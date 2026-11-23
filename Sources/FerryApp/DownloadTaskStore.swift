import Darwin
import FerryCore
import Foundation

/// Only unfinished, explicitly recoverable work is persisted. Loading it never
/// schedules a request or opens a device. Monotonic timing and session tokens
/// belong to the old process and are deliberately omitted.
final class DownloadTaskStore {
  static var defaultURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
      .appendingPathComponent("Ferry/download-tasks.json")
  }
  private let url: URL
  private let limit = 64 * 1024 * 1024

  init(url: URL) { self.url = url }

  private struct Archive: Codable {
    var version = 1
    let tasks: [Record]
  }

  private struct Record: Codable {
    let id: UUID
    let title: String
    let filterSummary: String
    let request: EngineRequest
    let demo: Bool
    let started: Bool
    let recoveryPath: String?
    let output: URL?
    let reportURL: URL?
    let total: Int
    let totalBytes: Int64
    let completed: Int
    let transferred: Int64
    let skipped: Int
  }

  func load() throws -> [DownloadTask] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? file.close() }
    let data = try file.read(upToCount: limit + 1) ?? Data()
    guard data.count <= limit else { throw EngineFailure(L10n.text("恢复记录无效或已损坏。")) }
    let archive = try JSONDecoder().decode(Archive.self, from: data)
    guard archive.version == 1, archive.tasks.count <= 128,
      Set(archive.tasks.map(\.id)).count == archive.tasks.count
    else { throw EngineFailure(L10n.text("恢复记录无效或已损坏。")) }
    return try archive.tasks.map { record in
      guard record.request.operation == "download", record.request.durableRecovery == true,
        (record.request.destination as NSString).isAbsolutePath,
        record.output?.isFileURL != false, record.reportURL?.isFileURL != false,
        record.request.sourceSelection?.isEmpty == false,
        record.total >= 0, record.totalBytes >= 0, record.transferred >= 0,
        record.completed >= 0, record.skipped >= 0,
        !record.started || record.recoveryPath != nil
      else { throw EngineFailure(L10n.text("恢复记录无效或已损坏。")) }
      var task = DownloadTask(
        id: record.id, title: record.title, filterSummary: record.filterSummary,
        state: .interrupted, completed: record.completed, total: record.total,
        transferred: record.transferred, totalBytes: record.totalBytes, skipped: record.skipped,
        request: record.request, demo: record.demo)
      task.started = record.started
      task.recoveryPath = record.recoveryPath
      task.output = record.output
      task.reportURL = record.reportURL
      task.resumeAvailable = true
      return task
    }
  }

  func save(_ tasks: [DownloadTask]) throws {
    let records = tasks.filter { $0.state != .completed && $0.hasDurableRecovery }.map { task in
      var request = task.request
      request.downloadID = nil
      request.downloadAction = nil
      request.resumeToken = nil
      request.recoveryPath = nil
      return Record(
        id: task.id, title: task.title, filterSummary: task.filterSummary, request: request,
        demo: task.demo, started: task.started, recoveryPath: task.recoveryPath,
        output: task.output, reportURL: task.reportURL,
        total: task.total, totalBytes: task.totalBytes, completed: task.completed,
        transferred: task.transferred, skipped: task.skipped)
    }
    let data = try JSONEncoder().encode(Archive(tasks: records))
    guard records.count <= 128, data.count <= limit else {
      throw EngineFailure(L10n.text("恢复记录超过安全大小限制，请分批下载。"))
    }
    let parent = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let temporary = parent.appendingPathComponent(".download-tasks-\(UUID().uuidString).tmp")
    let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer {
      try? file.close()
      try? FileManager.default.removeItem(at: temporary)
    }
    try file.write(contentsOf: data)
    try file.synchronize()
    try file.close()
    guard rename(temporary.path, url.path) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }
}
