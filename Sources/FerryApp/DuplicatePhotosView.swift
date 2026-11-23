import AppKit
import FerryCore
import SwiftUI

struct DuplicatePhotosView: View {
  @ObservedObject var controller: DuplicatePhotosController
  @State private var confirming = false

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 18) {
        Label(L10n.text("重复图片整理"), systemImage: "photo.on.rectangle.angled").font(
          .title2.weight(.semibold))
        Text(L10n.text("按完整文件 SHA-256 查找完全相同的图片，文件名和日期可以不同。画面相似但压缩或 EXIF 不同的图片不算重复。"))
          .foregroundStyle(.secondary)
        GroupBox {
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              Text(controller.folder?.path ?? L10n.text("尚未选择文件夹"))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
              Spacer()
              Button(L10n.text("选择文件夹…")) { chooseFolder(preferred: false) }
            }
            Toggle(
              L10n.text("包含子文件夹"),
              isOn: Binding(get: { controller.recursive }, set: controller.setRecursive))
          }.padding(8).disabled(controller.isBusy)
        }
        HStack {
          Button(L10n.text("扫描重复图片")) { controller.scan() }.disabled(
            controller.folder == nil || controller.isBusy)
          Button(L10n.text("将 \(controller.selectedCopies) 份副本移到废纸篓"), role: .destructive) {
            confirming = true
          }
          .disabled(!controller.canClean)
        }
        if controller.isBusy {
          VStack(alignment: .leading, spacing: 8) {
            Text(
              controller.phase == .stopping
                ? L10n.text("正在停止…")
                : controller.progress.stage == .trashing
                  ? L10n.text(
                    "正在移到废纸篓 \(controller.progress.processed) / \(controller.progress.total)")
                  : controller.progress.stage == .hashing
                    ? L10n.text(
                      "正在核验完整内容 \(controller.progress.processed) / \(controller.progress.total)")
                    : L10n.text("正在扫描，已发现 \(controller.progress.processed) 张图片…"))
            if controller.progress.total > 0 {
              ProgressView(
                value: Double(controller.progress.processed),
                total: Double(controller.progress.total))
            } else {
              ProgressView().controlSize(.small)
            }
            HStack {
              Text(controller.progress.currentPath).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
              Spacer()
              Button(L10n.text("停止")) { controller.cancel() }.disabled(
                controller.phase == .stopping)
            }
          }
        }
        if let error = controller.error {
          Text(error).foregroundStyle(.orange).textSelection(.enabled)
        }
        if controller.phase == .scanCancelled {
          Text(L10n.text("扫描已停止，未移动任何文件。")).foregroundStyle(.secondary)
        }
        if let plan = controller.plan {
          VStack(alignment: .leading, spacing: 7) {
            Text(
              L10n.text(
                "已检查 \(plan.summary.images) 张 · \(plan.groups.count) 组重复 · \(plan.summary.duplicateCopies) 份副本"
              )
            )
            .font(.headline)
            Text(
              L10n.text(
                "重复副本总大小 \(Display.bytes(plan.summary.duplicateBytes)) · 跳过 \(plan.summary.skipped) · 读取失败 \(plan.summary.failed)"
              )
            )
            .font(.caption).foregroundStyle(.secondary)
            if plan.groups.isEmpty { Text(L10n.text("没有找到完全相同的图片。")).foregroundStyle(.secondary) }
          }
          if !plan.groups.isEmpty {
            HStack {
              Button(L10n.text("全选重复组")) { controller.selectAll(true) }
              Button(L10n.text("取消选择")) { controller.selectAll(false) }
              Button(L10n.text("优先保留指定文件夹…")) { chooseFolder(preferred: true) }
            }.disabled(controller.phase != .ready)
            if let folder = controller.preferredFolder {
              Text(L10n.text("优先保留：\(folder.path)")).font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            Text(
              L10n.text(
                "已选 \(controller.selectedGroups.count) 组，将移动 \(controller.selectedCopies) 份副本（\(Display.bytes(controller.selectedBytes))）。每组保留一份，不按日期判断原件。"
              )
            )
            .font(.caption)
            if controller.phase == .finished {
              Text(L10n.text("处理后请重新扫描；下方为上次扫描结果。")).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(plan.groups) { group in
              DuplicateGroupView(
                group: group, plan: plan, selected: controller.selectedGroups.contains(group.id),
                keepID: controller.keepers[group.id] ?? group.photos[0].id,
                editable: controller.phase == .ready,
                select: { controller.selectGroup(group.id, selected: $0) },
                keep: { controller.keep($0, in: group.id) })
            }
          }
        }
        if let result = controller.result {
          GroupBox(result.cancelled ? L10n.text("清理已停止") : L10n.text("处理完成")) {
            VStack(alignment: .leading, spacing: 8) {
              Text(
                L10n.text(
                  "已移到废纸篓 \(result.moved) 份 · 保留项异常跳过 \(result.skipped) 份 · 失败 \(result.failed) 份"))
              if !result.issues.isEmpty {
                Text(L10n.text("问题明细（最多 50 条）")).font(.caption.weight(.medium))
              }
              ForEach(result.issues) { issue in
                Text("\(issue.path) · \(issue.message)").font(.caption).foregroundStyle(.secondary)
                  .textSelection(.enabled)
              }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
          }
        }
        Text(
          L10n.text(
            "扫描不会修改图片。跳过隐藏文件、链接和照片资料库；移入废纸篓前重新核验副本和保留项。废纸篓不可用时报告失败，绝不永久删除。停止只终止剩余操作，已移动的副本可从废纸篓找回。显示的是文件大小，不保证实际释放空间。"
          )
        )
        .font(.caption).foregroundStyle(.secondary)
      }.padding(24).frame(maxWidth: 1040, alignment: .leading).frame(
        maxWidth: .infinity, alignment: .leading)
    }.background(Color(nsColor: .windowBackgroundColor))
      .alert(L10n.text("将选中的副本移到废纸篓？"), isPresented: $confirming) {
        Button(L10n.text("取消"), role: .cancel) {}
        Button(L10n.text("移到废纸篓"), role: .destructive) { controller.clean() }
      } message: {
        Text(L10n.text("将移动 \(controller.selectedCopies) 份副本，每组保留选定的一份。不会永久删除文件；可在 Finder 废纸篓中找回。"))
      }
  }

  private func chooseFolder(preferred: Bool) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.resolvesAliases = true
    panel.directoryURL = controller.folder
    if panel.runModal() == .OK, let url = panel.url {
      if preferred { controller.preferFolder(url) } else { controller.selectFolder(url) }
    }
  }
}

