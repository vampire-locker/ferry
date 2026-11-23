import AVKit
import AppKit
import FerryCore
import QuickLookUI
import SwiftUI

struct MediaPreviewPresentation: ViewModifier {
  @ObservedObject var media: MediaController
  func body(content: Content) -> some View {
    content.sheet(
      item: $media.previewEntry, onDismiss: { media.closePreview() },
      content: { entry in MediaPreviewView(media: media, entry: entry) })
  }
}

struct MediaPreviewView: View {
  @ObservedObject var media: MediaController
  let entry: RemoteEntry

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Image(systemName: entry.symbol).foregroundStyle(.secondary)
        Text(entry.name).font(.headline).lineLimit(1).truncationMode(.middle)
        Spacer()
        Button(L10n.text("关闭")) { media.closePreview() }.keyboardShortcut(.cancelAction)
      }
      .padding(16)
      Divider()
      Group {
        if let url = media.previewURL {
          if entry.isVideo || entry.isAudio {
            PlaybackPreview(url: url, isVideo: entry.isVideo)
          } else if entry.isPlainText {
            FileTextPreview(url: url)
          } else {
            NativeMediaPreview(url: url)
          }
        } else if let error = media.previewError {
          ContentUnavailableView {
            Label(L10n.text("无法预览"), systemImage: "exclamationmark.triangle")
          } description: {
            Text(error)
          } actions: {
            if entry.isPreviewable { Button(L10n.text("重试")) { media.openPreview(entry) } }
          }
        } else {
          VStack(spacing: 16) {
            ProgressView(
              value: Display.progress(bytes: media.previewBytes, total: media.previewTotal)
            )
            .frame(width: 300)
            Text(L10n.text("正在读取预览文件…")).font(.headline)
            Text("\(Display.bytes(media.previewBytes)) / \(Display.bytes(media.previewTotal))")
              .monospacedDigit().foregroundStyle(.secondary)
            Text(L10n.text("文件读取完成后即可预览，较大的文件需要等待。"))
              .font(.caption).foregroundStyle(.secondary)
            Button(L10n.text("取消")) { media.closePreview() }
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      Text(L10n.text("临时预览 · 手机文件只读 · 无法预览的格式可下载后打开"))
        .font(.caption).foregroundStyle(.secondary).padding(10)
    }
    .frame(minWidth: 640, idealWidth: 860, minHeight: 460, idealHeight: 620)
  }
}

@MainActor
private final class FilePlayback: ObservableObject {
  let player: AVPlayer
  @Published var error: String?
  private var observation: NSKeyValueObservation?

  init(url: URL, isVideo: Bool) {
    let item = AVPlayerItem(url: url)
    player = AVPlayer(playerItem: item)
    observation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
      if item.status == .failed {
        Task { @MainActor [weak self] in
          self?.error =
            isVideo
            ? L10n.text("macOS 无法播放此视频的格式或编码，可下载后使用其他播放器打开。")
            : L10n.text("macOS 无法播放此音频的格式或编码，可下载后使用其他播放器打开。")
        }
      }
    }
  }
}

private struct PlaybackPreview: View {
  @StateObject private var playback: FilePlayback
  let isVideo: Bool
  init(url: URL, isVideo: Bool) {
    self.isVideo = isVideo
    _playback = StateObject(wrappedValue: FilePlayback(url: url, isVideo: isVideo))
  }

  var body: some View {
    Group {
      if let error = playback.error {
        ContentUnavailableView(
          isVideo ? L10n.text("无法播放此视频") : L10n.text("无法播放此音频"),
          systemImage: isVideo ? "film" : "music.note", description: Text(error))
      } else if !isVideo {
        VStack(spacing: 16) {
          Spacer()
          Image(systemName: "music.note").font(.system(size: 64)).foregroundStyle(.secondary)
          Text(L10n.text("音频预览")).font(.headline)
          Spacer()
          NativeFilePlayer(player: playback.player, isVideo: false).frame(height: 100)
        }
      } else {
        NativeFilePlayer(player: playback.player, isVideo: true)
      }
    }
    .onAppear { playback.player.play() }
    .onDisappear {
      playback.player.pause()
      playback.player.replaceCurrentItem(with: nil)
    }
  }
}

private struct NativeFilePlayer: NSViewRepresentable {
  let player: AVPlayer
  let isVideo: Bool
  func makeNSView(context: Context) -> AVPlayerView {
    let view = AVPlayerView()
    view.controlsStyle = .inline
    view.showsFullScreenToggleButton = isVideo
    view.player = player
    return view
  }
  func updateNSView(_ view: AVPlayerView, context: Context) {
    view.showsFullScreenToggleButton = isVideo
    view.player = player
  }
  static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
    view.player?.pause()
    view.player = nil
  }
}

private struct NativeMediaPreview: NSViewRepresentable {
  let url: URL
  func makeNSView(context: Context) -> QLPreviewView {
    let view = QLPreviewView(frame: .zero, style: .normal)!
    view.shouldCloseWithWindow = false
    view.autostarts = true
    view.previewItem = url as NSURL
    return view
  }
  func updateNSView(_ view: QLPreviewView, context: Context) {
    if (view.previewItem as? NSURL) != url as NSURL { view.previewItem = url as NSURL }
  }
  static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}

/// Scoped to the browser window. Space in a text editor (including search) must
/// remain text input; Table's native mouse selection and primaryAction stay intact.
struct PreviewKeyboardCapture: NSViewRepresentable {
  let action: () -> Bool
  func makeNSView(context: Context) -> SpaceKeyView {
    let view = SpaceKeyView()
    view.action = action
    return view
  }
  func updateNSView(_ view: SpaceKeyView, context: Context) { view.action = action }

  final class SpaceKeyView: NSView {
    var action: (() -> Bool)?
    private var monitor: Any?
    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self, event.window === window, window?.attachedSheet == nil,
          event.charactersIgnoringModifiers == " ", !event.isARepeat,
          event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
          !(window?.firstResponder is NSTextView), !(window?.firstResponder is NSTextField)
        else { return event }
        return action?() == true ? nil : event
      }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
  }
}
