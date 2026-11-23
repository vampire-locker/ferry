import Foundation

public struct DeviceStorage: Codable, Identifiable, Hashable, Sendable {
  public let id: UInt32
  public let name: String
  public let capacity: UInt64
  public let free: UInt64
}

public struct RemoteEntry: Codable, Identifiable, Hashable, Sendable {
  public let id: UInt32
  public let storageID: UInt32
  public let name: String
  public let isDirectory: Bool
  public let size: Int64
  public let modified: Int64

  public var isHidden: Bool { name.hasPrefix(".") }
  public var sortSize: Int64 { isDirectory ? 0 : size }
  // A size of -1 is only used by explicitly requested fast directory listings.
  public var hasKnownSize: Bool { isDirectory || size >= 0 }
  public var sizeDescription: String { size < 0 ? L10n.text("未读取") : Display.bytes(size) }

  public func replacingSize(_ value: Int64) -> RemoteEntry {
    RemoteEntry(
      id: id, storageID: storageID, name: name, isDirectory: isDirectory,
      size: isDirectory ? 0 : value, modified: modified)
  }
  public var isImage: Bool {
    !isDirectory && Self.isImageFilename(name)
  }
  public static func isImageFilename(_ name: String) -> Bool {
    imageExtensions.contains((name as NSString).pathExtension.lowercased())
  }
  public var isVideo: Bool {
    !isDirectory && Self.isVideoFilename(name)
  }
  public static func isVideoFilename(_ name: String) -> Bool {
    videoExtensions.contains((name as NSString).pathExtension.lowercased())
  }
  public var isAudio: Bool {
    !isDirectory && Self.audioExtensions.contains((name as NSString).pathExtension.lowercased())
  }
  public var isPlainText: Bool {
    !isDirectory && Self.textExtensions.contains((name as NSString).pathExtension.lowercased())
  }
  public var isDocument: Bool {
    !isDirectory
      && (isPlainText
        || Self.documentExtensions.contains((name as NSString).pathExtension.lowercased()))
  }
  public var isThumbnailEligible: Bool { isImage || isVideo }
  public var isPreviewable: Bool { isThumbnailEligible || isAudio || isDocument }
  // Keep media extensions aligned with transfer.MediaKind in the helper.
  private static let imageExtensions: Set<String> = [
    "jpg", "jpeg", "jpe", "jfif", "pjpeg", "pjp", "png", "apng",
    "heic", "heif", "heics", "heifs", "hif", "avif", "avifs", "webp", "gif",
    "bmp", "dib", "tif", "tiff", "jp2", "j2k", "jpf", "jpx", "jxl",
    "svg", "svgz", "ico", "icns", "psd", "psb",
    "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2",
    "orf", "rw2", "rwl", "raf", "srw", "pef", "x3f", "erf", "kdc", "dcr",
    "mos", "mrw", "3fr", "fff", "iiq",
  ]
  private static let videoExtensions: Set<String> = [
    "mp4", "mov", "m4v", "mkv", "webm", "avi", "3gp", "3g2", "3gpp", "3gpp2",
    "mpg", "mpeg", "mpe", "m1v", "m2v", "mpv", "mts", "m2ts", "m2t", "ts",
    "mxf", "flv", "f4v", "vob", "ogv", "wmv", "asf", "rm", "rmvb",
    "divx", "xvid", "nsv", "h264", "264", "h265", "265", "hevc",
  ]
  // Full previews are explicit requests. Audio/documents never enter the
  // background image/video thumbnail queue. Keep aligned with PreviewKind.
  private static let audioExtensions: Set<String> = [
    "mp3", "m4a", "m4b", "m4r", "aac", "wav", "wave", "aif", "aiff", "aifc",
    "flac", "alac", "ogg", "oga", "opus", "amr", "wma", "caf",
  ]
  private static let textExtensions: Set<String> = [
    "txt", "text", "md", "markdown", "csv", "tsv", "log", "json", "xml", "yaml", "yml",
  ]
  private static let documentExtensions: Set<String> = [
    "pdf", "rtf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp",
  ]

  public var kind: String {
    if isDirectory { return L10n.text("文件夹") }
    if isImage { return L10n.text("图片") }
    if isVideo { return L10n.text("视频") }
    if isAudio { return L10n.text("音频") }
    if isDocument { return L10n.text("文档") }
    let ext = (name as NSString).pathExtension.lowercased()
    return ext.isEmpty ? L10n.text("文件") : ext.uppercased() + L10n.text(" 文件")
  }

  public var symbol: String {
    if isDirectory { return "folder.fill" }
    if isImage { return "photo" }
    if isVideo { return "film" }
    if isAudio { return "music.note" }
    return "doc.text"
  }
}

public struct EngineRequest: Codable, Sendable {
  public let operation: String
  public var deviceKey: String = ""
  public var storageID: UInt32 = 0
  public var parentID: UInt32 = 0
  public var objectIDs: [UInt32] = []
  public var destination: String = ""
  public var downloadLayout: String?
  public var reportDirectory: String?
  public var usePhotoCreationDate: Bool = false
  public var archivePhotosByMonth: Bool = false
  public var archiveVideosByMonth: Bool = false
  public var promptConflicts: Bool = false
  public var conflictDecision: DownloadConflictDecision?
  public var showHiddenFiles: Bool = false
  public var includeSizes: Bool?
  public var usbTarget: USBDeviceTarget?
  public var downloadID: String?
  public var downloadAction: String?
  public var resumeToken: String?
  public var recoveryPath: String?
  public var recoveryIdentity: String?
  public var durableRecovery: Bool? = nil
  public var sourceDirectory: [String]?
  public var sourceSelection: [RemoteEntry]?
  public var sourceStorage: DeviceStorage?

