import FerryCore
import SwiftUI

struct FrequentDirectoriesView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Divider().padding(.vertical, 6)
      Text(L10n.text("经常访问"))
        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        .padding(.bottom, 2)
      if model.frequentDirectories.isEmpty {
        Text(L10n.text("成功打开的目录会显示在这里"))
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.vertical, 6)
      } else {
        ForEach(Array(model.frequentDirectories.prefix(8)), id: \.id) { entry in
          directoryRow(entry)
        }
      }
    }
  }

  private func directoryRow(_ entry: FrequentDirectory) -> some View {
    let current = model.selectedPage == .browser && model.isCurrentFrequentDirectory(entry)
    let unavailable = !model.isFrequentStorageAvailable(entry)
    return HStack(spacing: 0) {
      Button {
        model.openFrequentDirectory(entry)
      } label: {
        HStack(alignment: .top, spacing: 9) {
          Image(systemName: "folder")
            .foregroundStyle(current ? Color.accentColor : .secondary)
            .padding(.top, 1)
          VStack(alignment: .leading, spacing: 3) {
            Text(entry.name).font(.subheadline)
              .lineLimit(1).truncationMode(.middle)
            Text(parentDescription(entry)).font(.caption2).foregroundStyle(.secondary)
              .lineLimit(1).truncationMode(.middle)
          }
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(model.busy || unavailable || current)
    }
    .background(
      current ? Color.accentColor.opacity(0.1) : .clear,
      in: RoundedRectangle(cornerRadius: 8)
    )
    .contentShape(Rectangle())
    .contextMenu {
      Button(L10n.text("从经常访问中移除"), systemImage: "minus.circle") {
        model.removeFrequentDirectory(entry.id)
      }
    }
    .help(entry.pathDescription)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(entry.pathDescription)
    .accessibilityAddTraits(current ? .isSelected : [])
  }

  private func parentDescription(_ entry: FrequentDirectory) -> String {
    ([entry.storageName] + Array(entry.components.dropLast())).joined(separator: " / ")
  }
}
