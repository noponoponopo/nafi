import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var appState: AppState
  @AppStorage("Nami.defaultShowHidden") private var defaultShowHidden = false
  @AppStorage("Nami.defaultViewMode") private var defaultViewMode = FileViewMode.list.rawValue

  var body: some View {
    TabView {
      Form {
        Toggle("新しいタブで隠しファイルを表示", isOn: $defaultShowHidden)
          .onChange(of: defaultShowHidden) { _, value in
            for model in appState.workspace.allModels {
              model.showHidden = value
              model.load()
            }
          }

        Picker("新しいタブの表示", selection: $defaultViewMode) {
          ForEach(FileViewMode.allCases) { mode in
            Label(mode.label, systemImage: mode.systemImage).tag(mode.rawValue)
          }
        }
        .onChange(of: defaultViewMode) { _, value in
          if let mode = FileViewMode(rawValue: value) {
            appState.activeModel.viewMode = mode
          }
        }

        Text("起動時は1ペインです。必要なときだけツールバーまたはタブの端ドラッグでペインを追加できます。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .formStyle(.grouped)
      .tabItem { Label("一般", systemImage: "gearshape") }

      VStack(alignment: .leading, spacing: 14) {
        Label("フォルダを汚さない設計", systemImage: "checkmark.shield")
          .font(.headline)
        Text(
          "Namiの表示設定・サーバープロファイル・サイドバー構成は ~/Library/Application Support/Nami に保存します。閲覧したフォルダ内へ .DS_Store や独自メタデータを作成しません。"
        )
        Text("Finder自身や他のアプリが作成する .DS_Store までは抑止しません。")
          .foregroundStyle(.secondary)
        Spacer()
      }
      .padding(24)
      .tabItem { Label("プライバシー", systemImage: "hand.raised") }
    }
    .padding(12)
  }
}
