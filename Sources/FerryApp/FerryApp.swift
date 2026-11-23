import AppKit
import FerryCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  var shutdown: (() -> Void)?
  let quitConfirmation = QuitConfirmation()
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    quitConfirmation.shouldTerminate()
  }
  func applicationWillTerminate(_ notification: Notification) { shutdown?() }
}

@main
struct FerryApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @StateObject private var model = AppModel()

  var body: some Scene {
    Window(L10n.text("渡舟"), id: "main") {
      ContentView(model: model)
        .background(QuitWindowGuard(confirmation: delegate.quitConfirmation))
        .environment(\.locale, L10n.locale)
        .frame(minWidth: 920, minHeight: 650)
        .onAppear {
          delegate.shutdown = { model.shutdown() }
          delegate.quitConfirmation.pendingTaskCount = {
            model.downloadQueue.currentPendingTaskCount + (model.photoDateRepair.isBusy ? 1 : 0)
              + (model.duplicatePhotos.isBusy ? 1 : 0) + (model.mediaArchive.isBusy ? 1 : 0)
              + (model.mediaRename.isBusy ? 1 : 0)
          }
          model.activate()
        }
    }
    .defaultSize(width: 1080, height: 740)
    .commands {
      CommandGroup(replacing: .newItem) {}
      CommandMenu(L10n.text("传输")) {
        Button(L10n.text("连接手机")) { model.connect() }.disabled(model.connectionActionsBlocked)
          .keyboardShortcut("r", modifiers: [.command, .shift])
        Button(L10n.text("刷新目录")) { model.loadDirectory() }.disabled(
          model.selectedPage != .browser || model.busy || model.storages.isEmpty
        )
        .keyboardShortcut("r")
        Button(model.downloadQueue.hasPendingTasks ? L10n.text("加入下载队列") : L10n.text("下载所选项目")) {
          model.download()
        }.disabled(
          model.fileActionsBlocked || model.selection.isEmpty
        )
        .keyboardShortcut("d")
        Button(L10n.text("预览所选文件")) { model.previewSelection() }
          .disabled(model.previewActionsBlocked || model.previewableSelection == nil)
          .keyboardShortcut("y")
      }
    }
    Settings {
      SettingsView(model: model)
        .environment(\.locale, L10n.locale)
    }

  }
}
