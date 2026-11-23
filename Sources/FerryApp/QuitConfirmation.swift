import AppKit
import FerryCore
import SwiftUI

@MainActor
final class QuitConfirmation {
  var pendingTaskCount: () -> Int = { 0 }
  private(set) var approved = false
  private var presenting = false
  private let present: @MainActor (Int) -> Bool

  init(present: @escaping @MainActor (Int) -> Bool) {
    self.present = present
  }

  convenience init() { self.init(present: { Self.showAlert(pending: $0) }) }

  func shouldTerminate() -> NSApplication.TerminateReply {
    if approved { return .terminateNow }
    guard !presenting else { return .terminateCancel }
    presenting = true
    defer { presenting = false }
    approved = present(max(0, pendingTaskCount()))
    return approved ? .terminateNow : .terminateCancel
  }

  private static func showAlert(pending: Int) -> Bool {
    let alert = NSAlert()
    alert.alertStyle = pending > 0 ? .warning : .informational
    alert.messageText = L10n.text("确定退出渡舟吗？")
    alert.informativeText =
      pending > 0
      ? L10n.text("还有 \(pending) 个任务正在进行或等待。退出会停止剩余工作；已完成的下载、日期修复和废纸篓移动会保留。")
      : L10n.text("退出将关闭渡舟并释放手机连接。")
    // Return chooses cancellation, so an accidental key press cannot stop work.
    alert.addButton(withTitle: L10n.text("取消"))
    alert.addButton(withTitle: L10n.text("退出"))
    alert.buttons[0].keyEquivalent = "\r"
    alert.buttons[1].keyEquivalent = ""
    return alert.runModal() == .alertSecondButtonReturn
  }
}

/// Ask before the window disappears. Forward every other delegate method to
/// SwiftUI, which retains ownership of sizing, restoration and window state.
final class QuitWindowDelegate: NSObject, NSWindowDelegate {
  weak var original: (any NSWindowDelegate)?
  let confirmation: QuitConfirmation
  let requestQuit: () -> Void

  init(
    original: (any NSWindowDelegate)?, confirmation: QuitConfirmation,
    requestQuit: @escaping () -> Void
  ) {
    self.original = original
    self.confirmation = confirmation
    self.requestQuit = requestQuit
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if confirmation.approved { return true }
    requestQuit()
    return false
  }

  override func responds(to selector: Selector!) -> Bool {
    super.responds(to: selector) || original?.responds(to: selector) == true
  }

  override func forwardingTarget(for selector: Selector!) -> Any? {
    if original?.responds(to: selector) == true { return original }
    return super.forwardingTarget(for: selector)
  }
}

struct QuitWindowGuard: NSViewRepresentable {
  let confirmation: QuitConfirmation

  func makeNSView(context: Context) -> HookView {
    let view = HookView()
    view.confirmation = confirmation
    return view
  }

  func updateNSView(_ view: HookView, context: Context) { view.install() }
  static func dismantleNSView(_ view: HookView, coordinator: ()) { view.uninstall() }

  final class HookView: NSView {
    var confirmation: QuitConfirmation?
    private weak var guardedWindow: NSWindow?
    private var guardDelegate: QuitWindowDelegate?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      install()
    }

    func install() {
      guard let window, let confirmation else { return }
      if guardedWindow === window, window.delegate === guardDelegate { return }
      uninstall()
      let proxy = QuitWindowDelegate(original: window.delegate, confirmation: confirmation) {
        NSApp.terminate(nil)
      }
      guardedWindow = window
      guardDelegate = proxy
      window.delegate = proxy
    }

    func uninstall() {
      if let guardedWindow, guardedWindow.delegate === guardDelegate {
        guardedWindow.delegate = guardDelegate?.original
      }
      guardedWindow = nil
      guardDelegate = nil
    }
  }
}
