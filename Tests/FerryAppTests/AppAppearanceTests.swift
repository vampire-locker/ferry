import AppKit
import FerryCore
import SwiftUI
import XCTest

@testable import FerryApp

private final class AppearanceEngine: EngineRunning, @unchecked Sendable {
  func events(for request: EngineRequest, demo: Bool) -> AsyncThrowingStream<EngineEvent, Error> {
    XCTFail("Appearance tests must not access any device")
    return AsyncThrowingStream { $0.finish() }
  }
  func cancel() {}
  func shutdown() {}
}

@MainActor
private final class SchemeRecorder {
  var scheme: ColorScheme?
}

private struct SchemeProbe: NSViewRepresentable {
  let recorder: SchemeRecorder
  func makeNSView(context: Context) -> NSView { NSView() }
  func updateNSView(_ view: NSView, context: Context) {
    recorder.scheme = context.environment.colorScheme
  }
}

@MainActor
final class AppAppearanceTests: XCTestCase {
  func testLightDarkAndSystemKeepWindowsAndSwiftUIInSync() async throws {
    let app = NSApplication.shared
    let original = app.appearance
    defer { app.appearance = original }
    app.appearance = nil
    let systemName = app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])!
    let systemScheme: ColorScheme = systemName == .darkAqua ? .dark : .light
    let domain = "ferry-appearance-\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: domain)!
    defer { preferences.removePersistentDomain(forName: domain) }
    let model = AppModel(runner: AppearanceEngine(), preferences: preferences)
    defer { model.shutdown() }

    let mainRecorder = SchemeRecorder()
    let settingsRecorder = SchemeRecorder()
    let main = window(content: SchemeProbe(recorder: mainRecorder))
    let settings = window(
      content: SettingsView(model: model).background(SchemeProbe(recorder: settingsRecorder)))
    defer {
      main.contentView = nil
      settings.contentView = nil
      main.close()
      settings.close()
    }

    for appearance in [AppAppearance.light, .dark, .system, .light, .system, .dark, .system] {
      model.setAppearance(appearance)
      let expectedName =
        appearance.nativeAppearance?.bestMatch(from: [.aqua, .darkAqua]) ?? systemName
      let expectedScheme: ColorScheme =
        appearance == .system ? systemScheme : appearance == .dark ? .dark : .light
      for _ in 0..<200 {
        main.contentView?.layoutSubtreeIfNeeded()
        settings.contentView?.layoutSubtreeIfNeeded()
        if mainRecorder.scheme == expectedScheme && settingsRecorder.scheme == expectedScheme {
          break
        }
        try await Task.sleep(nanoseconds: 10_000_000)
      }
      for window in [main, settings] {
        XCTAssertNil(window.appearance, "Windows must inherit the application appearance")
        XCTAssertEqual(
          window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), expectedName)
        XCTAssertEqual(
          window.contentView?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), expectedName)
      }
      XCTAssertEqual(mainRecorder.scheme, expectedScheme, "main: \(appearance)")
      XCTAssertEqual(settingsRecorder.scheme, expectedScheme, "settings: \(appearance)")
      XCTAssertEqual(preferences.string(forKey: AppAppearance.preferenceKey), appearance.rawValue)
      if appearance == .system { XCTAssertNil(app.appearance) }
    }
  }

  private func window<Content: View>(content: Content) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 700),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: content)
    return window
  }
}
