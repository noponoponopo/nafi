import AppKit
import SwiftUI

private struct ServerConnectionOption: Identifiable, Hashable {
  let id: String
  let label: String
  let kind: ServerProfile.Kind
  let rcloneBackend: String?

  static let standard: [ServerConnectionOption] = [
    option(.smb), option(.webdav), option(.sftp), option(.ftp), option(.s3),
    option(.nfs), option(.afp),
  ]
  static let cloud: [ServerConnectionOption] = [
    rclone("Google Drive", "drive"),
    rclone("Microsoft OneDrive", "onedrive"),
    rclone("Dropbox", "dropbox"),
    rclone("Box", "box"),
    rclone("pCloud", "pcloud"),
    rclone("Proton Drive", "protondrive"),
    rclone("iCloud Drive / Photos", "iclouddrive"),
    rclone("Google Photos", "google photos"),
    rclone("MEGA", "mega"),
    rclone("Backblaze B2", "b2"),
    rclone("Microsoft Azure Blob Storage", "azureblob"),
    rclone("Microsoft Azure Files", "azurefiles"),
    rclone("Google Cloud Storage", "google cloud storage"),
    rclone("Oracle Cloud Object Storage", "oracleobjectstorage"),
    rclone("OpenStack Swift", "swift"),
    rclone("Storj", "storj"),
    rclone("Koofr", "koofr"),
    rclone("Jottacloud", "jottacloud"),
    rclone("Filen", "filen"),
    rclone("Internxt Drive", "internxt"),
    rclone("Yandex Disk", "yandex"),
  ]
  static let custom = ServerConnectionOption(
    id: "rclone:custom",
    label: "その他の接続先",
    kind: .rclone,
    rcloneBackend: nil
  )
  static let all = standard + cloud + [custom]

  static func selectionID(for profile: ServerProfile) -> String {
    guard profile.kind == .rclone else { return "kind:\(profile.kind.rawValue)" }
    return cloud.first(where: { $0.rcloneBackend == profile.rcloneBackend })?.id ?? custom.id
  }

  private static func option(_ kind: ServerProfile.Kind) -> ServerConnectionOption {
    ServerConnectionOption(id: "kind:\(kind.rawValue)", label: kind.label, kind: kind, rcloneBackend: nil)
  }

  private static func rclone(_ label: String, _ backend: String) -> ServerConnectionOption {
    ServerConnectionOption(id: "rclone:\(backend)", label: label, kind: .rclone, rcloneBackend: backend)
  }
}

