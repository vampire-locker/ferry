import Foundation

enum DownloadDestination {
  static let preferenceKey = "downloadDestinationPath"

  static var defaultURL: URL {
    FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
  }

  static func restore(from preferences: UserDefaults) -> URL {
    guard let path = preferences.string(forKey: preferenceKey), isValidPath(path) else {
      return defaultURL
    }
    // Keep missing/unmounted locations. Falling back here would silently
    // redirect the next backup to a different folder or disk.
    return URL(fileURLWithPath: path, isDirectory: true)
  }

  static func isValidPath(_ path: String) -> Bool {
    path.hasPrefix("/") && !path.contains("\0")
  }

  static func isAvailable(_ url: URL) -> Bool {
    guard url.isFileURL, isValidPath(url.path) else { return false }
    var directory: ObjCBool = false
    let files = FileManager.default
    return files.fileExists(atPath: url.path, isDirectory: &directory)
      && directory.boolValue && files.isWritableFile(atPath: url.path)
  }
}
