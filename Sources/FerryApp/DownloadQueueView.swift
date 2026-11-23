import AppKit
import FerryCore
import SwiftUI

struct DownloadQueueView: View {
  let controller: DownloadQueueController
  @ObservedObject private var presentation: DownloadQueuePresentation
  @State private var reportTask: DownloadTask?

  init(controller: DownloadQueueController) {
    self.controller = controller
    self.presentation = controller.presentation
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        Text(L10n.text("共 \(presentation.rows.count) 个任务"))
          .font(.subheadline).foregroundStyle(.secondary)
        Spacer(minLength: 0)
        if presentation.hasPaused {
          Button(L10n.text("继续队列")) { controller.resume() }
        }
        if presentation.hasFinished {
          Button(L10n.text("清理已结束")) {
            controller.dismissFinished()
          }
          .help(L10n.text("仅移除列表中的已结束任务，不会删除已下载文件。"))
        }
      }
      .padding(.horizontal, 24).padding(.vertical, 14)
      Divider()
      if let error = presentation.recoveryError {
        Text(error).font(.caption).foregroundStyle(.orange).padding(16)
      }
      if presentation.rows.isEmpty {
        ContentUnavailableView(
          L10n.text("暂无下载任务"), systemImage: "arrow.down.circle",
          description: Text(L10n.text("在“手机文件”页面选择文件，添加到下载队列。"))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        taskList
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .sheet(item: $reportTask) { task in
      VStack(spacing: 0) {
        HStack {
          Text(L10n.text("传输报告")).font(.headline)
          Spacer()
          Button(L10n.text("关闭")) { reportTask = nil }.keyboardShortcut(.cancelAction)
        }.padding(16)
        Divider()
        if let url = task.reportURL { FileTextPreview(url: url) }
      }
      .frame(minWidth: 640, idealWidth: 800, minHeight: 420, idealHeight: 560)
    }
  }

  private var taskList: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 16) {
        ForEach(presentation.rows) { row in
          DownloadTaskRowView(row: row, controller: controller) { reportTask = $0 }
        }
      }
      .padding(24)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
  }

}

struct DownloadTaskClockSchedule: TimelineSchedule, Equatable {
  let origin: Date
  let isActive: Bool

  func entries(from startDate: Date, mode: Mode) -> AnySequence<Date> {
    if isActive {
      return AnySequence(
        PeriodicTimelineSchedule(from: origin, by: 1).entries(from: startDate, mode: mode))
    }
    return AnySequence(ExplicitTimelineSchedule([origin]).entries(from: startDate, mode: mode))
  }
}

struct DownloadTaskRowView: View {
  @ObservedObject var row: DownloadTaskRowModel
  let controller: DownloadQueueController
  let showReport: (DownloadTask) -> Void
  @State private var clockOrigin = Date()
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    TimelineView(
      DownloadTaskClockSchedule(
        origin: clockOrigin, isActive: row.task.state == .running || row.task.state == .cancelling)
    ) { _ in
      card(row.task)
    }
  }

  private func card(_ task: DownloadTask) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(task.title).font(.subheadline.weight(.semibold))
          .lineLimit(1).truncationMode(.middle).help(task.title)
        Spacer(minLength: 6)
        Label(stateTitle(task.state), systemImage: stateSymbol(task.state))
          .font(.caption.weight(.medium)).foregroundStyle(stateColor(task.state))
          .padding(.horizontal, 9).padding(.vertical, 4)
          .background(stateColor(task.state).opacity(0.1), in: Capsule())
          .fixedSize()
      }
      if !task.filterSummary.isEmpty {
        Text(task.filterSummary)
          .font(.caption).foregroundStyle(.secondary)
          .lineLimit(2).textSelection(.enabled).help(task.filterSummary)
      }
      if task.totalBytes > 0 || task.state == .running || task.state == .cancelling {
        SailingProgressView(
          transferred: task.transferred, total: task.totalBytes, state: task.state
        )
        // The native drawing reserves room for the boat beyond both ends.
        // Extend into the card padding so the waterline aligns with the text.
        .padding(.horizontal, -SailingProgressLayers.horizontalInset)
      }
      if task.total > 0 || task.totalBytes > 0 || controller.elapsed(for: task) != nil {
        statistics(task)
      }
      if let error = task.error {
        Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2).textSelection(.enabled)
      }
      if task.skipped > 0 {
        Text(L10n.text("已跳过 \(task.skipped) 个同名文件")).font(.caption).foregroundStyle(.secondary)
      }
      if task.state == .waiting {
        Text(L10n.text("请在弹窗中选择同名文件或月份目录的处理方式。"))
          .font(.caption).foregroundStyle(.secondary)
      }
      if task.state == .cancelling {
        Text(L10n.text("正在结束当前文件或设备操作，随后停止剩余任务。已完成文件会保留；大文件可能需要等待较长时间。"))
          .font(.caption).foregroundStyle(.secondary)
      }
      Divider()
      HStack(alignment: .center, spacing: 12) {
        Text(task.currentFile.isEmpty ? "—" : task.currentFile)
          .font(.caption).foregroundStyle(.secondary)
          .lineLimit(1).truncationMode(.middle).help(task.currentFile)
        Spacer(minLength: 0)
        if !task.state.isTerminal {
          Button(task.state == .cancelling ? L10n.text("停止中…") : L10n.text("取消任务")) {
            controller.cancel(task.id)
          }
          .disabled(task.state == .cancelling)
        } else {
          if task.resumeAvailable {
            Button(L10n.text("继续未完成")) { controller.continueTask(task.id) }
              .controlSize(.small)
              .fixedSize(horizontal: true, vertical: false)
              .help(L10n.text("连接原手机后继续，先核验已完成文件，再下载剩余内容。"))
            Button(L10n.text("移除任务")) { controller.removeTask(task.id) }
              .controlSize(.small)
              .fixedSize(horizontal: true, vertical: false)
              .help(L10n.text("仅移除列表中的已结束任务，不会删除已下载文件。"))
          }
          if let output = task.output {
            if task.reportURL != nil {
              Button(L10n.text("查看报告")) { showReport(task) }.controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
            }
            Button(L10n.text("打开文件夹")) { NSWorkspace.shared.open(output) }
              .controlSize(.small)
              .fixedSize(horizontal: true, vertical: false)
          }
        }
      }
      .buttonStyle(.bordered).controlSize(.small)
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    .overlay {
      RoundedRectangle(cornerRadius: 14)
        .strokeBorder(
          task.state == .running
            ? Color.accentColor.opacity(0.45)
            : Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.12),
          lineWidth: 1
        )
        .allowsHitTesting(false)
    }
  }

  private func statistics(_ task: DownloadTask) -> some View {
    HStack(alignment: .top, spacing: 16) {
      metric(L10n.text("文件数量"), value: task.total > 0 ? "\(task.completed) / \(task.total)" : "—")
      metric(
        L10n.text("传输量"),
        value: task.totalBytes > 0
          ? "\(Display.bytes(task.transferred)) / \(Display.bytes(task.totalBytes))" : "—")
      metric(
        L10n.text("已用时长"),
        value: controller.elapsed(for: task).map(Display.duration) ?? "—")
      if task.state.isTerminal {
        metric(
          L10n.text("平均速度"),
          value: controller.averageSpeed(for: task).map(Display.bytesPerSecond) ?? "—"
        )
        .help(
          task.continuing
            ? L10n.text("继续任务后，用时重新计算，平均速度仅计本次新增传输量，不计已核验复用的字节。")
            : L10n.text("已传输字节除以任务总用时，包含准备、等待和收尾时间；不代表目标磁盘的净写入速度。"))
      } else {
        metric(L10n.text("预计剩余"), value: remainingTitle(task))
      }
    }
  }

  private func metric(_ title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(value).font(.subheadline.weight(.medium)).monospacedDigit()
        .lineLimit(1).minimumScaleFactor(0.8).help(value)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  private func remainingTitle(_ task: DownloadTask) -> String {
    guard task.state == .running else { return "—" }
    if task.timing.hasTransferredAllBytes { return L10n.text("正在收尾…") }
    return controller.remaining(for: task).map(Display.duration) ?? L10n.text("估算中…")
  }
}

