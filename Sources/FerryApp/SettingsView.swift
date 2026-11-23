import FerryCore
import SwiftUI

struct SettingsView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    Form {
      Section(L10n.text("通用")) {
        Picker(
          L10n.text("语言"),
          selection: Binding(get: { model.languagePreference }, set: { model.setLanguage($0) })
        ) {
          ForEach(AppLanguage.allCases) { language in Text(language.title).tag(language) }
        }
        Text(L10n.text("语言更改在重新启动应用后生效。")).font(.caption).foregroundStyle(.secondary)
        Picker(
          L10n.text("外观"),
          selection: Binding(get: { model.appearance }, set: { model.setAppearance($0) })
        ) {
          ForEach(AppAppearance.allCases) { appearance in Text(appearance.title).tag(appearance) }
        }.pickerStyle(.segmented)
      }
      Section(L10n.text("文件显示")) {
        Toggle(
          L10n.text("显示隐藏文件和文件夹"),
          isOn: Binding(
            get: { model.showHiddenFiles }, set: { model.setShowHiddenFiles($0) }
          )
        )
        .disabled(model.busy)
        Text(L10n.text("默认隐藏名称以“.”开头的项目，设置会在下次打开应用时保留。"))
          .font(.caption).foregroundStyle(.secondary)
        Text(L10n.text("关闭时，下载也会跳过隐藏文件和文件夹，包括所选文件夹内部的隐藏项目。"))
          .font(.caption).foregroundStyle(.secondary)
      }
      Section(L10n.text("下载")) {
        Toggle(
          L10n.text("按拍摄年月归档图片"),
          isOn: Binding(
            get: { model.archivePhotosByMonth }, set: { model.setArchivePhotosByMonth($0) }
          )
        )
        Text(
          L10n.text("图片保存到“年份/月份”目录；优先使用 EXIF 拍摄时间，缺失时使用手机修改日期，都没有则放入“日期未知”。")
        )
        .font(.caption).foregroundStyle(.secondary)
        Toggle(
          L10n.text("按拍摄年月归档视频"),
          isOn: Binding(
            get: { model.archiveVideosByMonth }, set: { model.setArchiveVideosByMonth($0) })
        )
        Text(
          L10n.text(
            "视频优先使用内嵌日期，缺失时使用手机修改日期，都没有则放入“日期未知”。MP4、MOV、M4V、3GP 可读取容器日期，其他格式使用手机修改日期。不解码或转码视频。")
        )
        .font(.caption).foregroundStyle(.secondary)
        Text(L10n.text("图片和视频可共用已有年月目录；未开启归档的类型保留原目录结构。视频内嵌日期可能是剪辑或导出时间，未必是原始拍摄时间。"))
          .font(.caption).foregroundStyle(.secondary)
        Toggle(
          L10n.text("将照片创建日期设为拍摄时间"),
          isOn: Binding(
            get: { model.usePhotoCreationDate }, set: { model.setUsePhotoCreationDate($0) }
          )
        )
        Text(L10n.text("仅读取照片的 EXIF 原始日期时间；没有有效拍摄时间时保持原样。保留修改日期，不改变图片内容。"))
          .font(.caption).foregroundStyle(.secondary)
      }
      Section(L10n.text("USB 连接")) {
        Toggle(
          L10n.text("允许系统授权临时接管 USB"),
          isOn: Binding(
            get: { model.allowUSBCapture }, set: { model.setAllowUSBCapture($0) }
          )
        ).disabled(model.connectionActionsBlocked || !model.usbCaptureAvailable)
        Text(
          model.usbCaptureAvailable
            ? (model.usbCaptureRequiresAdministrator
              ? L10n.text(
                "连接时由 macOS 请求管理员授权，临时接管 USB。连接成功后以当前用户权限浏览和下载，不安装后台服务。接管期间照片导入或 ADB 可能暂不可用；断开或退出后归还。"
              )
              : L10n.text(
                "相机服务占用手机时向 macOS 请求授权。接管期间该手机的照片导入或 ADB 可能暂不可用；断开连接或退出后归还。更改此项会释放当前连接，需手动重新连接。"))
            : L10n.text("传输引擎签名不可用于授权连接，请重新构建应用；普通 USB 连接仍可使用。")
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Section(L10n.text("体验与测试")) {
        Toggle(
          L10n.text("演示模式（示例数据）"),
          isOn: Binding(
            get: { model.demo }, set: { model.changeMode($0) }
          )
        )
        .disabled(model.connectionActionsBlocked)
        Text(L10n.text("使用合成文件体验浏览和下载，不连接手机，也不包含手机中的真实文件。退出演示模式后会恢复自动检测手机。"))
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(width: 560, height: 640)
    .padding(12)
  }
}
