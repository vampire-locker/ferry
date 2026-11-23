import FerryCore
import SwiftUI

private let appVersion =
  Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? L10n.text("开发版")

let ferryAccent = Color(red: 0.05, green: 0.48, blue: 0.43)

struct ContentView: View {
  @ObservedObject var model: AppModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 0) {
      sidebar
      Divider()
      VStack(spacing: 0) {
        header
        Divider()
        ZStack {
          RetainedBrowserHost(model: model, isVisible: model.selectedPage == .browser)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(model.selectedPage != .browser)
          if model.selectedPage == .downloads {
            DownloadQueueView(controller: model.downloadQueue)
          } else if model.selectedPage == .tools {
            LocalToolsView(
              selection: Binding(
                get: { model.selectedLocalTool }, set: { model.selectLocalTool($0) }),
              dates: model.photoDateRepair, duplicates: model.duplicatePhotos,
              archive: model.mediaArchive, rename: model.mediaRename)
          }
        }
      }
      .background(Color(nsColor: .controlBackgroundColor))
    }
    .overlay(alignment: .center) {
      ZStack {
        if model.selectedPage == .browser, let feedback = model.enqueueFeedback {
          enqueueConfirmation(feedback)
            .id(feedback.id)
            .padding(20)
            .transition(reduceMotion ? .identity : .scale(scale: 0.96).combined(with: .opacity))
        }
      }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.enqueueFeedback?.id)
    }
    .background(
      PreviewKeyboardCapture {
        guard !model.previewActionsBlocked, model.previewableSelection != nil else { return false }
        model.previewSelection()
        return true
      }
    )
    .modifier(MediaPreviewPresentation(media: model.media))
    .modifier(DownloadConflictPresentation(controller: model.downloadQueue))
    .tint(ferryAccent)
    .task(id: model.enqueueFeedback?.id) {
      guard let id = model.enqueueFeedback?.id else { return }
      do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
      model.dismissEnqueueFeedback(id: id)
    }
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 24) {
      HStack(spacing: 12) {
        Image(systemName: "sailboat.fill")
          .font(.system(size: 27)).foregroundStyle(ferryAccent)
          .frame(width: 46, height: 46)
          .background(ferryAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))
        VStack(alignment: .leading, spacing: 3) {
          Text(L10n.text("渡舟")).font(.system(size: 20, weight: .bold))
          Text(L10n.text("让文件，轻松靠岸")).font(.caption).foregroundStyle(.secondary)
        }
      }
      .padding(.top, 12)

      VStack(spacing: 6) {
        pageButton(L10n.text("手机文件"), systemImage: "folder", page: .browser)
        pageButton(L10n.text("下载任务"), systemImage: "arrow.down.circle", page: .downloads)
        pageButton(L10n.text("本地工具"), systemImage: "wrench.and.screwdriver", page: .tools)
      }

      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Text(L10n.text("我的设备")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
          if !model.demo && !model.usbDevices.isEmpty {
            Picker(
              L10n.text("选择手机"),
              selection: Binding(
                get: { model.selectedUSBDeviceID }, set: { model.selectUSBDevice($0) }
              )
            ) {
              Text(L10n.text("请选择手机")).tag(nil as UInt64?)
              ForEach(model.usbDevices) { device in
                Text(device.label).tag(Optional(device.id))
              }
            }
            .labelsHidden()
            .accessibilityLabel(L10n.text("选择手机"))
            .disabled(model.connectionActionsBlocked)
          }
          Label(model.deviceName, systemImage: "iphone")
            .font(.subheadline.weight(.medium)).lineLimit(2)
          ForEach(model.storages) { storage in
            Button {
              model.selectStorage(storage.id)
            } label: {
              HStack {
                Image(systemName: "internaldrive")
                Text(storage.name).lineLimit(1)
                Spacer(minLength: 0)
                if storage.id == model.storageID && model.selectedPage == .browser {
                  Circle().fill(ferryAccent).frame(width: 6, height: 6)
                }
              }
              .padding(10)
              .background(
                storage.id == model.storageID && model.selectedPage == .browser
                  ? ferryAccent.opacity(0.1) : .clear,
                in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain).disabled(model.busy)
          }
          Button {
            model.connect()
          } label: {
            Label(
              model.storages.isEmpty ? L10n.text("手动连接") : L10n.text("重新连接"),
              systemImage: "cable.connector"
            )
            .frame(maxWidth: .infinity)
          }
          .controlSize(.large).disabled(model.connectionActionsBlocked)
          if !model.storages.isEmpty {
            Button(L10n.text("断开连接")) { model.disconnectPhone() }
              .disabled(model.connectionActionsBlocked)
              .help(L10n.text("释放手机 USB 连接并归还系统服务；再次连接需点击连接按钮。"))
            FrequentDirectoriesView(model: model)
          }
        }
      }
      VStack(alignment: .leading, spacing: 10) {
        Label(L10n.text("手机文件只读"), systemImage: "lock.shield")
          .font(.subheadline.weight(.medium))
        Text(L10n.text("下载不会修改或删除手机里的原文件。"))
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Divider().padding(.vertical, 4)
        SettingsLink {
          Label(L10n.text("设置"), systemImage: "gearshape")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        if model.demo {
          Text(L10n.text("当前为示例数据，不是手机文件"))
            .font(.caption).foregroundStyle(.orange)
        }
        Text(L10n.text("\(appVersion) · 本地预览版")).font(.caption2).foregroundStyle(.tertiary)
      }
    }
    .padding(20)
    .frame(width: 220)
    .frame(maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private func pageButton(_ title: String, systemImage: String, page: AppPage) -> some View {
    Button {
      model.selectPage(page)
    } label: {
      HStack(spacing: 10) {
        Label(title, systemImage: systemImage)
          .symbolEffect(
            .bounce, value: reduceMotion || page != .downloads ? 0 : model.enqueueRevision)
        Spacer(minLength: 0)
        if page == .downloads && model.downloadSummary.pendingTaskCount > 0 {
          Text("\(model.downloadSummary.pendingTaskCount)")
            .font(.caption.weight(.semibold)).monospacedDigit()
            .contentTransition(.numericText())
            .animation(
              reduceMotion ? nil : .easeOut(duration: 0.2),
              value: model.downloadSummary.pendingTaskCount
            )
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(ferryAccent.opacity(0.12), in: Capsule())
        }
      }
      .font(.subheadline.weight(.medium)).padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        model.selectedPage == page ? ferryAccent.opacity(0.1) : .clear,
        in: RoundedRectangle(cornerRadius: 8)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(model.selectedPage == page ? .isSelected : [])
  }

  private var header: some View {
    HStack(spacing: 14) {
      VStack(alignment: .leading, spacing: 5) {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Text(
            model.selectedPage == .tools
              ? L10n.text("本地工具")
              : model.selectedPage == .downloads
                ? L10n.text("下载任务")
                : model.storages.isEmpty ? L10n.text("从 Android，传到 Mac") : L10n.text("手机文件")
          )
          .font(.system(size: 20, weight: .semibold))
          if model.demo && model.selectedPage != .tools {
            Label(L10n.text("演示模式"), systemImage: "play.rectangle.fill")
              .font(.caption.weight(.medium))
              .foregroundStyle(.orange)
              .padding(.horizontal, 8).padding(.vertical, 3)
              .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
              .help(L10n.text("当前使用合成的示例数据，不连接或读取真实手机。"))
          }
        }
        .frame(minHeight: 26, alignment: .leading)
        Text(
          model.selectedPage == .tools
            ? L10n.text("管理 Mac 上已有的照片与视频")
            : model.selectedPage == .downloads
              ? L10n.text("查看进度、管理队列和打开下载结果") : model.status
        )
        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
      }
      Spacer()
      if model.busy && model.selectedPage == .browser {
        ProgressView().controlSize(.small)
        Button(model.cancelling ? L10n.text("停止中…") : L10n.text("停止")) { model.cancel() }
          .disabled(model.cancelling)
      }
    }
    .padding(.horizontal, 24).padding(.vertical, 20)
  }

  private func enqueueConfirmation(_ feedback: EnqueueFeedback) -> some View {
    HStack(spacing: 12) {
      Image(systemName: "checkmark.circle.fill")
        .font(.title2).foregroundStyle(ferryAccent)
      Text(L10n.text("已将 \(feedback.itemCount) 项加入下载队列"))
        .font(.subheadline.weight(.medium))
        .fixedSize(horizontal: false, vertical: true)
      Button(L10n.text("查看任务")) {
        model.dismissEnqueueFeedback(id: feedback.id)
        model.selectPage(.downloads)
      }
      .buttonStyle(.bordered).controlSize(.small)
    }
    .padding(14)
    .frame(maxWidth: 430, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12).stroke(ferryAccent.opacity(0.25), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
  }
}
