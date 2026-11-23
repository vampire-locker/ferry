import FerryCore
import SwiftUI

struct BrowserPageView: View {
  @ObservedObject var model: AppModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 0) {
      if let error = model.error { errorBanner(error) }
      Group {
        if model.storages.isEmpty { welcome } else { browser }
      }
      if model.downloadSummary.hasTasks {
        Divider()
        if model.selectedPage == .browser {
          DownloadStatusBar(controller: model.downloadQueue) { model.selectPage(.downloads) }
        } else {
          // Preserve the table's viewport without observing progress offscreen.
          Color.clear.frame(height: DownloadStatusBar.height)
        }
      }
      Divider()
      downloadBar
    }
    .disabled(model.selectedPage != .browser)
  }

  private var welcome: some View {
    VStack(spacing: 24) {
      Spacer(minLength: 20)
      ZStack {
        Circle().fill(ferryAccent.opacity(0.07)).frame(width: 132, height: 132)
        Image(systemName: "externaldrive.badge.plus")
          .font(.system(size: 52, weight: .light)).foregroundStyle(ferryAccent)
      }
      VStack(spacing: 10) {
        Text(model.demo ? L10n.text("先体验一次轻松传输") : L10n.text("把手机里的珍藏带回 Mac"))
          .font(.system(size: 20, weight: .semibold))
        Text(model.demo ? L10n.text("使用合成的文件和文件夹，完整体验浏览与下载。") : L10n.text("插入数据线并选择文件传输，渡舟会自动连接。"))
          .foregroundStyle(.secondary)
      }
      HStack(alignment: .top, spacing: 26) {
        setupStep("1", L10n.text("连接数据线"), L10n.text("使用支持数据传输的 USB 线"))
        setupStep("2", L10n.text("解锁手机"), L10n.text("USB 用途选择“文件传输”"))
        setupStep("3", L10n.text("允许访问"), L10n.text("关闭其他占用手机的传输工具"))
      }
      .padding(.vertical, 8)
      Button {
        model.connect()
      } label: {
        Label(model.demo ? L10n.text("连接演示手机") : L10n.text("手动连接"), systemImage: "cable.connector")
          .padding(.horizontal, 16).padding(.vertical, 5)
      }
      .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.connectionActionsBlocked)
      Spacer(minLength: 20)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
  }

  private func setupStep(_ number: String, _ title: String, _ detail: String) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(number).font(.caption.bold()).foregroundStyle(ferryAccent)
        .frame(width: 23, height: 23).background(ferryAccent.opacity(0.1), in: Circle())
      Text(title).font(.subheadline.weight(.semibold))
      Text(detail).font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }

  private var browser: some View {
    VStack(spacing: 0) {
      HStack {
        Button {
          model.up()
        } label: {
          Image(systemName: "chevron.left")
        }
        .disabled(model.busy || model.folders.isEmpty).help(L10n.text("返回上一级"))
        BreadcrumbPath(model: model)
        if model.sorting { ProgressView().controlSize(.small).help(L10n.text("正在排序当前目录")) }
        Picker(
          L10n.text("浏览视图"),
          selection: Binding(get: { model.viewMode }, set: { model.setViewMode($0) })
        ) {
          Label(L10n.text("列表"), systemImage: "list.bullet").tag(BrowserViewMode.list)
          Label(L10n.text("预览"), systemImage: "square.grid.2x2").tag(BrowserViewMode.preview)
        }
        .pickerStyle(.segmented).labelsHidden().frame(width: 135).disabled(
          model.previewActionsBlocked)
        Button {
          model.previewSelection()
        } label: {
          Image(systemName: "eye")
        }
        .disabled(model.previewActionsBlocked || model.previewableSelection == nil).help(
          L10n.text("预览所选文件（空格）"))
        TextField(L10n.text("搜索当前目录"), text: $model.query)
          .textFieldStyle(.roundedBorder).frame(width: 180).disabled(model.busy)
        Button {
          model.loadDirectory()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .disabled(model.busy).help(L10n.text("刷新目录"))
      }
      .padding(.horizontal, 18).padding(.vertical, 12)
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 10) {
          yearFilterControl
          monthFilterControl
          mediaFilterControl
          Spacer(minLength: 0)
          clearFiltersButton
        }
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 10) {
            yearFilterControl
            monthFilterControl
            Spacer(minLength: 0)
          }
          HStack(spacing: 10) {
            mediaFilterControl
            Spacer(minLength: 0)
            clearFiltersButton
          }
        }
      }
      .padding(.horizontal, 18).padding(.bottom, 10)
      Group {
        if model.viewMode == .list {
          fileList
        } else {
          PreviewGrid(model: model, media: model.media)
        }
      }
      .disabled(model.fileActionsBlocked)
      .overlay {
        if model.filtering {
          VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(L10n.text("正在筛选…")).font(.caption).foregroundStyle(.secondary)
          }
          .padding(20)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        } else if model.entries.isEmpty && !model.busy {
          ContentUnavailableView(
            model.error == nil ? L10n.text("这里还没有文件") : L10n.text("目录未能加载"),
            systemImage: "folder",
            description: Text(
              model.error == nil ? L10n.text("可以返回上一级浏览其他目录。") : L10n.text("请检查连接，然后刷新目录。")))
        } else if !model.entries.isEmpty && model.visibleEntries.isEmpty {
          if !model.query.isEmpty {
            ContentUnavailableView.search(text: model.query)
          } else if model.yearFilter != .all || model.monthFilter != .all
            || model.mediaFilter != .all
          {
            ContentUnavailableView {
              Label(L10n.text("没有符合筛选条件的文件"), systemImage: "line.3.horizontal.decrease.circle")
            } description: {
              Text(L10n.text("可调整修改年份、月份或类型，或清除筛选查看全部项目。"))
            } actions: {
              Button(L10n.text("清除筛选")) { model.clearFileFilters() }
            }
          } else {
            ContentUnavailableView(
              L10n.text("此目录的项目已隐藏"), systemImage: "eye.slash",
              description: Text(L10n.text("可在设置中开启“显示隐藏文件和文件夹”。")))
          }
        }
      }
      HStack {
        Text(model.filtering ? L10n.text("正在筛选…") : L10n.text("\(model.visibleEntries.count) 项"))
        if model.hiddenEntryCount > 0 { Text(L10n.text("· 已隐藏 \(model.hiddenEntryCount) 项")) }
        if !model.selection.isEmpty { Text(L10n.text("· 已选择 \(model.selection.count) 项")) }
        Button(L10n.text("全选")) { model.selectAllVisible() }.disabled(
          model.fileActionsBlocked || model.visibleEntries.isEmpty)
        Button(L10n.text("取消选择")) { model.clearSelection() }.disabled(
          model.fileActionsBlocked || model.selection.isEmpty)
        if model.hasUnloadedSizes {
          Button(L10n.text("读取大小")) { model.loadDirectorySizes() }
            .disabled(model.fileActionsBlocked)
            .help(L10n.text("按需读取当前目录的文件大小；点击大小列排序也会读取。"))
        }
        Spacer()
        Text(L10n.text("空格预览 · 双击打开 · ⌘ / Shift 多选"))
      }
      .font(.caption).foregroundStyle(.secondary)
      .padding(.horizontal, 20).padding(.vertical, 10)
    }
  }

  private var yearFilterControl: some View {
    HStack(spacing: 8) {
      Label(L10n.text("修改年份"), systemImage: "calendar").foregroundStyle(.secondary)
      Picker(
        L10n.text("按修改年份筛选"),
        selection: Binding(
          get: { model.yearFilter }, set: { model.setYearFilter($0) }
        )
      ) {
        ForEach(model.yearOptions) { option in Text(option.title).tag(option.filter) }
      }
      .labelsHidden().frame(width: 160)
      .disabled(model.busy || model.yearOptions.count <= 1)
      .help(L10n.text("按当前目录文件的修改年份筛选，不包含文件夹；日期缺失的文件可选择“日期未知”。"))
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  private var monthFilterControl: some View {
    HStack(spacing: 8) {
      Text(L10n.text("月份")).foregroundStyle(.secondary)
      Picker(
        L10n.text("按修改月份筛选"),
        selection: Binding(
          get: { model.monthFilter }, set: { model.setMonthFilter($0) }
        )
      ) {
        ForEach(model.monthOptions) { option in Text(option.title).tag(option.filter) }
      }
      .labelsHidden().frame(width: 130)
      .disabled(model.busy || model.monthOptions.count <= 1)
      .help(L10n.text("按文件修改日期的月份筛选，可与年份叠加；选择具体月份时不包含文件夹或日期未知的文件。"))
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  private var mediaFilterControl: some View {
    HStack(spacing: 8) {
      Label(L10n.text("类型"), systemImage: "line.3.horizontal.decrease.circle").foregroundStyle(
        .secondary)
      Picker(
        L10n.text("按媒体类型筛选"),
        selection: Binding(
          get: { model.mediaFilter }, set: { model.setMediaFilter($0) }
        )
      ) {
        ForEach(DirectoryMediaFilter.allCases) { filter in Text(filter.title).tag(filter) }
      }
      .labelsHidden().frame(width: 110).disabled(model.busy)
      .help(L10n.text("按文件扩展名筛选多种图片或视频格式，不区分大小写；选择图片或视频时不包含文件夹。"))
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  @ViewBuilder private var clearFiltersButton: some View {
    if model.yearFilter != .all || model.monthFilter != .all || model.mediaFilter != .all
      || !model.query.isEmpty
    {
      Button(L10n.text("清除筛选")) { model.clearFileFilters() }.disabled(model.busy)
    }
  }

  private var fileList: some View {
    Table(
      model.visibleEntries,
      selection: Binding(
        get: { model.selection },
        set: { if !model.fileActionsBlocked && model.selection != $0 { model.selection = $0 } }
      ),
      sortOrder: Binding(
        get: { model.sortOrder }, set: { if model.sortOrder != $0 { model.sortOrder = $0 } })
    ) {
      TableColumn(L10n.text("选择")) { entry in
        Toggle(
          L10n.text("选择 \(entry.name)"),
          isOn: Binding(
            get: { model.selection.contains(entry.id) },
            set: { model.setSelected(entry.id, selected: $0) }
          )
        )
        .toggleStyle(.checkbox)
        .labelsHidden()
      }.width(36)
      TableColumn(L10n.text("名称"), value: \.name) { entry in
        HStack(spacing: 10) {
          Image(systemName: entry.symbol).font(.title3)
            .foregroundStyle(entry.isDirectory ? ferryAccent : .secondary)
            .frame(width: 24)
          Text(entry.name).lineLimit(1)
          Spacer(minLength: 0)
          if entry.isDirectory {
            Button {
              model.open(entry)
            } label: {
              Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless).help(L10n.text("打开 \(entry.name)"))
          }
        }
        .padding(.vertical, 5)
      }.width(min: 220, ideal: 360)
      TableColumn(L10n.text("大小"), value: \.sortSize) { entry in
        Text(entry.isDirectory ? "—" : entry.sizeDescription)
          .monospacedDigit().foregroundStyle(.secondary)
      }.width(90)
      TableColumn(L10n.text("类型"), value: \.kind) { entry in
        Text(entry.kind).foregroundStyle(.secondary)
      }
      .width(80)
      TableColumn(L10n.text("修改日期"), value: \.modified) { entry in
        if entry.modified > 0 {
          Text(
            Date(timeIntervalSince1970: Double(entry.modified)),
            format: .dateTime.year().month().day()
          )
          .lineLimit(1)
          .foregroundStyle(.secondary)
        } else {
          Text("—").foregroundStyle(.secondary)
        }
      }.width(min: 140, ideal: 180)
    }
    .contextMenu(forSelectionType: UInt32.self) { ids in
      if ids.count == 1, let id = ids.first,
        let entry = model.visibleEntries.first(where: { $0.id == id }), entry.isDirectory
      {
        Button(L10n.text("打开文件夹")) { model.open(entry) }
      }
      if ids.count == 1, let id = ids.first,
        model.visibleEntries.contains(where: { $0.id == id && !$0.isDirectory })
      {
        Button(L10n.text("预览")) {
          model.selection = ids
          model.previewSelection()
        }.disabled(model.previewActionsBlocked)
      }
      if !ids.isEmpty {
        Button(model.downloadSummary.hasPendingTasks ? L10n.text("加入下载队列") : L10n.text("下载所选项目")) {
          model.selection = ids
          model.download()
        }
        .disabled(model.fileActionsBlocked)
      }
    } primaryAction: { ids in
      guard !model.fileActionsBlocked, ids.count == 1, let id = ids.first,
        let entry = model.visibleEntries.first(where: { $0.id == id })
      else { return }
      if entry.isDirectory {
        model.open(entry)
      } else {
        model.selection = ids
        model.previewSelection()
      }
    }
    .disabled(model.fileActionsBlocked)
  }

  private func errorBanner(_ message: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
      Text(message).font(.caption).textSelection(.enabled).fixedSize(
        horizontal: false, vertical: true)
      Spacer(minLength: 0)
      Button {
        model.error = nil
      } label: {
        Image(systemName: "xmark")
      }.buttonStyle(.plain)
    }
    .padding(12).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    .padding(.horizontal, 20).padding(.top, 12)
  }

  private var downloadBar: some View {
    HStack(spacing: 16) {
      Image(systemName: "folder.badge.gearshape").foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 4) {
        Text(L10n.text("保存到 \(model.destination.lastPathComponent)")).font(
          .subheadline.weight(.medium)
        )
        .help(model.destination.path)
        Toggle(
          L10n.text("为本次下载创建文件夹"),
          isOn: Binding(
            get: { model.createDownloadFolder }, set: { model.setCreateDownloadFolder($0) })
        )
        .toggleStyle(.checkbox).font(.caption)
        .help(L10n.text("默认直接保存到所选位置；同名文件会询问处理方式。"))
      }
      Button(L10n.text("更改…")) { model.chooseDestination() }.disabled(model.busy)
      Spacer(minLength: 0)
      Button {
        model.download()
      } label: {
        Label(
          model.downloadSummary.hasPendingTasks
            ? (model.selection.isEmpty
              ? L10n.text("加入下载队列") : L10n.text("加入队列 \(model.selection.count) 项"))
            : (model.selection.isEmpty
              ? L10n.text("下载到 Mac") : L10n.text("下载 \(model.selection.count) 项")),
          systemImage: model.downloadSummary.hasPendingTasks ? "text.badge.plus" : "arrow.down"
        )
        .symbolEffect(.bounce, value: reduceMotion ? 0 : model.enqueueRevision)
      }
      .buttonStyle(.borderedProminent).controlSize(.large)
      .disabled(model.fileActionsBlocked || model.selection.isEmpty)
    }.padding(20)
  }

}
