import AppKit
import FerryCore
import SwiftUI

struct LocalMediaArchiveView: View {
  @ObservedObject var controller: LocalMediaArchiveController
  @State private var confirming = false

  var body: some View {
    ScrollViewReader { proxy in
      content.onChange(of: controller.previewPage) { _, _ in
        if controller.phase == .ready {
          proxy.scrollTo("archive-path-preview", anchor: .top)
        }
      }
    }
  }

  private var content: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Label(
          controller.isRenaming ? L10n.text("按拍摄时间重命名") : L10n.text("图片/视频年月归档"),
          systemImage: controller.isRenaming ? LocalTool.rename.symbol : LocalTool.archive.symbol
        )
        .font(.title2.weight(.semibold))
        Text(
          controller.isRenaming
            ? L10n.text("读取图片和视频的拍摄时间，缺失时从文件名补充，在原文件夹中重命名，并同步创建日期和修改日期。先预览，再确认处理，无需连接手机。")
            : L10n.text("将已有图片和视频移动到所选文件夹内的“年份/月”目录，先预览，再确认归档。不需要手机连接。")
        )
        .foregroundStyle(.secondary)
        GroupBox {
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              Text(controller.folder?.path ?? L10n.text("尚未选择文件夹"))
                .font(.caption).textSelection(.enabled)
              Spacer()
              Button(L10n.text("选择文件夹…"), action: chooseFolder)
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
              Toggle(
                L10n.text("包含子文件夹"),
                isOn: Binding(
                  get: { controller.recursive && controller.folderYear == nil },
                  set: { controller.setOptions(recursive: $0) })
              )
              .disabled(controller.folderYear != nil)
            }
            if let year = controller.folderYear {
              Text(L10n.text("已识别年份目录 \(year)：仅整理根目录文件，直接归入月份；已有子目录保持不动，不同年份保留原位。"))
                .font(.caption).foregroundStyle(.secondary)
            }
            Text(
              controller.isRenaming
                ? L10n.text("图片优先使用 EXIF 原始拍摄时间，其次内嵌创建时间；视频使用内嵌拍摄或创建时间。缺失时默认从文件名识别完整日期和时间，并标明来源；不使用文件系统日期。")
                : L10n.text("优先使用 EXIF / 视频拍摄元数据；缺失时先识别文件名日期，再使用文件创建日期。不会使用修改日期。")
            )
            .font(.caption).foregroundStyle(.secondary)
            if controller.isRenaming {
              Text(
                L10n.text(
                  "图片：IMG_20151101_145451.jpg、IMG_20151101_145451.png；视频：VID_20250704_005959.mp4。保留原扩展名及大小写，不转换格式。"
                )
              )
              .font(.caption).foregroundStyle(.secondary)
              Text(L10n.text("文件名保留元数据记录的当地时间；文件日期按元数据时区解释。文件名补充或元数据没有时区时，使用 Mac 当前时区；仅有年月日的文件名跳过。"))
                .font(.caption).foregroundStyle(.secondary)
            }
          }.padding(8).disabled(controller.isBusy)
        }
        HStack(spacing: 12) {
          Button(controller.isRenaming ? L10n.text("扫描图片/视频") : L10n.text("扫描媒体")) {
            controller.scan()
          }
          .disabled(
            controller.folder == nil || controller.isBusy
              || (!controller.images && !controller.videos))
          Button(
            controller.isRenaming
              ? L10n.text("重命名已选 \(controller.selectedCount) 个文件")
              : L10n.text("归档已选 \(controller.selectedCount) 个文件")
          ) { confirming = true }
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
                : controller.conflict != nil
                  ? L10n.text("等待处理同名文件")
                  : controller.isScanning
                    ? L10n.text("正在扫描，已检查 \(controller.progress.processed) 个媒体文件…")
                    : controller.isRenaming
                      ? L10n.text(
                        "正在重命名 \(controller.progress.processed) / \(controller.progress.total)")
                      : L10n.text(
                        "正在归档 \(controller.progress.processed) / \(controller.progress.total)"))
            if controller.isScanning {
              ProgressView().controlSize(.small)
            } else {
              ProgressView(
                value: Double(controller.progress.processed),
                total: Double(max(1, controller.progress.total)))
            }
            if controller.progress.localCopyTotal > 0 {
              Text(
                controller.progress.verifyingCopy
                  ? L10n.text("正在校验源文件和副本…")
                  : L10n.text(
                    "正在本地复制：\(Display.bytes(controller.progress.localCopyBytes)) / \(Display.bytes(controller.progress.localCopyTotal))"
                  )
              )
              .font(.caption).foregroundStyle(.secondary)
              ProgressView(
                value: Double(controller.progress.localCopyBytes),
                total: Double(controller.progress.localCopyTotal))
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
        if let plan = controller.plan, controller.phase == .ready {
          Text(
            L10n.text(
              "图片：\(plan.summary.images) · 视频：\(plan.summary.videos) · 跳过：\(plan.summary.skipped) · 读取失败：\(plan.summary.failed)"
            )
          )
          .font(.caption).foregroundStyle(.secondary)
          Text(
            controller.isRenaming
              ? L10n.text(
                "待处理：\(controller.movingCount) · 名称和日期已符合：\(controller.alreadyCount) · 无有效时间：\(plan.summary.noDate)"
              )
              : L10n.text(
                "可归档：\(controller.movingCount) · 已在目标目录：\(controller.alreadyCount) · 已选文件待选月份：\(controller.unresolvedCount)"
              )
          )
          .font(.subheadline.weight(.medium))
          if plan.summary.otherYears > 0 {
            GroupBox(L10n.text("与目录年份不符：\(plan.summary.otherYears) 个，已保留原位")) {
              VStack(alignment: .leading, spacing: 6) {
                ForEach(plan.skippedYearItems) { issue in
                  Text("\(issue.path) · \(issue.message)").font(.caption).textSelection(.enabled)
                }
                if plan.summary.otherYears > plan.skippedYearItems.count {
                  Text(L10n.text("仅显示前 50 条。")).font(.caption).foregroundStyle(.secondary)
                }
              }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
          }
          ForEach(plan.directories.filter { $0.candidates.count > 1 }) { directory in
            Picker(
              L10n.text("\(directory.id) 归档目录"),
              selection: Binding(
                get: { controller.choices[directory.id] ?? "" },
                set: { controller.choose($0, for: directory.id) })
            ) {
              Text(L10n.text("请选择归档目录")).tag("")
              ForEach(directory.candidates, id: \.self) { Text($0).tag($0) }
            }
          }
          if !plan.items.isEmpty {
            GroupBox(controller.isRenaming ? L10n.text("名称和日期预览") : L10n.text("归档路径预览")) {
              VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                  Text(L10n.text("已选择 \(controller.selectedCount) 个文件")).font(.caption)
                    .monospacedDigit()
                  Spacer()
                  Button(L10n.text("全部选择")) { controller.selectAll(true) }
                    .disabled(controller.isAllSelected)
                  Button(L10n.text("清空选择")) { controller.selectAll(false) }
                    .disabled(controller.selectedCount == 0)
                }.controlSize(.small)
                previewPagination
                Divider()
                ForEach(Array(controller.previewItems)) { item in
                  HStack(alignment: .top, spacing: 10) {
                    Toggle(
                      L10n.text("选择文件 \(item.relativePath)"),
                      isOn: Binding(
                        get: { controller.selectedIDs.contains(item.id) },
                        set: { controller.selectItem(item.id, selected: $0) })
                    )
                    .labelsHidden().toggleStyle(.checkbox).disabled(!controller.canSelect(item.id))
                    VStack(alignment: .leading, spacing: 4) {
                      HStack {
                        Text(item.relativePath).lineLimit(1).truncationMode(.middle).help(
                          item.relativePath)
                        Spacer()
                        Text(item.source.title).foregroundStyle(.secondary)
                      }
                      Text(
                        "→ "
                          + (plan.destination(item, choices: controller.choices)
                            ?? L10n.text("请选择归档目录"))
                      )
                      .foregroundStyle(.secondary).textSelection(.enabled)
                      if controller.isRenaming, let targetDate = item.captureDate {
                        Text(
                          L10n.text(
                            "创建日期：\(displayDate(item.creationDate)) → \(displayDate(targetDate))")
                        )
                        .foregroundStyle(.secondary)
                        Text(
                          L10n.text(
                            "修改日期：\(displayDate(item.modificationDate)) → \(displayDate(targetDate))"
                          )
                        )
                        .foregroundStyle(.secondary)
                      }
                      if !controller.canSelect(item.id) {
                        Text(
                          controller.isRenaming
                            ? L10n.text("名称和日期已符合，无需处理") : L10n.text("已在目标目录，无需处理")
                        ).foregroundStyle(.secondary)
                      }
                    }
                  }.font(.caption)
                  Divider()
                }
                previewPagination
              }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }.id("archive-path-preview")
          }
        }
        if let result = controller.result {
          GroupBox(
            result.cancelled
              ? (controller.isRenaming ? L10n.text("重命名已停止") : L10n.text("归档已停止"))
              : L10n.text("处理完成")
          ) {
            VStack(alignment: .leading, spacing: 10) {
              Text(
                controller.isRenaming
                  ? L10n.text(
                    "已重命名 \(result.moved) 个 · 已同步日期 \(result.datesUpdated) 个 · 跳过 \(result.skipped) 个 · 失败 \(result.failed) 个"
                  )
                  : L10n.text(
                    "已归档 \(result.moved) 个（替换 \(result.replaced) 个）· 跳过 \(result.skipped) 个 · 已在目标目录 \(result.already) 个 · 失败 \(result.failed) 个"
                  ))
              if !result.moves.isEmpty {
                Text(
                  controller.isRenaming
                    ? L10n.text("实际处理路径（最多 100 条）") : L10n.text("实际移动路径（最多 100 条）")
                ).font(.caption.weight(.medium))
              }
              ForEach(result.moves) { move in
                Text(
                  "\(move.original) → \(move.destination)"
                    + (move.replaced ? L10n.text("（已替换）") : "")
                )
                .font(.caption).textSelection(.enabled)
              }
              if !result.issues.isEmpty {
                Text(L10n.text("问题明细（最多 50 条）")).font(.caption.weight(.medium))
              }
              ForEach(result.issues) { issue in
                Text("\(issue.path) · \(issue.message)").font(.caption).foregroundStyle(.secondary)
                  .textSelection(.enabled)
              }
              Text(L10n.text("再次处理前请重新扫描。")).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
          }
        }
        Text(
          controller.isRenaming
            ? L10n.text(
              "只在原文件夹内重命名并同步日期，保留文件内容、EXIF 和原扩展名。元数据和文件名都没有有效时间、隐藏文件、链接、照片资料库及应用包不处理。停止保留已完成的重命名和日期同步。")
            : L10n.text(
              "保留归档文件的内容、EXIF、创建日期和修改日期；同名时选择保留两者、跳过或替换。保留两者会自动编号，替换会覆盖目标文件。复用已有月份目录，不删除空目录。跳过隐藏文件、链接、照片资料库及应用包。停止只影响剩余文件。"
            )
        )
        .font(.caption).foregroundStyle(.secondary)
        Text(L10n.text("同盘优先直接移动，磁盘不支持时才复制校验。归档时请避免其他程序同时写入同一目标目录。强退或拔盘可能留下占位文件或副本。"))
          .font(.caption).foregroundStyle(.secondary)
      }.padding(24).frame(maxWidth: 960, alignment: .leading).frame(
        maxWidth: .infinity, alignment: .leading)
    }.background(Color(nsColor: .windowBackgroundColor))
      .sheet(item: Binding(get: { controller.conflict }, set: { _ in })) { question in
        DownloadConflictView(
          conflict: question.file,
          context: controller.isRenaming
            ? .localRename(
              sourcePath: question.sourcePath, targetChanged: question.targetChanged,
              blockedReason: question.replacementBlockedReason)
            : .localArchive(sourcePath: question.sourcePath, targetChanged: question.targetChanged),
          resolve: controller.resolve, stop: controller.cancel
        )
        .id(question.id).interactiveDismissDisabled()
      }
      .alert(
        controller.isRenaming ? L10n.text("确认重命名并同步文件日期？") : L10n.text("确认移动并归档文件？"),
        isPresented: $confirming
      ) {
        Button(L10n.text("取消"), role: .cancel) {}
        Button(controller.isRenaming ? L10n.text("开始重命名") : L10n.text("开始归档")) {
          controller.apply()
        }
      } message: {
        Text(
          controller.isRenaming
            ? L10n.text(
              "将处理已选的 \(controller.selectedCount) 个文件，在原文件夹内重命名，并把创建、修改日期同步为预览中的时间（优先元数据，缺失时使用文件名）。未选文件不处理；停止不会撤回已完成的更改。"
            )
            : L10n.text(
              "将移动已选的 \(controller.selectedCount) 个文件到所选文件夹内的年月目录，未勾选的文件保持原位。同名时询问处理方式；已完成的移动或替换不会因停止而恢复原状。"
            ))
      }
  }
  private func displayDate(_ date: Date) -> String {
    date.formatted(.dateTime.year().month().day().hour().minute().second().locale(L10n.locale))
  }

  private var previewPagination: some View {
    HStack(spacing: 12) {
      Text(
        L10n.text(
          "共 \(controller.plan?.items.count ?? 0) 个，当前第 \(controller.previewRange.lowerBound + 1)–\(controller.previewRange.upperBound) 个"
        )
      )
      .font(.caption).foregroundStyle(.secondary).monospacedDigit()
      Spacer(minLength: 0)
      Toggle(
        L10n.text("本页全选"),
        isOn: Binding(
          get: { controller.isPageSelected }, set: { controller.selectPage($0) })
      )
      .toggleStyle(.checkbox).disabled(controller.pageSelectableIDs.isEmpty)
      Text(L10n.text("第 \(controller.previewPage + 1) / \(controller.previewPageCount) 页"))
        .font(.caption).monospacedDigit()
      Button(L10n.text("上一页")) { controller.showPreviewPage(controller.previewPage - 1) }
        .disabled(controller.previewPage == 0)
      Button(L10n.text("下一页")) { controller.showPreviewPage(controller.previewPage + 1) }
        .disabled(controller.previewPage + 1 >= controller.previewPageCount)
    }.controlSize(.small)
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.resolvesAliases = true
    if panel.runModal() == .OK, let url = panel.url { controller.selectFolder(url) }
  }
}
