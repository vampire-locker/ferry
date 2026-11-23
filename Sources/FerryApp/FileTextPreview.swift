import AppKit
import CoreFoundation
import FerryCore
import SwiftUI

private struct TextPreviewContent: Sendable {
  let text: String
  let truncated: Bool
}

struct FileTextPreview: View {
  let url: URL
  @State private var content: TextPreviewContent?
  @State private var error: String?

  var body: some View {
    Group {
      if let content {
        VStack(spacing: 0) {
          ReadOnlyTextView(text: content.text)
          if content.truncated {
            Text(L10n.text("文本较长，预览仅显示前 1 MiB。可下载查看完整内容。"))
              .font(.caption).foregroundStyle(.secondary).padding(10)
          }
        }
      } else if let error {
        ContentUnavailableView(L10n.text("无法预览"), systemImage: "doc.text", description: Text(error))
      } else {
        ProgressView()
      }
    }
    .task(id: url) {
      content = nil
      error = nil
      let file = url
      let reader = Task.detached(priority: .userInitiated) { try Self.read(file) }
      do {
        let result = try await withTaskCancellationHandler(
          operation: { try await reader.value }, onCancel: { reader.cancel() })
        guard !Task.isCancelled else { return }
        content = result
      } catch {
        if !Task.isCancelled { self.error = error.localizedDescription }
      }
    }
  }

  nonisolated private static func read(_ url: URL) throws -> TextPreviewContent {
    let limit = 1024 * 1024
    try Task.checkCancellation()
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let bytes = try handle.read(upToCount: limit + 1) ?? Data()
    let truncated = bytes.count > limit
    let prefix = Data(bytes.prefix(limit))
    if prefix.isEmpty { return TextPreviewContent(text: "", truncated: false) }
    let hasUTF16BOM = prefix.starts(with: [0xff, 0xfe]) || prefix.starts(with: [0xfe, 0xff])
    let hasUTF32BOM =
      prefix.starts(with: [0xff, 0xfe, 0x00, 0x00])
      || prefix.starts(with: [0x00, 0x00, 0xfe, 0xff])
    let gb18030 = String.Encoding(
      rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    let encodings: [String.Encoding] =
      hasUTF32BOM ? [.utf32] : hasUTF16BOM ? [.utf16] : [.utf8, gb18030, .windowsCP1252]
    for encoding in encodings {
      // A byte-limited prefix can end halfway through a character.
      for trim in 0...(truncated ? min(3, prefix.count - 1) : 0) {
        try Task.checkCancellation()
        if let text = String(data: prefix.dropLast(trim), encoding: encoding) {
          return TextPreviewContent(text: text, truncated: truncated)
        }
      }
    }
    throw EngineFailure(L10n.text("无法识别文本编码，可下载后使用其他应用打开。"))
  }
}

private struct ReadOnlyTextView: NSViewRepresentable {
  let text: String
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    let view = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
    view.isEditable = false
    view.isSelectable = true
    view.isRichText = false
    view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    view.textColor = .labelColor
    view.backgroundColor = .textBackgroundColor
    view.textContainerInset = NSSize(width: 14, height: 14)
    view.isVerticallyResizable = true
    view.isHorizontallyResizable = false
    view.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    view.autoresizingMask = [.width]
    view.textContainer?.widthTracksTextView = true
    view.textContainer?.containerSize = NSSize(
      width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
    view.string = text
    scroll.documentView = view
    return scroll
  }
  func updateNSView(_ view: NSScrollView, context: Context) {
    if let textView = view.documentView as? NSTextView, textView.string != text {
      textView.string = text
    }
  }
}
