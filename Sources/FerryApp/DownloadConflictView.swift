import FerryCore
import SwiftUI

struct DownloadConflictPresentation: ViewModifier {
  let controller: DownloadQueueController
  @ObservedObject private var state: DownloadConflictState
  init(controller: DownloadQueueController) {
    self.controller = controller
    self.state = controller.conflicts
  }
  func body(content: Content) -> some View {
    content.sheet(item: Binding(get: { state.prompt }, set: { _ in })) { value in
      DownloadConflictView(conflict: value.conflict) { decision in
        controller.resolve(value.taskID, decision: decision)
      } stop: {
        controller.cancel(value.taskID)
      }
      .id(value.id)
      .interactiveDismissDisabled()
    }
  }
}

struct DownloadConflictView: View {
  enum Context {
    case download
    case localArchive(sourcePath: String, targetChanged: Bool)
    case localRename(sourcePath: String, targetChanged: Bool, blockedReason: String?)
    var details: (source: String, changed: Bool, blocked: String?)? {
      switch self {
      case .download: return nil
      case .localArchive(let source, let changed): return (source, changed, nil)
      case .localRename(let source, let changed, let blocked): return (source, changed, blocked)
      }
    }
  }
  let context: Context
  let conflict: DownloadConflict
  let resolve: (DownloadConflictDecision) -> Void
  let stop: () -> Void
  @State private var applyToAll = false
  @State private var directory = ""
  private var isDirectory: Bool { conflict.kind == "monthDirectory" }
  private var isRenaming: Bool {
    if case .localRename = context { return true }
    return false
  }
  private var isArchive: Bool {
    if case .localArchive = context { return true }
    return false
  }

  init(
    conflict: DownloadConflict, context: Context = .download,
    resolve: @escaping (DownloadConflictDecision) -> Void,
    stop: @escaping () -> Void
  ) {
    self.conflict = conflict
    self.context = context
    self.resolve = resolve
    self.stop = stop
    _directory = State(initialValue: conflict.candidates?.first ?? "")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Label(
        isDirectory ? L10n.text("选择月份文件夹") : L10n.text("目标位置已有同名项目"),
        systemImage: isDirectory ? "folder" : "doc.on.doc"
      )
      .font(.headline)
      Text(conflict.name).font(.subheadline.weight(.medium)).lineLimit(2).textSelection(.enabled)
      Text(conflict.targetPath).font(.caption).foregroundStyle(.secondary)
        .lineLimit(3).textSelection(.enabled)
      if let details = context.details {
        Text(
          isRenaming ? L10n.text("待重命名文件：\(details.source)") : L10n.text("待归档文件：\(details.source)")
        ).font(.caption).foregroundStyle(.secondary)
          .lineLimit(3).textSelection(.enabled)
        if details.changed {
          Text(L10n.text("目标项目在处理期间发生变化，请重新选择同名处理方式。"))
            .font(.caption).foregroundStyle(.orange)
        }
        Text(
          isRenaming
            ? L10n.text("保留两者会自动编号；跳过不改名或日期；替换会覆盖目标文件，再同步日期。")
            : L10n.text("保留两者会自动编号；跳过会将源文件保留原位；替换会覆盖目标文件。")
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      if isDirectory {
        Text(L10n.text("发现多个代表同一月份的文件夹，请选择本次任务要使用的目录。"))
          .font(.subheadline)
        Picker(L10n.text("保存到"), selection: $directory) {
          ForEach(conflict.candidates ?? [], id: \.self) { path in
            Text(path).tag(path)
          }
        }
        Text(L10n.text("本次任务中该月份的后续图片会继续使用所选目录，不会合并其他文件夹。"))
          .font(.caption).foregroundStyle(.secondary)
      } else {
        HStack(alignment: .top, spacing: 32) {
          metadata(
            title: L10n.text("已有项目"), size: conflict.existingSize,
            modified: conflict.existingModified)
          metadata(
            title: isRenaming
              ? L10n.text("待重命名文件") : isArchive ? L10n.text("待归档文件") : L10n.text("正在导出的文件"),
            size: conflict.incomingSize,
            modified: conflict.incomingModified)
        }
        if !conflict.canReplace {
          Text(context.details?.blocked ?? L10n.text("目标是文件夹、链接或其他非普通文件，不能替换。"))
            .font(.caption).foregroundStyle(.secondary)
        }
        Toggle(
          isRenaming
            ? L10n.text("应用到本次重命名的所有同名文件")
            : isArchive ? L10n.text("应用到本次归档的所有同名文件") : L10n.text("应用到本次任务的所有同名文件"),
          isOn: $applyToAll
        )
        .toggleStyle(.checkbox)
      }
      HStack {
        Button(
          isRenaming ? L10n.text("停止重命名") : isArchive ? L10n.text("停止归档") : L10n.text("停止任务"),
          action: stop
        ).keyboardShortcut(
          .cancelAction)
        Spacer(minLength: 20)
        if isDirectory {
          Button(L10n.text("使用此文件夹")) {
            resolve(
              DownloadConflictDecision(id: conflict.id, choice: "directory", directory: directory))
          }
          .disabled(directory.isEmpty).keyboardShortcut(.defaultAction)
        } else {
          Button(L10n.text("保留两者")) { choose("keepBoth") }.keyboardShortcut(.defaultAction)
          Button(L10n.text("跳过")) { choose("skip") }
          Button(L10n.text("替换"), role: .destructive) { choose("replace") }.disabled(
            !conflict.canReplace
          )
          .tint(.red)
        }
      }
    }
    .padding(24).frame(width: 570)
  }

  private func choose(_ choice: String) {
    resolve(DownloadConflictDecision(id: conflict.id, choice: choice, applyToAll: applyToAll))
  }

  private func metadata(title: String, size: Int64, modified: Int64) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.subheadline.weight(.medium))
      Text(Display.bytes(size)).font(.caption)
      Text(L10n.text("修改日期")).font(.caption).foregroundStyle(.secondary)
      if modified > 0 {
        Text(
          Date(timeIntervalSince1970: Double(modified)),
          format: .dateTime.year().month().day().hour().minute()
        )
        .font(.caption)
      } else {
        Text(L10n.text("日期未知")).font(.caption)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
