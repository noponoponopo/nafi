import SwiftUI

struct WorkspaceLibraryView: View {
  @ObservedObject var library: WorkspaceLibrary
  @ObservedObject var workspace: WorkspaceModel
  let restore: (WorkspaceSnapshot) -> Void
  @State private var name = ""
  @State private var selection: UUID?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("ワークスペース").font(.title3.weight(.semibold))
        Spacer()
        Button("完了", action: { dismiss() }).keyboardShortcut(.defaultAction)
      }
      .padding(16)
      Divider()
      HStack {
        TextField("ワークスペース名", text: $name)
          .textFieldStyle(.roundedBorder)
        Button("現在の状態を保存") {
          library.saveNamed(name: name, workspace: workspace)
          name = ""
        }
        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      .padding(16)
      Divider()
      if library.named.isEmpty {
        ContentUnavailableView(
          "保存済みワークスペースはありません",
          systemImage: "rectangle.3.group",
          description: Text("ペイン構成、場所、表示、検索、履歴をまとめて保存します。")
        )
      } else {
        List(library.named, selection: $selection) { snapshot in
          HStack {
            VStack(alignment: .leading, spacing: 3) {
              Text(snapshot.name)
              Text("\(snapshot.panes.count)ペイン • \(snapshot.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("開く") {
              restore(snapshot)
              dismiss()
            }
          }
          .tag(snapshot.id)
        }
      }
      Divider()
      HStack {
        Text("標準のmacOSウインドウタブごとに、独立したワークスペースを保持します。")
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("選択を削除", role: .destructive) {
          guard let selection, let item = library.named.first(where: { $0.id == selection }) else { return }
          library.remove(item)
          self.selection = nil
        }
        .disabled(selection == nil)
      }
      .padding(16)
    }
    .frame(minWidth: 680, minHeight: 460)
    .alert(
      "ワークスペース",
      isPresented: Binding(
        get: { library.errorMessage != nil },
        set: { if !$0 { library.errorMessage = nil } }
      )
    ) { Button("OK", role: .cancel) {} } message: { Text(library.errorMessage ?? "") }
  }
}
