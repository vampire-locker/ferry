import FerryCore
import SwiftUI

private struct BreadcrumbLocation: Identifiable {
  let id: Int
  let name: String
}

struct BreadcrumbPath: View {
  @ObservedObject var model: AppModel

  private var locations: [BreadcrumbLocation] {
    let storage = model.storages.first(where: { $0.id == model.storageID })?.name ?? L10n.text("手机")
    return [BreadcrumbLocation(id: 0, name: storage)]
      + model.folders.enumerated().map {
        BreadcrumbLocation(id: $0.offset + 1, name: $0.element.name)
      }
  }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 5) {
        ForEach(locations) { location in
          if location.id > 0 { Text("/").foregroundStyle(.tertiary) }
          Button {
            model.navigateToFolder(atDepth: location.id)
          } label: {
            Text(location.name)
              .foregroundStyle(
                location.id == model.folders.count ? Color.primary : Color.accentColor
              )
              .padding(.vertical, 3)
          }
          .buttonStyle(.plain)
          .disabled(location.id == model.folders.count)
          .help(
            location.id == model.folders.count
              ? L10n.text("当前目录") : L10n.text("返回 \(location.name)"))
        }
      }
      .fixedSize(horizontal: true, vertical: false)

      HStack(spacing: 5) {
        Menu {
          ForEach(locations) { location in
            Button(location.id == 0 ? location.name : L10n.text("返回 \(location.name)")) {
              model.navigateToFolder(atDepth: location.id)
            }
            .disabled(location.id == model.folders.count)
          }
        } label: {
          Label(L10n.text("选择上级目录"), systemImage: "ellipsis").labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(model.path)
        Text("/").foregroundStyle(.tertiary)
        Text(locations.last?.name ?? L10n.text("手机")).lineLimit(1).truncationMode(.middle)
          .help(model.path)
      }
    }
    .font(.subheadline)
    .frame(maxWidth: .infinity, alignment: .leading)
    .disabled(model.busy)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(L10n.text("目录路径"))
  }
}
