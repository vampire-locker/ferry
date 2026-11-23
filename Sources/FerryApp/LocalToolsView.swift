import FerryCore
import SwiftUI

enum LocalTool: CaseIterable, Hashable, Identifiable {
  case dates, duplicates, archive, rename
  var id: Self { self }
  var title: String {
    switch self {
    case .dates: return L10n.text("图片/视频日期修复")
    case .duplicates: return L10n.text("重复图片整理")
    case .archive: return L10n.text("图片/视频归档")
    case .rename: return L10n.text("按拍摄时间重命名")
    }
  }
  var summary: String {
    switch self {
    case .dates: return L10n.text("修复图片和视频的创建日期，可选同步修改日期，保留原文件名。")
    case .duplicates: return L10n.text("找出内容相同的图片，选择保留项，将副本移到废纸篓。")
    case .archive: return L10n.text("按拍摄年月整理图片和视频，保留文件内容与日期。")
    case .rename: return L10n.text("优先按拍摄时间命名，缺失时从文件名补充，同时同步创建和修改日期。")
    }
  }
  var symbol: String {
    switch self {
    case .dates: return "calendar.badge.clock"
    case .duplicates: return "square.on.square"
    case .archive: return "folder.badge.gearshape"
    case .rename: return "square.and.pencil"
    }
  }
}

private enum LocalToolStatus {
  case available, scanning, repairing, cleaning, archiving, renaming, waitingConflict, stopping,
    ready,
    finished, stopped,
    issue
  var title: String {
    switch self {
    case .available: return L10n.text("打开工具")
    case .scanning: return L10n.text("正在扫描")
    case .repairing: return L10n.text("正在修复")
    case .cleaning: return L10n.text("正在清理")
    case .archiving: return L10n.text("正在归档")
    case .renaming: return L10n.text("正在重命名")
    case .waitingConflict: return L10n.text("等待处理同名文件")
    case .stopping: return L10n.text("正在停止…")
    case .ready: return L10n.text("扫描完成 · 查看结果")
    case .finished: return L10n.text("处理完成 · 查看结果")
    case .stopped: return L10n.text("已停止 · 查看详情")
    case .issue: return L10n.text("遇到问题 · 查看详情")
    }
  }
  var isRunning: Bool {
    switch self {
    case .scanning, .repairing, .cleaning, .archiving, .renaming, .waitingConflict, .stopping:
      return true
    default: return false
    }
  }
}

struct LocalToolsView: View {
  @Binding var selection: LocalTool?
  @ObservedObject var dates: PhotoDateRepairController
  @ObservedObject var duplicates: DuplicatePhotosController
  @ObservedObject var archive: LocalMediaArchiveController
  @ObservedObject var rename: LocalMediaArchiveController

  var body: some View {
    Group {
      if let selection {
        VStack(spacing: 0) {
          HStack(spacing: 16) {
            Button {
              self.selection = nil
            } label: {
              Label(L10n.text("返回本地工具"), systemImage: "chevron.left")
            }
            .buttonStyle(.plain).foregroundStyle(ferryAccent)
            Divider().frame(height: 16)
            Text(selection.title).font(.subheadline.weight(.medium))
            Spacer()
          }.padding(.horizontal, 24).padding(.vertical, 16)
          Divider()
          switch selection {
          case .dates: PhotoDateRepairView(controller: dates)
          case .duplicates: DuplicatePhotosView(controller: duplicates)
          case .archive: LocalMediaArchiveView(controller: archive)
          case .rename: LocalMediaArchiveView(controller: rename)
          }
        }
      } else {
        home
      }
    }.background(Color(nsColor: .windowBackgroundColor))
  }

  private var isBusy: Bool { dates.isBusy || duplicates.isBusy || archive.isBusy || rename.isBusy }

  private var home: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 8) {
          Text(L10n.text("选择工具")).font(.title2.weight(.semibold))
          Text(L10n.text("先预览，确认后再处理文件。无需连接手机。"))
            .font(.subheadline).foregroundStyle(.secondary)
        }
        if isBusy {
          Label(L10n.text("工具正在运行，点击对应卡片可返回查看进度。"), systemImage: "arrow.triangle.2.circlepath")
            .font(.caption).foregroundStyle(ferryAccent)
        }
        LazyVGrid(
          columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible())], spacing: 16
        ) {
          ForEach(LocalTool.allCases) { tool in
            let state = status(for: tool)
            LocalToolCard(tool: tool, status: state) { selection = tool }
              .disabled(isBusy && !state.isRunning)
          }
        }
      }.padding(24).frame(maxWidth: 960, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func status(for tool: LocalTool) -> LocalToolStatus {
    switch tool {
    case .dates:
      if !dates.isBusy && (dates.error != nil || (dates.result?.failed ?? 0) > 0) { return .issue }
      switch dates.phase {
      case .idle: return .available
      case .scanning: return .scanning
      case .applying: return .repairing
      case .stopping: return .stopping
      case .ready: return .ready
      case .scanCancelled: return .stopped
      case .finished: return dates.result?.cancelled == true ? .stopped : .finished
      }
    case .duplicates:
      if !duplicates.isBusy && (duplicates.error != nil || (duplicates.result?.failed ?? 0) > 0) {
        return .issue
      }
      switch duplicates.phase {
      case .idle: return .available
      case .scanning: return .scanning
      case .trashing: return .cleaning
      case .stopping: return .stopping
      case .ready: return .ready
      case .scanCancelled: return .stopped
      case .finished: return duplicates.result?.cancelled == true ? .stopped : .finished
      }
    case .archive, .rename:
      let archive = tool == .rename ? rename : archive
      if archive.conflict != nil { return .waitingConflict }
      if !archive.isBusy && (archive.error != nil || (archive.result?.failed ?? 0) > 0) {
        return .issue
      }
      switch archive.phase {
      case .idle: return .available
      case .scanning: return .scanning
      case .applying: return tool == .rename ? .renaming : .archiving
      case .stopping: return .stopping
      case .ready: return .ready
      case .scanCancelled: return .stopped
      case .finished: return archive.result?.cancelled == true ? .stopped : .finished
      }
    }
  }
}

private struct LocalToolCard: View {
  let tool: LocalTool
  let status: LocalToolStatus
  let open: () -> Void
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    Button(action: open) {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          Image(systemName: tool.symbol).font(.system(size: 22, weight: .medium))
            .foregroundStyle(ferryAccent).frame(width: 46, height: 46)
            .background(ferryAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
          Spacer()
          Image(systemName: "chevron.right").font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
        }
        VStack(alignment: .leading, spacing: 8) {
          Text(tool.title).font(.headline)
          Text(tool.summary).font(.subheadline).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true).frame(
              minHeight: 40, alignment: .topLeading)
        }
        Label(
          isEnabled ? status.title : L10n.text("等待当前工具结束"),
          systemImage: status.isRunning ? "circle.inset.filled" : "arrow.right"
        )
        .font(.caption.weight(.medium))
        .foregroundStyle(status.isRunning ? ferryAccent : .secondary)
      }
      .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading).padding(20)
      .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
      .overlay {
        RoundedRectangle(cornerRadius: 16)
          .strokeBorder(status.isRunning ? ferryAccent.opacity(0.45) : Color.primary.opacity(0.08))
      }
      .contentShape(RoundedRectangle(cornerRadius: 16))
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(tool.title)
    .accessibilityValue(isEnabled ? status.title : L10n.text("等待当前工具结束"))
    .accessibilityHint(tool.summary)
  }
}
