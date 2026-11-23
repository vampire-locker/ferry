import AppKit
import FerryCore
import SwiftUI

private struct ThumbnailFrameKey: Hashable {
  let entry: RemoteEntry
  let storageID: UInt32
  let parentID: UInt32
  let query: String
  let showHiddenFiles: Bool
  let yearFilter: DirectoryYearFilter
  let monthFilter: DirectoryMonthFilter
  let mediaFilter: DirectoryMediaFilter
}

private struct ThumbnailFrames: PreferenceKey {
  static var defaultValue: [ThumbnailFrameKey: CGRect] { [:] }
  static func reduce(
    value: inout [ThumbnailFrameKey: CGRect], nextValue: () -> [ThumbnailFrameKey: CGRect]
  ) {
    value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
  }
}

struct PreviewGrid: View {
  @ObservedObject var model: AppModel
  @ObservedObject var media: MediaController
  @FocusState private var gridFocused: Bool
  @State private var frames: [ThumbnailFrameKey: CGRect] = [:]

  var body: some View {
    VStack(spacing: 0) {
      if let error = media.thumbnailError {
        HStack {
          Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
          Text(L10n.text("缩略图读取中断：\(error)")).font(.caption).lineLimit(2)
          Spacer()
          Button(L10n.text("重试")) { media.retryThumbnails() }
            .disabled(model.previewActionsBlocked)
        }
        .padding(10)
      }
      GeometryReader { viewport in
        ScrollView {
          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 14)], spacing: 16
          ) {
            ForEach(model.visibleEntries) { entry in
              PreviewCell(
                model: model, media: media, entry: entry,
                frameKey: ThumbnailFrameKey(
                  entry: entry, storageID: model.storageID, parentID: model.folders.last?.id ?? 0,
                  query: model.query, showHiddenFiles: model.showHiddenFiles,
                  yearFilter: model.yearFilter, monthFilter: model.monthFilter,
                  mediaFilter: model.mediaFilter)
              ) { gridFocused = true }
            }
          }
          .padding(18)
        }
        .coordinateSpace(name: "thumbnailViewport")
        .onPreferenceChange(ThumbnailFrames.self) { value in
          frames = value
          updateDemand(in: viewport.size)
        }
        .onChange(of: media.requestVersion) { _, _ in updateDemand(in: viewport.size) }
        .onChange(of: viewport.size) { _, _ in updateDemand(in: viewport.size) }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .focusable().focused($gridFocused).focusEffectDisabled()
    .onDisappear { media.setThumbnailDemand([]) }
  }

  private func updateDemand(in size: CGSize) {
    guard !model.previewActionsBlocked, model.viewMode == .preview else {
      media.setThumbnailDemand([])
      return
    }
    let viewport = CGRect(origin: .zero, size: size).insetBy(dx: 0, dy: -48)
    let entries = frames.compactMap { key, frame -> RemoteEntry? in
      guard key.storageID == model.storageID, key.parentID == (model.folders.last?.id ?? 0),
        key.query == model.query, key.showHiddenFiles == model.showHiddenFiles,
        key.yearFilter == model.yearFilter,
        key.monthFilter == model.monthFilter,
        key.mediaFilter == model.mediaFilter,
        model.isEntryVisible(key.entry),
        frame.width > 0, frame.height > 0, frame.intersects(viewport)
      else { return nil }
      return key.entry
    }
    media.setThumbnailDemand(entries)
  }
}

private struct PreviewCell: View {
  @ObservedObject var model: AppModel
  @ObservedObject var media: MediaController
  let entry: RemoteEntry
  let frameKey: ThumbnailFrameKey
  let focus: () -> Void

  var body: some View {
    VStack(spacing: 8) {
      ZStack(alignment: .bottomTrailing) {
        RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor))
        if let image = media.thumbnail(for: entry) {
          Image(nsImage: image).resizable().scaledToFit().padding(4)
        } else {
          VStack(spacing: 8) {
            Image(systemName: entry.symbol).font(.system(size: 46, weight: .light))
              .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
            if let issue = media.thumbnailIssue(for: entry) {
              Button(L10n.text("重试缩略图")) { media.retryThumbnails(entry) }
                .buttonStyle(.borderless).font(.caption).help(issue)
                .disabled(model.previewActionsBlocked)
            } else if media.isLoadingThumbnail(entry) {
              ProgressView().controlSize(.small)
            }
          }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        if entry.isVideo {
          Image(systemName: "play.circle.fill").font(.title2)
            .foregroundStyle(.white, .black.opacity(0.65)).padding(8)
        }
      }
      .frame(height: 112)
      HStack(alignment: .top, spacing: 5) {
        Toggle(
          L10n.text("选择 \(entry.name)"),
          isOn: Binding(
            get: { model.selection.contains(entry.id) },
            set: {
              focus()
              model.setSelected(entry.id, selected: $0)
            }
          )
        ).toggleStyle(.checkbox).labelsHidden()
        Text(entry.name).font(.callout).lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      Text(entry.isDirectory ? L10n.text("文件夹") : entry.sizeDescription)
        .font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(8)
    .background(
      model.selection.contains(entry.id) ? Color.accentColor.opacity(0.14) : .clear,
      in: RoundedRectangle(cornerRadius: 10)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 10)
        .stroke(model.selection.contains(entry.id) ? Color.accentColor : .clear, lineWidth: 1.5)
    }
    .contentShape(Rectangle())
    .background {
      if entry.isThumbnailEligible {
        GeometryReader { geometry in
          Color.clear.preference(
            key: ThumbnailFrames.self,
            value: [frameKey: geometry.frame(in: .named("thumbnailViewport"))])
        }
      }
    }
    .onTapGesture(count: 2) {
      focus()
      model.selection = [entry.id]
      if entry.isDirectory { model.open(entry) } else { model.previewSelection() }
    }
    .onTapGesture {
      focus()
      model.selectGridEntry(
        entry, extending: NSEvent.modifierFlags.contains(.shift),
        toggling: NSEvent.modifierFlags.contains(.command))
    }
    .contextMenu {
      if entry.isDirectory { Button(L10n.text("打开文件夹")) { model.open(entry) } }
      if entry.isThumbnailEligible {
        Button(L10n.text("重新加载缩略图")) { media.retryThumbnails(entry) }
          .disabled(model.previewActionsBlocked)
      }
      if !entry.isDirectory {
        Button(L10n.text("预览")) {
          model.selection = [entry.id]
          model.previewSelection()
        }.disabled(model.previewActionsBlocked)
      }
      Button(model.downloadQueue.hasPendingTasks ? L10n.text("加入下载队列") : L10n.text("下载所选项目")) {
        if !model.selection.contains(entry.id) { model.selection = [entry.id] }
        model.download()
      }
    }
    .help(!entry.isDirectory ? L10n.text("\(entry.name) · 空格预览") : entry.name)
  }
}
