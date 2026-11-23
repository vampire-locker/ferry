import AppKit
import FerryCore

enum AppAppearance: String, CaseIterable, Identifiable {
  case system, light, dark
  static let preferenceKey = "appearance"
  var id: Self { self }
  var title: String {
    switch self {
    case .system: return L10n.text("跟随系统")
    case .light: return L10n.text("浅色")
    case .dark: return L10n.text("深色")
    }
  }
  // AppKit is the single owner of appearance. SwiftUI hosting views inherit
  // it, including system changes after an explicit light/dark override ends.
  var nativeAppearance: NSAppearance? {
    switch self {
    case .system: return nil
    case .light: return NSAppearance(named: .aqua)
    case .dark: return NSAppearance(named: .darkAqua)
    }
  }
}
