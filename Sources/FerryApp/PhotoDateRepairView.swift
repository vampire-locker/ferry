import AppKit
import FerryCore
import SwiftUI

struct PhotoDateRepairView: View {
  @ObservedObject var controller: PhotoDateRepairController

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Label(L10n.text("图片/视频日期修复"), systemImage: "calendar")
          .font(.title2.weight(.semibold))
        Text(L10n.text("选择图片和视频所在的文件夹，先预览，再修复创建日期；可选同时修复修改日期。保留原文件名和格式，无需连接手机。"))
          .foregroundStyle(.secondary)
        GroupBox {
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("文件夹")).font(.headline)
                Text(controller.folder?.path ?? L10n.text("尚未选择文件夹"))
                  .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                  .textSelection(.enabled)
              }
              Spacer()
              Button(L10n.text("选择文件夹…"), action: chooseFolder).disabled(controller.isBusy)
            }
            HStack(spacing: 24) {
              Toggle(
                L10n.text("图片"),
                isOn: Binding(
                  get: { controller.images }, set: { controller.setOptions(images: $0) }))
              Toggle(
                L10n.text("视频"),
                isOn: Binding(
                  get: { controller.videos }, set: { controller.setOptions(videos: $0) }))
            }
            Toggle(
              L10n.text("包含子文件夹"),
              isOn: Binding(
                get: { controller.recursive }, set: { controller.setOptions(recursive: $0) }))
            Toggle(
              L10n.text("同时修复修改日期"),
              isOn: Binding(
                get: { controller.repairModificationDate },
                set: { controller.setOptions(repairModificationDate: $0) }))
            Toggle(
              L10n.text("没有拍摄元数据时，从文件名识别日期"),
              isOn: Binding(
                get: { controller.allowFilename }, set: { controller.setOptions(allowFilename: $0) }
              ))
            Toggle(
              L10n.text("允许仅恢复年月日（时间设为 00:00）"),
              isOn: Binding(
                get: { controller.allowDateOnly }, set: { controller.setOptions(allowDateOnly: $0) }
              )
            )
            .disabled(!controller.allowFilename)
            Text(
              L10n.text(
                "图片优先使用 EXIF，视频优先使用内嵌拍摄或创建时间；文件名日期仅作推测，请核对预览。20130607_190722、VID_20250704_005959 表示完整时间，20121209_015 仅恢复日期，015 不作为时间。"
              )
            )
            .font(.caption).foregroundStyle(.secondary)
          }.padding(8).disabled(controller.isBusy)
        }
        HStack(spacing: 12) {
          Button(L10n.text("扫描图片/视频")) { controller.scan() }
            .disabled(
              controller.folder == nil || controller.isBusy
                || (!controller.images && !controller.videos))
          Button(L10n.text("修复 \(controller.plan?.items.count ?? 0) 个文件")) { controller.apply() }
            .buttonStyle(.borderedProminent).disabled(!controller.canApply)
          if controller.isBusy {
            Button(L10n.text("停止")) { controller.cancel() }.disabled(controller.phase == .stopping)
          }
        }
        if controller.isBusy {
          VStack(alignment: .leading, spacing: 8) {
            Text(
              controller.phase == .stopping
                ? L10n.text("正在停止…")
                : controller.isScanning
                  ? L10n.text("正在扫描，已检查 \(controller.progress.processed) 个媒体文件…")
                  : L10n.text(
                    "正在修复 \(controller.progress.processed) / \(controller.progress.total)"))
            if controller.progress.total > 0 && !controller.isScanning {
              ProgressView(
                value: Double(controller.progress.processed),
                total: Double(controller.progress.total))
            } else {
              ProgressView().controlSize(.small)
            }
            Text(controller.progress.currentPath).font(.caption).foregroundStyle(.secondary)
              .lineLimit(1).truncationMode(.middle)
          }
        }
        if let error = controller.error {
          Text(error).foregroundStyle(.orange).textSelection(.enabled)
        }
        if controller.phase == .scanCancelled {
          Text(L10n.text("扫描已停止，未修改文件。")).foregroundStyle(.secondary)
        }
        if let plan = controller.plan {
          VStack(alignment: .leading, spacing: 8) {
            Text(
              L10n.text(
                "已检查 \(plan.summary.mediaCount) 个（图片 \(plan.summary.images)、视频 \(plan.summary.videos)）· 计划修复 \(plan.items.count) 个 · 日期一致 \(plan.summary.unchanged) 个"
              )
            )
            .font(.headline)
            Text(
              L10n.text(
                "EXIF：\(plan.summary.fromExif) · 视频元数据：\(plan.summary.fromVideoMetadata) · 文件名时间：\(plan.summary.fromFilenameTime) · 仅日期：\(plan.summary.fromFilenameDay)"
              ))
            Text(
              L10n.text(
                "无有效日期：\(plan.summary.noDate) · 链接或特殊目录：\(plan.summary.linksOrContainers) · 读取失败：\(plan.summary.failures)"
              )
            )
            .foregroundStyle(.secondary)
          }.font(.caption)
          if !plan.items.isEmpty {
            GroupBox(L10n.text("创建日期预览（前 20 个）")) {
              VStack(spacing: 0) {
                ForEach(Array(plan.items.prefix(20))) { item in
                  VStack(alignment: .leading, spacing: 5) {
                    HStack {
                      Label(item.relativePath, systemImage: item.isVideo ? "video" : "photo")
                        .lineLimit(1).truncationMode(.middle).help(
                          item.relativePath)
                      Spacer()
                      Text(item.source.title).foregroundStyle(
                        item.source == .exif || item.source == .videoMetadata
                          ? Color.secondary : .orange)
                    }
                    Text(
                      L10n.text(
                        "创建日期：\(displayDate(item.originalDate)) → \(displayDate(item.targetDate))")
                    )
                    .foregroundStyle(.secondary).monospacedDigit()
                    if plan.repairModificationDate {
                      Text(
                        L10n.text(
                          "修改日期：\(displayDate(item.originalModificationDate)) → \(displayDate(item.targetDate))"
                        )
                      )
                      .foregroundStyle(.secondary).monospacedDigit()
                    }
                  }.font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                  Divider()
                }
              }
            }
          }
        }
        if let result = controller.result {
          GroupBox(result.cancelled ? L10n.text("修复已停止") : L10n.text("处理完成")) {
            VStack(alignment: .leading, spacing: 8) {
              Text(
                L10n.text(
                  "已修复 \(result.repaired) 个 · 文件变化已跳过 \(result.changed) 个 · 失败 \(result.failed) 个"))
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
            "只调整文件日期，保留原文件名、图片和视频内容及内嵌元数据，不重新编码。默认只修复创建日期；勾选后同时修复修改日期。跳过隐藏文件、链接、资料库和无有效日期的文件。无时区按 Mac 当前时区解释，部分磁盘会按秒取整。停止或退出保留已完成的修复。"
          )
        )
        .font(.caption).foregroundStyle(.secondary)
      }.padding(24).frame(maxWidth: 960, alignment: .leading).frame(
        maxWidth: .infinity, alignment: .leading)
    }.background(Color(nsColor: .windowBackgroundColor))
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.resolvesAliases = true
    if panel.runModal() == .OK, let url = panel.url { controller.selectFolder(url) }
  }

  private func displayDate(_ date: Date) -> String {
    date.formatted(.dateTime.year().month().day().hour().minute().second().locale(L10n.locale))
  }
}