private struct DuplicateGroupView: View {
  let group: DuplicatePhotoGroup
  let plan: DuplicatePhotoPlan
  let selected: Bool
  let keepID: String
  let editable: Bool
  let select: (Bool) -> Void
  let keep: (String) -> Void
  @State private var expanded = false

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 12) {
        Toggle(
          L10n.text("清理本组：\(group.photos.count) 份相同图片，每份 \(Display.bytes(group.photos[0].size))"),
          isOn: Binding(get: { selected }, set: select)
        ).disabled(!editable)
        HStack(alignment: .top, spacing: 14) {
          DuplicateThumbnail(item: group.photos[0], plan: plan, digest: group.hash)
          VStack(alignment: .leading, spacing: 7) {
            Text(L10n.text("保留：\(plan.folder.appendingPathComponent(keepID).path)"))
              .font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup(L10n.text("查看 \(group.photos.count) 份文件并选择保留项"), isExpanded: $expanded)
            {
              LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(group.photos) { photo in
                  Button {
                    keep(photo.id)
                  } label: {
                    HStack(alignment: .top, spacing: 8) {
                      Image(systemName: keepID == photo.id ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(keepID == photo.id ? ferryAccent : .secondary)
                      VStack(alignment: .leading, spacing: 4) {
                        Text(plan.folder.appendingPathComponent(photo.relativePath).path)
                          .textSelection(.enabled)
                        Text(
                          L10n.text(
                            "修改：\(date(photo.modified)) · 创建：\(photo.created.map(date) ?? "—")")
                        )
                        .foregroundStyle(.secondary)
                      }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    }.contentShape(Rectangle())
                  }.buttonStyle(.plain).disabled(!editable)
                }
              }.padding(.top, 8)
            }.font(.caption)
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
      }.padding(8)
    }
  }
  private func date(_ value: Date) -> String {
    value.formatted(.dateTime.year().month().day().hour().minute().locale(L10n.locale))
  }
}

private struct DuplicateThumbnail: View {
  let item: DuplicatePhoto
  let plan: DuplicatePhotoPlan
  let digest: String
  @State private var image: CGImage?
  private final class CachedImage {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
  }
  private static let cache: NSCache<NSString, CachedImage> = {
    let cache = NSCache<NSString, CachedImage>()
    cache.countLimit = 80
    cache.totalCostLimit = 16 << 20
    return cache
  }()
  var body: some View {
    Group {
      if let image {
        Image(decorative: image, scale: 1).resizable().scaledToFit()
      } else {
        Image(systemName: "photo").font(.title).foregroundStyle(.secondary)
      }
    }.frame(width: 72, height: 72).background(
      Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8)
    )
    .accessibilityLabel(L10n.text("重复组缩略图"))
    .task(id: digest) {
      if let cached = Self.cache.object(forKey: digest as NSString) {
        image = cached.image
        return
      }
      let cancellation = PhotoRepairCancellation()
      let result = await withTaskCancellationHandler {
        await Task.detached(priority: .utility) {
          DuplicatePhotos.thumbnail(item, plan: plan, cancellation: cancellation)
        }.value
      } onCancel: {
        cancellation.cancel()
      }
      guard !Task.isCancelled, let result else { return }
      Self.cache.setObject(
        CachedImage(result), forKey: digest as NSString, cost: result.bytesPerRow * result.height)
      image = result
    }
  }
}
