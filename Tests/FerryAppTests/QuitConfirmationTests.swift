import AppKit
import XCTest

@testable import FerryApp

@MainActor
final class QuitConfirmationTests: XCTestCase {
  func testCancelLeavesApplicationRunningAndNextAttemptAsksAgain() {
    var attempts = 0
    let confirmation = QuitConfirmation { count in
      attempts += 1
      XCTAssertEqual(count, 0)
      return false
    }
    XCTAssertEqual(confirmation.shouldTerminate(), .terminateCancel)
    XCTAssertFalse(confirmation.approved)
    XCTAssertEqual(confirmation.shouldTerminate(), .terminateCancel)
    XCTAssertEqual(attempts, 2)
  }

  func testActiveTasksAreCountedAtQuitTimeAndApprovedQuitDoesNotPromptTwice() {
    var pending = 2
    var counts: [Int] = []
    let confirmation = QuitConfirmation { count in
      counts.append(count)
      return count == 3
    }
    confirmation.pendingTaskCount = { pending }
    XCTAssertEqual(confirmation.shouldTerminate(), .terminateCancel)
    pending = 3
    XCTAssertEqual(confirmation.shouldTerminate(), .terminateNow)
    XCTAssertTrue(confirmation.approved)
    XCTAssertEqual(confirmation.shouldTerminate(), .terminateNow)
    XCTAssertEqual(counts, [2, 3])
  }

  func testRepeatedQuitRequestWhileDialogOpenDoesNotPresentAnotherDialog() {
    var confirmation: QuitConfirmation!
    var attempts = 0
    confirmation = QuitConfirmation { _ in
      attempts += 1
      XCTAssertEqual(confirmation.shouldTerminate(), .terminateCancel)
      return false
    }
    XCTAssertEqual(confirmation.shouldTerminate(), .terminateCancel)
    XCTAssertEqual(attempts, 1)
  }

  func testWindowCloseKeepsWindowUntilQuitIsApprovedAndForwardsOtherDelegateMethods() {
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
      styleMask: [.titled, .closable], backing: .buffered, defer: true)
    let original = OriginalWindowDelegate()
    var quitRequests = 0
    var approved = false
    let confirmation = QuitConfirmation { _ in approved }
    let proxy = QuitWindowDelegate(original: original, confirmation: confirmation) {
      quitRequests += 1
    }
    XCTAssertFalse(proxy.windowShouldClose(window))
    XCTAssertEqual(quitRequests, 1)
    XCTAssertFalse(confirmation.approved)
    let resized = #selector(NSWindowDelegate.windowDidResize(_:))
    XCTAssertTrue(proxy.responds(to: resized))
    XCTAssertTrue(proxy.forwardingTarget(for: resized) as AnyObject? === original)
    approved = true
    XCTAssertEqual(confirmation.shouldTerminate(), .terminateNow)
    XCTAssertTrue(proxy.windowShouldClose(window))
    XCTAssertEqual(quitRequests, 1)
  }

  func testWindowHookRestoresSwiftUIDelegateWhenRemoved() {
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
      styleMask: [.titled, .closable], backing: .buffered, defer: true)
    let original = OriginalWindowDelegate()
    window.delegate = original
    let view = QuitWindowGuard.HookView()
    view.confirmation = QuitConfirmation { _ in false }
    window.contentView = view
    view.install()
    XCTAssertTrue(window.delegate is QuitWindowDelegate)
    view.install()
    view.uninstall()
    XCTAssertTrue(window.delegate === original)
  }
}

private final class OriginalWindowDelegate: NSObject, NSWindowDelegate {
  func windowDidResize(_ notification: Notification) {}
}