struct ServerEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject private var serverManager: ServerManager
  @State private var draft: ServerProfile
  @State private var password = ""
  @State private var keyPassphrase = ""
  @State private var sessionToken = ""
  @State private var connectAfterSave = false
  @State private var errorMessage: String?
  @State private var pendingHostKeyScan: SSHHostKeyScan?
  @State private var hostKeyStatus: String?
  @State private var isCheckingHostKey = false
  @State private var connectionOptionID: String

  init(serverManager: ServerManager, profile: ServerProfile? = nil) {
    let initialProfile = profile ?? .blank
    _serverManager = ObservedObject(wrappedValue: serverManager)
    _draft = State(initialValue: initialProfile)
    _connectionOptionID = State(
      initialValue: ServerConnectionOption.selectionID(for: initialProfile)
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("サーバー接続")
            .font(.title2.weight(.semibold))
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
          Picker("種類", selection: $connectionOptionID) {
            Section("サーバー") {
              ForEach(ServerConnectionOption.standard) { option in
                Label(option.label, systemImage: option.kind.systemImage).tag(option.id)
              }
            }
            Section("クラウドストレージ") {
              ForEach(ServerConnectionOption.cloud) { option in
                Label(option.label, systemImage: option.kind.systemImage).tag(option.id)
              }
            }
            Divider()
            Label(
              ServerConnectionOption.custom.label,
              systemImage: ServerProfile.Kind.rclone.systemImage
            ).tag(ServerConnectionOption.custom.id)
          }
          .onChange(of: connectionOptionID) { _, newValue in applyConnectionOption(newValue) }

          if draft.kind == .s3 {
            s3DestinationSection
          } else if draft.kind == .rclone {
            TextField("開始パス（任意）", text: $draft.path, prompt: Text("folder/subfolder"))
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
          sftpHostKeySection
        case .s3:
          s3AuthenticationSection
          s3CompatibilitySection
        case .rclone:
          rcloneConfigurationSection
        default:
          Section("認証") {
            TextField("ユーザー名", text: $draft.username)
            SecureField("パスワード", text: $password)
          }
        }

        if draft.kind == .ftp { ftpSecuritySection }

        transferPolicySection

        Section("自動化") {
          Toggle("nafi起動時に自動接続", isOn: $draft.autoConnect)
          if draft.kind == .webdav {
            Toggle("TLSを使用", isOn: $draft.useTLS)
          }
          if [.nfs, .afp].contains(draft.kind) {
            TextField(
              "ローカルマウント先（任意）", text: $draft.localMountPath,
              prompt: Text("/Volumes/Server"))
          }
          Toggle("保存後すぐ接続", isOn: $connectAfterSave)
        }
      }
      .formStyle(.grouped)
      .frame(maxHeight: .infinity)

      Divider()
      HStack {
        Text(connectionSummary)
          .font(.caption.monospaced())
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
    .onChange(of: draft.host) { _, _ in
      pendingHostKeyScan = nil
      hostKeyStatus = nil
    }
    .onChange(of: draft.port) { _, _ in
      pendingHostKeyScan = nil
      hostKeyStatus = nil
    }
    .onAppear {
      // Read only the secrets this connection type actually uses. This avoids
      // unnecessary Keychain access prompts when editing a profile.
      switch draft.kind {
      case .sftp:
        switch draft.sftpAuthentication {
        case .password:
          password = serverManager.password(for: draft)
        case .privateKey:
          keyPassphrase = serverManager.keyPassphrase(for: draft)
        case .sshAgent:
          break
        }
      case .s3:
        if !draft.s3Anonymous {
          password = serverManager.password(for: draft)
          sessionToken = serverManager.sessionToken(for: draft)
        }
      case .ftp, .smb, .webdav, .nfs, .afp, .rclone:
        password = serverManager.password(for: draft)
      }
      if draft.kind == .sftp { refreshHostKeyStatus() }
    }
    .alert(
      "操作を完了できません",
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
  private var rcloneConfigurationSection: some View {
    Section("アカウント") {
      RcloneProviderEditor(
        profileID: draft.id,
        backend: $draft.rcloneBackend,
        parametersJSON: $draft.rcloneParametersJSON,
        secretJSON: $password,
        onConfigurationCompleted: persistRcloneConfiguration
      )
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
          TextField("秘密鍵ファイル", text: $draft.privateKeyPath, prompt: Text("~/.ssh/id_rsa"))
          Button("選択…") { choosePrivateKey() }
        }
        SecureField("PEM鍵のパスフレーズ（未設定なら空欄）", text: $keyPassphrase)
      case .sshAgent:
        HStack {
          TextField("使用する鍵（任意）", text: $draft.privateKeyPath, prompt: Text("~/.ssh/id_ed25519"))
          Button("選択…") { choosePrivateKey() }
        }
      }

      Picker("リモートshell", selection: $draft.sftpShellType) {
        ForEach(ServerProfile.SFTPShellType.allCases) { value in
          Text(value.label).tag(value)
        }
      }
    }
  }

  @ViewBuilder
  private var sftpHostKeySection: some View {
    Section("SFTPホストキー") {
      if let scan = pendingHostKeyScan {
        ForEach(scan.keys) { key in
          VStack(alignment: .leading, spacing: 3) {
            Text(key.algorithm)
              .font(.caption.weight(.semibold))
            Text(key.fingerprint)
              .font(.caption.monospaced())
              .textSelection(.enabled)
          }
        }
        HStack {
          Button("確認した鍵を信頼") { trustPendingHostKeys() }
            .buttonStyle(.borderedProminent)
        }
      }

      HStack {
        Button(pendingHostKeyScan == nil ? "鍵指紋を取得" : "再取得") {
          scanHostKeys()
        }
        .disabled(!canCheckHostKey || isCheckingHostKey)

        Button("登録済みキーを削除", role: .destructive) {
          removeTrustedHostKeys()
        }
        .disabled(!canCheckHostKey || isCheckingHostKey)

        if isCheckingHostKey { ProgressView().controlSize(.small) }
        Spacer()
        if let hostKeyStatus {
          Text(hostKeyStatus)
        }
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
    }
  }

  @ViewBuilder
  private var transferPolicySection: some View {
    Section("転送ポリシー") {
      HStack {
        Stepper("並列転送: \(draft.transferPolicy.parallelTransfers)", value: $draft.transferPolicy.parallelTransfers, in: 1...32)
        Stepper("並列確認: \(draft.transferPolicy.parallelChecks)", value: $draft.transferPolicy.parallelChecks, in: 1...64)
      }
      TextField("帯域上限", text: $draft.transferPolicy.bandwidthLimit, prompt: Text("off / 20M / 10M:2M"))
      Picker("完了検証", selection: $draft.transferPolicy.verification) {
        ForEach(TransferVerificationMode.allCases) { mode in
          Text(mode.label).tag(mode)
        }
      }
      HStack {
        Stepper("再試行: \(draft.transferPolicy.retryCount)", value: $draft.transferPolicy.retryCount, in: 0...20)
        Stepper("低水準再試行: \(draft.transferPolicy.lowLevelRetryCount)", value: $draft.transferPolicy.lowLevelRetryCount, in: 0...100)
      }
      Toggle("空フォルダを保持", isOn: $draft.transferPolicy.preserveEmptyDirectories)
      Toggle("可能ならサーバー側コピーを使用", isOn: $draft.transferPolicy.useServerSideCopy)
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
      }
    }
  }

  private var canCheckHostKey: Bool {
    !draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && (1...65535).contains(draft.port)
  }

  private func refreshHostKeyStatus() {
    guard canCheckHostKey else {
      hostKeyStatus = nil
      return
    }
    let host = draft.host
    let port = draft.port
    Task {
      do {
        let trusted = try await SSHHostKeyService.shared.isTrusted(host: host, port: port)
        guard draft.host == host, draft.port == port else { return }
        hostKeyStatus = trusted ? "登録済み" : "未登録"
      } catch {
        guard draft.host == host, draft.port == port else { return }
        hostKeyStatus = "状態を確認できません"
      }
    }
  }

  private func scanHostKeys() {
    guard canCheckHostKey else { return }
    let host = draft.host
    let port = draft.port
    isCheckingHostKey = true
    pendingHostKeyScan = nil
    hostKeyStatus = "取得中…"
    Task {
      defer { isCheckingHostKey = false }
      do {
        let scan = try await SSHHostKeyService.shared.scan(host: host, port: port)
        guard draft.host == host, draft.port == port else { return }
        pendingHostKeyScan = scan
        hostKeyStatus = "照合待ち"
      } catch {
        guard draft.host == host, draft.port == port else { return }
        hostKeyStatus = nil
        errorMessage = error.localizedDescription
      }
    }
  }

  private func trustPendingHostKeys() {
    guard let scan = pendingHostKeyScan else { return }
    isCheckingHostKey = true
    Task {
      defer { isCheckingHostKey = false }
      do {
        try await SSHHostKeyService.shared.trust(scan)
        guard (try? SSHHostKeyService.validatedHost(draft.host)) == scan.host,
          draft.port == scan.port
        else { return }
        pendingHostKeyScan = nil
        hostKeyStatus = "登録済み"
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func removeTrustedHostKeys() {
    guard canCheckHostKey else { return }
    let host = draft.host
    let port = draft.port
    isCheckingHostKey = true
    Task {
      defer { isCheckingHostKey = false }
      do {
        try await SSHHostKeyService.shared.removeTrustedKeys(host: host, port: port)
        guard draft.host == host, draft.port == port else { return }
        pendingHostKeyScan = nil
        hostKeyStatus = "未登録"
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private var isValid: Bool {
    let named = !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    if draft.kind == .rclone {
      let backend = draft.rcloneBackend.trimmingCharacters(in: .whitespacesAndNewlines)
      guard named, !backend.isEmpty,
        (try? JSONSerialization.jsonObject(with: Data(draft.rcloneParametersJSON.utf8))) is [String: Any]
      else { return false }
      let secret = password.trimmingCharacters(in: .whitespacesAndNewlines)
      return secret.isEmpty || ((try? JSONSerialization.jsonObject(with: Data(secret.utf8))) is [String: Any])
    }
    let basics = named
      && !draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && (1...65535).contains(draft.port)
    guard basics else { return false }
    if draft.kind == .sftp {
      guard !draft.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return false
      }
      if draft.sftpAuthentication == .privateKey {
        return !draft.privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
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

  private var connectionSummary: String {
    guard draft.kind == .rclone else { return draft.endpointDescription }
    return ServerConnectionOption.all.first(where: { $0.id == connectionOptionID })?.label
      ?? "その他の接続先"
  }

  private func applyConnectionOption(_ optionID: String) {
    guard let option = ServerConnectionOption.all.first(where: { $0.id == optionID }) else {
      return
    }
    let oldKind = draft.kind
    let oldBackend = draft.rcloneBackend
    let oldDefault = defaultPort(for: oldKind)
    draft.kind = option.kind
    if let backend = option.rcloneBackend {
      draft.rcloneBackend = backend
      if oldKind == .rclone, oldBackend != backend {
        draft.rcloneParametersJSON = "{}"
        password = ""
      }
    } else if option.id == ServerConnectionOption.custom.id {
      draft.rcloneBackend = ""
      draft.rcloneParametersJSON = "{}"
      password = ""
    }
    if draft.port == oldDefault { draft.port = defaultPort(for: option.kind) }
    if option.kind == .s3 {
      draft.useTLS = true
      if draft.s3Region.isEmpty { draft.s3Region = "auto" }
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
    draft.transferPolicy.clamp()
    do {
      try serverManager.save(
        profile: draft,
        password: password,
        keyPassphrase: keyPassphrase,
        sessionToken: sessionToken
      )
      if connectAfterSave {
        let savedProfile = serverManager.profiles.first(where: { $0.id == draft.id }) ?? draft
        Task { await serverManager.connect(savedProfile) }
      }
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func persistRcloneConfiguration() throws {
    draft.transferPolicy.clamp()
    try serverManager.save(
      profile: draft,
      password: password,
      keyPassphrase: "",
      sessionToken: ""
    )
    if let saved = serverManager.profiles.first(where: { $0.id == draft.id }) {
      draft = saved
    }
  }
}
