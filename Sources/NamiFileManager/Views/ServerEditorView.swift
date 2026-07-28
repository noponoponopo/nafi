import AppKit
import SwiftUI

struct ServerEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject private var serverManager: ServerManager
  @State private var draft: ServerProfile
  @State private var password = ""
  @State private var keyPassphrase = ""
  @State private var sessionToken = ""
  @State private var connectAfterSave = false
  @State private var errorMessage: String?

  init(serverManager: ServerManager, profile: ServerProfile? = nil) {
    _serverManager = ObservedObject(wrappedValue: serverManager)
    _draft = State(initialValue: profile ?? .blank)
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("サーバー接続")
            .font(.title2.weight(.semibold))
          Text("接続設定はnafi、パスワード・鍵パスフレーズ・S3シークレットはKeychainに保存します。")
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
            let oldDefault = defaultPort(for: oldValue)
            if draft.port == oldDefault { draft.port = defaultPort(for: newValue) }
            if newValue == .s3 {
              draft.useTLS = true
              if draft.s3Region.isEmpty { draft.s3Region = "auto" }
            }
          }

          if draft.kind == .s3 {
            s3DestinationSection
          } else {
            TextField("ホスト", text: $draft.host, prompt: Text("nas.example.local"))
            HStack {
              TextField("共有名 / パス", text: $draft.path, prompt: Text("share/folder"))
              TextField("ポート", value: $draft.port, format: .number)
                .frame(width: 90)
            }
          }
        }

        switch draft.kind {
        case .sftp:
          sftpAuthenticationSection
        case .s3:
          s3AuthenticationSection
          s3CompatibilitySection
        default:
          Section("認証") {
            TextField("ユーザー名", text: $draft.username)
            SecureField("パスワード", text: $password)
          }
        }

        if draft.kind == .ftp { ftpSecuritySection }

        Section("自動化") {
          Toggle("nafi起動時に自動接続", isOn: $draft.autoConnect)
          if draft.kind == .webdav {
            Toggle("TLSを使用", isOn: $draft.useTLS)
          }
          if [.smb, .webdav, .nfs, .afp].contains(draft.kind) {
            TextField(
              "ローカルマウント先（任意）", text: $draft.localMountPath,
              prompt: Text("/Volumes/Server"))
            Text("SMB・WebDAV・NFS・AFPはnafiからmacOSのNetFSへ直接接続します。Finderなどの外部アプリは開きません。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          if [.sftp, .ftp, .s3].contains(draft.kind) {
            Text("この接続は通常のnafiペイン／タブへ別ルートとして追加され、ローカルや他サーバーと相互コピー・移動できます。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Toggle("保存後すぐ接続", isOn: $connectAfterSave)
        }
      }
      .formStyle(.grouped)
      .frame(maxHeight: .infinity)

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
    .frame(minWidth: 560, idealWidth: 620, minHeight: 480, idealHeight: 640)
    .onAppear {
      password = serverManager.password(for: draft)
      keyPassphrase = serverManager.keyPassphrase(for: draft)
      sessionToken = serverManager.sessionToken(for: draft)
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

  @ViewBuilder
  private var s3DestinationSection: some View {
    TextField(
      "S3互換エンドポイント",
      text: $draft.host,
      prompt: Text("<ACCOUNT_ID>.r2.cloudflarestorage.com")
    )
    HStack {
      TextField("バケット", text: $draft.s3Bucket, prompt: Text("my-bucket"))
      TextField("開始プレフィックス（任意）", text: $draft.path, prompt: Text("folder/subfolder"))
    }
    HStack {
      Toggle("HTTPS", isOn: $draft.useTLS)
        .onChange(of: draft.useTLS) { oldValue, newValue in
          let oldPort = oldValue ? 443 : 80
          if draft.port == oldPort { draft.port = newValue ? 443 : 80 }
        }
      Spacer()
      TextField("ポート", value: $draft.port, format: .number)
        .frame(width: 90)
    }
  }

  @ViewBuilder
  private var sftpAuthenticationSection: some View {
    Section("SFTP認証") {
      TextField("ユーザー名", text: $draft.username)
      Picker("認証方式", selection: $draft.sftpAuthentication) {
        ForEach(ServerProfile.SFTPAuthentication.allCases) { method in
          Text(method.label).tag(method)
        }
      }

      switch draft.sftpAuthentication {
      case .password:
        SecureField("パスワード", text: $password)
      case .privateKey:
        HStack {
          TextField("秘密鍵ファイル", text: $draft.privateKeyPath, prompt: Text("~/.ssh/id_ed25519"))
          Button("選択…") { choosePrivateKey() }
        }
        SecureField("鍵のパスフレーズ（未設定なら空欄）", text: $keyPassphrase)
        Text("macOS標準OpenSSHで読み込めるRSA・Ed25519・ECDSA・FIDO鍵、OpenSSH／PEM／PKCS#8形式に対応します。暗号化鍵も利用できます。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private var s3AuthenticationSection: some View {
    Section("S3認証") {
      Toggle("匿名／公開バケットとして接続", isOn: $draft.s3Anonymous)
      if !draft.s3Anonymous {
        TextField("アクセスキーID", text: $draft.username)
        SecureField("シークレットアクセスキー", text: $password)
        SecureField("セッショントークン（任意）", text: $sessionToken)
      }
      Text("Cloudflare R2ではR2 APIトークンから作成したアクセスキーIDとシークレットを入力します。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var s3CompatibilitySection: some View {
    Section("S3互換設定") {
      HStack {
        TextField("リージョン", text: $draft.s3Region, prompt: Text("auto"))
        Button("R2向け設定") {
          draft.useTLS = true
          draft.port = 443
          draft.s3Region = "auto"
          draft.s3AddressingStyle = .pathStyle
          draft.verifyTLSCertificate = true
        }
      }
      Picker("アドレス形式", selection: $draft.s3AddressingStyle) {
        ForEach(ServerProfile.S3AddressingStyle.allCases) { style in
          Text(style.label).tag(style)
        }
      }
      Toggle("サーバー証明書を検証", isOn: $draft.verifyTLSCertificate)
      if !draft.verifyTLSCertificate {
        Label("自己署名証明書向けです。通信相手のなりすましを検出できなくなります。", systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.orange)
      }
      Text("R2はリージョン auto とパス形式が推奨です。MinIO・Ceph・NASなど、署名V4対応の任意S3互換エンドポイントも利用できます。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var ftpSecuritySection: some View {
    Section("FTPセキュリティ") {
      Picker("暗号化", selection: $draft.ftpEncryption) {
        ForEach(ServerProfile.FTPEncryption.allCases) { encryption in
          Text(encryption.label).tag(encryption)
        }
      }
      .onChange(of: draft.ftpEncryption) { oldValue, newValue in
        if draft.port == oldValue.defaultPort { draft.port = newValue.defaultPort }
      }

      if draft.ftpEncryption.usesTLS {
        Toggle("サーバー証明書を検証", isOn: $draft.verifyTLSCertificate)
        if !draft.verifyTLSCertificate {
          Label("証明書を検証しない接続は、なりすましを検出できません。", systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
        }
        Text("明示FTPSではAUTH TLS、暗黙FTPSでは接続直後からTLSを使用します。制御接続とデータ接続の両方を暗号化します。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var isValid: Bool {
    let basics =
      !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && (1...65535).contains(draft.port)
    guard basics else { return false }
    if draft.kind == .sftp, draft.sftpAuthentication == .privateKey {
      return !draft.privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    if draft.kind == .s3 {
      let bucketOK = !draft.s3Bucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      let credentialsOK =
        draft.s3Anonymous
        || (!draft.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && !password.isEmpty)
      return bucketOK && credentialsOK
    }
    return true
  }

  private func defaultPort(for kind: ServerProfile.Kind) -> Int {
    switch kind {
    case .ftp: draft.ftpEncryption.defaultPort
    case .s3: draft.useTLS ? 443 : 80
    default: kind.defaultPort
    }
  }

  private func choosePrivateKey() {
    let panel = NSOpenPanel()
    panel.title = "SFTP秘密鍵を選択"
    panel.prompt = "選択"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    if !draft.privateKeyPath.isEmpty {
      let expanded = NSString(string: draft.privateKeyPath).expandingTildeInPath
      panel.directoryURL = URL(fileURLWithPath: expanded).deletingLastPathComponent()
    } else {
      panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        ".ssh", isDirectory: true)
    }
    if panel.runModal() == .OK, let url = panel.url {
      let home = FileManager.default.homeDirectoryForCurrentUser.path
      draft.privateKeyPath =
        url.path.hasPrefix(home + "/")
        ? "~/" + String(url.path.dropFirst(home.count + 1))
        : url.path
    }
  }

  private func save() {
    do {
      try serverManager.save(
        profile: draft,
        password: password,
        keyPassphrase: keyPassphrase,
        sessionToken: sessionToken
      )
      if connectAfterSave {
        Task { await serverManager.connect(draft) }
      }
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
