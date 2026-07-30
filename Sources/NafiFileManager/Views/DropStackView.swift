import SwiftUI

struct DropStackView: View {
  @ObservedObject var model: DropStackModel
  let destination: URL
  @State private var selection = Set<UUID>()

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Drop Stack").font(.headline)
          Text("複数の場所から集め、最後にまとめて転送します。元の項目は実行まで変更しません。")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button("選択を削除") { model.remove(selection) }.disabled(selection.isEmpty)
        Button("すべて消去", role: .destructive) { model.clear() }.disabled(model.entries.isEmpty)
      }
      .padding(16)
      Divider()
      if model.entries.isEmpty {
        ContentUnavailableView(
          "Drop Stackは空です",
          systemImage: "tray",
          description: Text("ファイルを選択してクイック操作から追加してください。")
        )
      } else {
        List(model.entries, selection: $selection) { entry in
          HStack(spacing: 10) {
            Image(systemName: "doc")
            VStack(alignment: .leading, spacing: 2) {
              Text(entry.originalURL.lastPathComponent).lineLimit(1)
              Text(NafiURL.displayPath(entry.originalURL))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(entry.addedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
          }
          .tag(entry.id)
        }
      }
      Divider()
      HStack {
        Text("転送先: \(NafiURL.displayPath(destination))")
          .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        Spacer()
        Button("ここへコピー") { model.enqueueTransfer(to: destination, move: false) }
          .disabled(model.entries.isEmpty)
        Button("ここへ移動") { model.enqueueTransfer(to: destination, move: true) }
          .disabled(model.entries.isEmpty)
      }
      .padding(16)
    }
    .frame(minWidth: 680, minHeight: 440)
    .alert(
      "Drop Stack",
      isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { if !$0 { model.errorMessage = nil } }
      )
    ) { Button("OK", role: .cancel) {} } message: { Text(model.errorMessage ?? "") }
  }
}
