import Foundation

public enum DirectoryMediaFilter: String, CaseIterable, Identifiable, Sendable {
  case all
  case images
  case videos

  public var id: Self { self }

  public var title: String {
    switch self {
    case .all: return L10n.text("全部类型")
    case .images: return L10n.text("图片")
    case .videos: return L10n.text("视频")
    }
  }

  public func matches(_ entry: RemoteEntry) -> Bool {
    switch self {
    case .all: return true
    case .images: return entry.isImage
    case .videos: return entry.isVideo
    }
  }
}
