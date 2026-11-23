import AppKit
import SwiftUI

/// Keep the native browser and its scroll state alive in a separate hosting
/// tree. Download-row layout cannot walk the hidden Table/LazyVGrid subtree.
struct RetainedBrowserHost: NSViewRepresentable {
  let model: AppModel
  let isVisible: Bool
  @Environment(\.locale) private var locale

  func makeNSView(context: Context) -> RetainedBrowserContainer {
    RetainedBrowserContainer(model: model, locale: locale)
  }
  func updateNSView(_ view: RetainedBrowserContainer, context: Context) {
    view.update(model: model, locale: locale, isVisible: isVisible)
  }
}

final class RetainedBrowserContainer: NSView {
  private(set) var model: AppModel
  private var locale: Locale
  let hostingView: NSHostingView<AnyView>

  init(model: AppModel, locale: Locale) {
    self.model = model
    self.locale = locale
    hostingView = NSHostingView(rootView: Self.root(model: model, locale: locale))
    super.init(frame: .zero)
    autoresizesSubviews = false
    addSubview(hostingView)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  func update(model: AppModel, locale: Locale, isVisible: Bool) {
    if self.model !== model || self.locale != locale {
      self.model = model
      self.locale = locale
      hostingView.rootView = Self.root(model: model, locale: locale)
    }
    if isHidden == isVisible {
      isHidden = !isVisible
      needsLayout = true
    }
  }

  override func layout() {
    super.layout()
    // Do not resize or relayout the retained hosting tree while it is hidden.
    guard !isHidden else { return }
    if hostingView.frame != bounds { hostingView.frame = bounds }
  }

  private static func root(model: AppModel, locale: Locale) -> AnyView {
    AnyView(
      BrowserPageView(model: model)
        .environment(\.locale, locale)
        .tint(ferryAccent)
        .background(Color(nsColor: .controlBackgroundColor)))
  }
}