  public init(
    operation: String, deviceKey: String = "", storageID: UInt32 = 0, parentID: UInt32 = 0,
    objectIDs: [UInt32] = [], destination: String = "", showHiddenFiles: Bool = false,
    includeSizes: Bool? = nil, usbTarget: USBDeviceTarget? = nil,
    downloadID: String? = nil, downloadAction: String? = nil,
    downloadLayout: String? = nil, reportDirectory: String? = nil,
    usePhotoCreationDate: Bool = false, archivePhotosByMonth: Bool = false,
    archiveVideosByMonth: Bool = false,
    promptConflicts: Bool = false
  ) {
    self.operation = operation
    self.deviceKey = deviceKey
    self.storageID = storageID
    self.parentID = parentID
    self.objectIDs = objectIDs
    self.destination = destination
    self.downloadLayout = downloadLayout
    self.reportDirectory = reportDirectory
    self.usePhotoCreationDate = usePhotoCreationDate
    self.archivePhotosByMonth = archivePhotosByMonth
    self.archiveVideosByMonth = archiveVideosByMonth
    self.promptConflicts = promptConflicts
    self.showHiddenFiles = showHiddenFiles
    self.includeSizes = includeSizes
    self.usbTarget = usbTarget
    self.downloadID = downloadID
    self.downloadAction = downloadAction
  }
}

public struct RemoteObjectSize: Codable, Sendable {
  public let id: UInt32
  public let size: Int64
}

public struct EngineEvent: Decodable, Sendable {
  // In --serve mode, ready follows a successful terminal event and means the
  // next serial request may start; authorization_denied stops automatic retry.
  // diagnostic carries helper logs in message and does not complete a request.
  // yielded ends one download step at a file boundary; ready permits browsing
  // or the next step on the same session. downloadID identifies in-memory work.
  public let objectID: UInt32?
  public let type: String
  public let message: String?
  public let deviceName: String?
  public let deviceKey: String?
  public let storages: [DeviceStorage]?
  public let entries: [RemoteEntry]?
  public let sizes: [RemoteObjectSize]?
  public let currentFile: String?
  public let completed: Int?
  public let total: Int?
  public let bytes: Int64?
  public let totalBytes: Int64?
  public let output: String?
  public let reportPath: String?
  public let state: String?
  public let conflict: DownloadConflict?
  public let skipped: Int?
  public let resumeToken: String?
  public let recoveryPath: String?
  public let recoveryIdentity: String?
  // Logical progress without a new device read: recovery reuse or an early skip.
  public let reusedBytes: Int64?
}

public struct DownloadConflict: Decodable, Sendable, Identifiable {
  public let id: String
  public let kind: String
  public let targetPath: String
  public let name: String
  public let existingSize: Int64
  public let existingModified: Int64
  public let incomingSize: Int64
  public let incomingModified: Int64
  public let canReplace: Bool
  public let candidates: [String]?
}

public struct DownloadConflictDecision: Codable, Sendable {
  public let id: String
  public let choice: String
  public let applyToAll: Bool
  public let directory: String?
  public init(id: String, choice: String, applyToAll: Bool = false, directory: String? = nil) {
    self.id = id
    self.choice = choice
    self.applyToAll = applyToAll
    self.directory = directory
  }
}

public enum Display {
  public static func duration(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds < Double(Int.max) else { return "—" }
    let value = Int(max(0, seconds).rounded(.down))
    if value >= 3600 {
      return String(format: "%02d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60)
    }
    return String(format: "%02d:%02d", value / 60, value % 60)
  }

  public static func bytes(_ value: Int64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var amount = Double(max(0, value))
    var index = 0
    while amount >= 1024 && index < units.count - 1 {
      amount /= 1024
      index += 1
    }
    return index == 0
      ? "\(Int(amount)) B" : String(format: "%.1f %@", locale: L10n.locale, amount, units[index])
  }

  public static func bytesPerSecond(_ value: Double) -> String {
    guard value.isFinite, value > 0 else { return "—" }
    let units = ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
    var amount = value
    var index = 0
    while amount >= 1024 && index < units.count - 1 {
      amount /= 1024
      index += 1
    }
    return String(format: "%.1f %@", locale: L10n.locale, amount, units[index])
  }

  public static func progress(bytes: Int64, total: Int64) -> Double {
    guard total > 0 else { return 0 }
    return min(1, max(0, Double(bytes) / Double(total)))
  }
}

// Handles arbitrary pipe chunk boundaries, including split UTF-8 characters.
public struct EventFramer {
  private var buffer = Data()
  private var scannedOffset = 0
  public init() {}

  public mutating func append(_ chunk: Data) throws -> [EngineEvent] {
    buffer.append(chunk)
    guard buffer.count <= 64 * 1024 * 1024 else { throw EngineFailure(L10n.text("引擎响应超过大小限制")) }
    var events: [EngineEvent] = []
    var lineStart = buffer.startIndex
    var scanStart = buffer.index(buffer.startIndex, offsetBy: scannedOffset)
    while let newline = buffer[scanStart...].firstIndex(of: 10) {
      let line = buffer[lineStart..<newline]
      if !line.isEmpty { events.append(try JSONDecoder().decode(EngineEvent.self, from: line)) }
      lineStart = buffer.index(after: newline)
      scanStart = lineStart
    }
    if lineStart != buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<lineStart) }
    // Scan each byte once, rather than repeatedly scanning a multi-MB listing
    // from its beginning every time another pipe chunk arrives.
    scannedOffset = buffer.count
    return events
  }

  public func finish() throws {
    if !buffer.isEmpty { throw EngineFailure(L10n.text("引擎响应意外中断，请重新连接手机")) }
  }
}

public struct EngineFailure: LocalizedError, Sendable {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}
