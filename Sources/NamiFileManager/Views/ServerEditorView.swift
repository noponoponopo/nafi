import SwiftUI

struct ServerEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject private var serverManager: ServerManager
  @State private var draft: ServerProfile
  @State private var password = ""
  @State private var connectAfterSave = false
  @State private var errorMessage: String?

  init(serverManager: ServerManager, profile: ServerProfile?) {
    _serverManager = ObservedObject(wrappedValue: serverManager)
    _draft = State(initialValue: profile ?? .blank)
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("サーバー接続")
            .font(.title2.weight(.semibold))
          Text("接続情報はアプリ設定、パスワードはKeychainに保存します。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Image(systemName: draft.kind.systemImage)
          .font(.system(size: 34))
          .symbolRenderingMode(.hierarchical)
      }
      .padding(20)
      .background(.ultraThinMaterial)

      Form {
        Section("接続先") {
          TextField("表示名", text: $draft.name)
          Picker("種類", selection: $draft.kind) {
            ForEach(ServerProfile.Kind.allCases) { kind in
              Label(kind.label, systemImage: kind.systemImage).tag(kind)
            }
          }
          .onChange(of: draft.kind) { oldValue, newValue in
            if draft.port == oldValue.defaultPort {
              draft.port = newValue.defaultPort
            }
          }
          TextField("ホスト", text: $draft.host, prompt: Text("nas.example.local"))
          HStack {
            TextField("共有名 / パス", text: $draft.path, prompt: Text("share/folder"))
            TextField("ポート", value: $draft.port, format: .number)
              .frame(width: 90)
          }
        }

        Section("認証") {
          TextField("ユーザー名", text: $draft.username)
          SecureField("パスワード", text: $password)
          if draft.kind == .sftp {
            Text("完全自動接続にはSSH鍵認証とsshfsを推奨します。パスワードをコマンド引数へ渡すことはありません。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        Section("自動化") {
          Toggle("Nami起動時に自動接続", isOn: $draft.autoConnect)
          if draft.kind == .webdav {
            Toggle("TLSを使用", isOn: $draft.useTLS)
          }
          if draft.kind == .sftp {
            TextField(
              "ローカルマウント先（任意）", text: $draft.localMountPath, prompt: Text("~/Nami Mounts/Server"))
          }
          Toggle("保存後すぐ接続", isOn: $connectAfterSave)
        }
      }
      .formStyle(.grouped)

      Divider()
      HStack {
        Text(draft.endpointDescription)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer()
        Button("キャンセル") { dismiss() }
        Button("保存") { save() }
          .keyboardShortcut(.defaultAction)
          .disabled(!isValid)
      }
      .padding(16)
    }
    .frame(width: 560, height: 610)
    .onAppear {
      password = serverManager.password(for: draft)
    }
    .alert(
      "保存できません",
      isPresented: Binding(
        get: { errorMessage != nil },
        set: { if !$0 { errorMessage = nil } }
      )
    ) {
      Button("OK") { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
  }

  private var isValid: Bool {
    !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && (1...65535).contains(draft.port)
  }

  private func save() {
    do {
      try serverManager.save(profile: draft, password: password)
      if connectAfterSave {
        Task { await serverManager.connect(draft) }
      }
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