private func stateTitle(_ state: DownloadTaskState) -> String {
  switch state {
  case .queued: return L10n.text("等待下载")
  case .running: return L10n.text("正在下载")
  case .waiting: return L10n.text("等待选择")
  case .cancelling: return L10n.text("停止中…")
  case .completed: return L10n.text("已安全到达")
  case .cancelled: return L10n.text("下载已停止")
  case .failed: return L10n.text("下载未完成")
  case .paused: return L10n.text("等待继续")
  case .interrupted: return L10n.text("等待恢复")
  }
}

private func stateSymbol(_ state: DownloadTaskState) -> String {
  switch state {
  case .queued: return "clock"
  case .running: return "arrow.down.circle"
  case .waiting: return "questionmark.circle"
  case .cancelling: return "hourglass"
  case .completed: return "checkmark.circle.fill"
  case .cancelled: return "stop.circle"
  case .failed: return "exclamationmark.circle"
  case .paused: return "pause.circle"
  case .interrupted: return "arrow.clockwise.circle"
  }
}

private func stateColor(_ state: DownloadTaskState) -> Color {
  switch state {
  case .completed: return .accentColor
  case .failed: return .orange
  default: return .secondary
  }
}

struct DownloadStatusBar: View {
  static let height: CGFloat = 36
  let controller: DownloadQueueController
  @ObservedObject private var presentation: DownloadQueuePresentation
  let showDownloads: () -> Void

  init(controller: DownloadQueueController, showDownloads: @escaping () -> Void) {
    self.controller = controller
    self.presentation = controller.presentation
    self.showDownloads = showDownloads
  }

  var body: some View {
    Button(action: showDownloads) {
      HStack(spacing: 10) {
        if let row = presentation.focusedRow {
          FocusedDownloadStatus(row: row)
        } else {
          Spacer(minLength: 0)
        }
        Text(
          presentation.pendingTaskCount > 0
            ? L10n.text("\(presentation.pendingTaskCount) 项任务待完成") : L10n.text("查看下载任务")
        )
        .foregroundStyle(.secondary).fixedSize()
        Image(systemName: "chevron.right").foregroundStyle(.secondary)
      }
      .font(.caption).monospacedDigit()
      .padding(.horizontal, 20)
      .frame(height: Self.height)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(L10n.text("查看下载任务"))
  }
}

private struct FocusedDownloadStatus: View {
  @ObservedObject var row: DownloadTaskRowModel
  var body: some View {
    Label(stateTitle(row.task.state), systemImage: stateSymbol(row.task.state))
      .foregroundStyle(stateColor(row.task.state)).fixedSize()
    Text(row.task.title).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
    Spacer(minLength: 8)
    if row.task.state == .running && row.task.totalBytes > 0 {
      ProgressView(value: Display.progress(bytes: row.task.transferred, total: row.task.totalBytes))
        .frame(width: 100)
    }
  }
}
