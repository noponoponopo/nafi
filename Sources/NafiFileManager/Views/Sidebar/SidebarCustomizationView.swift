import SwiftUI

struct SidebarCustomizationView: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var model: SidebarModel

  var body: some View {
    VStack(spacing: 0) {
      SidebarCustomizationHeader { dismiss() }
      Divider()
      SidebarCustomizationForm(model: model)
      Divider()
      HStack {
        Button("初期状態に戻す") { model.reset() }
        Spacer()
      }
      .padding(16)
    }
    .frame(width: 520, height: 530)
  }
}

private struct SidebarCustomizationHeader: View {
  let dismiss: () -> Void

  var body: some View {
    HStack {
      Text("サイドバーを編集").font(.title3.weight(.semibold))
      Spacer()
      Button("完了", action: dismiss).keyboardShortcut(.defaultAction)
    }
    .padding(16)
  }
}

private struct SidebarCustomizationForm: View {
  @ObservedObject var model: SidebarModel

  var body: some View {
    Form {
      Section("表示するセクション") {
        Toggle("よく使う項目", isOn: $model.showsFavorites)
        Toggle("iCloud", isOn: $model.showsICloud)
        Toggle("ボリューム", isOn: $model.showsVolumes)
        Toggle("サーバー", isOn: $model.showsServers)
      }

      Section("よく使う項目 — ハンドルをドラッグして並べ替え") {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(model.favorites) { favorite in
              SidebarCustomizationRow(favorite: favorite, model: model)
                .modifier(SidebarReorderDropModifier(model: model, beforeID: favorite.id))
                .modifier(
                  SidebarReorderEndDropOverlay(
                    model: model,
                    isEnabled: favorite.id == model.favorites.last?.id
                  )
                )
            }
          }
          .padding(.vertical, 4)
        }
        .frame(minHeight: 210, maxHeight: 250)
        .background(
          Color(nsColor: .controlBackgroundColor),
          in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 0.5)
        }
      }
    }
    .formStyle(.grouped)
  }
}

private struct SidebarCustomizationRow: View {
  let favorite: SidebarFavorite
  @ObservedObject var model: SidebarModel

  var body: some View {
    HStack(spacing: 9) {
      Image(systemName: "line.3.horizontal")
        .foregroundStyle(.tertiary)
        .frame(width: 20, height: 28)
        .contentShape(Rectangle())
        .onDrag {
          DragPayloadProvider.sidebarFavoriteProvider(for: favorite.id)
        }
        .help("ドラッグして並べ替え")

      Image(systemName: favorite.systemImage).frame(width: 18)
      TextField(
        "名前",
        text: Binding(
          get: { favorite.title },
          set: { model.rename(favorite, to: $0) }
        )
      )
      .textFieldStyle(.plain)
      Spacer(minLength: 8)
      if !favorite.isBuiltIn {
        Button(role: .destructive) {
          model.remove(favorite)
        } label: {
          Image(systemName: "minus.circle")
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 10)
    .frame(maxWidth: .infinity, minHeight: 36)
    .contentShape(Rectangle())
    .overlay(alignment: .bottom) {
      Divider().padding(.leading, 48)
    }
  }
}
