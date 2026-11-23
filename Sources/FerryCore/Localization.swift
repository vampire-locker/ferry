import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
  case system
  case simplifiedChinese = "zh-Hans"
  case english = "en"

  public var id: Self { self }
  public var title: String {
    switch self {
    case .system: return L10n.text("跟随系统")
    case .simplifiedChinese: return "简体中文"
    case .english: return "English"
    }
  }

  public var resolvedIdentifier: String {
    guard self == .system else { return rawValue }
    for preferred in Locale.preferredLanguages {
      let base = preferred.split(separator: "-").first.map(String.init)
      if let supported = Self.allCases.first(where: {
        $0 != .system && $0.rawValue.split(separator: "-").first.map(String.init) == base
      }) {
        return supported.rawValue
      }
    }
    return Self.simplifiedChinese.rawValue
  }
}

/// Keeps interpolated file names and numbers separate from translation keys.
public struct LocalizedMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
  let key: String
  let arguments: [String]
  public init(stringLiteral value: String) {
    key = value
    arguments = []
  }
  public init(stringInterpolation value: StringInterpolation) {
    key = value.key
    arguments = value.arguments
  }
  public struct StringInterpolation: StringInterpolationProtocol {
    var key = ""
    var arguments: [String] = []
    public init(literalCapacity: Int, interpolationCount: Int) {
      key.reserveCapacity(literalCapacity)
      arguments.reserveCapacity(interpolationCount)
    }
    public mutating func appendLiteral(_ value: String) { key += value }
    public mutating func appendInterpolation<T>(_ value: T) {
      key += "%@"
      arguments.append(String(describing: value))
    }
  }
}

public enum L10n {
  public static let languagePreferenceKey = "appLanguage"
  // Language is fixed for the process lifetime, including background tasks and
  // helper requests. The next launch applies changes made in Settings.
  public static let languageIdentifier =
    (AppLanguage(
      rawValue: UserDefaults.standard.string(forKey: languagePreferenceKey) ?? "") ?? .system)
    .resolvedIdentifier
  public static let locale = Locale(identifier: languageIdentifier)
  private static let catalog: Bundle = {
    let resources: Bundle
    if let url = Bundle.main.url(forResource: "Ferry_FerryCore", withExtension: "bundle"),
      let packaged = Bundle(url: url)
    {
      resources = packaged
    } else {
      resources = Bundle.module
    }
    let path =
      resources.path(forResource: languageIdentifier, ofType: "lproj")
      ?? resources.path(forResource: languageIdentifier.lowercased(), ofType: "lproj")
    guard let path,
      let localized = Bundle(path: path)
    else { return resources }
    return localized
  }()

  public static func text(_ message: LocalizedMessage) -> String {
    let format = catalog.localizedString(
      forKey: message.key, value: message.key, table: "Localizable")
    guard !message.arguments.isEmpty else { return format }
    return String(
      format: format, locale: locale, arguments: message.arguments.map { $0 as CVarArg })
  }
}
