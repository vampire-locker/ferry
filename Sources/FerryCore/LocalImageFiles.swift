import Darwin
import Foundation

// Shared scope rules for local image tools; never follows descendant links.
enum LocalImageFiles {
  static func isContainer(_ url: URL, flagged: Bool?) -> Bool {
    flagged == true
      || ["photoslibrary", "photolibrary", "aplibrary", "app", "bundle", "framework"].contains(
        url.pathExtension.lowercased())
  }
  static func checkedStat(_ fd: Int32) throws -> stat {
    var value = stat()
    guard fstat(fd, &value) == 0 else { throw systemError() }
    return value
  }
  static func systemError() -> Error {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
  static func openRoot(_ folder: URL) throws -> Int32 {
    guard folder.isFileURL else { throw EngineFailure(L10n.text("请选择本地图片文件夹。")) }
    if folder.resolvingSymlinksInPath().pathComponents.contains(where: {
      ["photoslibrary", "photolibrary", "aplibrary", "app", "bundle", "framework"].contains(
        ($0 as NSString).pathExtension.lowercased())
    }) {
      throw EngineFailure(L10n.text("请选择普通文件夹，不处理照片资料库或应用包。"))
    }
    let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw systemError() }
    return fd
  }
  // Every component is opened relative to the selected root; symlinks are
  // rejected even if a parent was replaced after the scan.
  static func openItem(_ root: Int32, _ parts: [String], directory: Bool = false) throws
    -> Int32
  {
    guard !parts.isEmpty, parts.count <= 128,
      parts.allSatisfy({
        !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\0")
      })
    else { throw EngineFailure(L10n.text("文件路径超出安全范围。")) }
    var current = dup(root)
    guard current >= 0 else { throw systemError() }
    for (index, part) in parts.enumerated() {
      let flags =
        O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        | (index < parts.count - 1 || directory ? O_DIRECTORY : 0)
      let next = openat(current, part, flags)
      close(current)
      guard next >= 0 else { throw systemError() }
      current = next
    }
    return current
  }

}
