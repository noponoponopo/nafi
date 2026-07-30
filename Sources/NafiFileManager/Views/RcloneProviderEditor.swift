import SwiftUI

struct RcloneProviderEditor: View {
  let profileID: UUID
  @Binding var backend: String
  @Binding var parametersJSON: String
  @Binding var secretJSON: String
  let onConfigurationCompleted: @MainActor () throws -> Void

  @State private var provider: RcloneProviderDefinition?
  @State private var providers: [RcloneProviderDefinition] = []
  @State private var values: [String: JSONValue] = [:]
  @State private var secrets: [String: JSONValue] = [:]
  @State private var showAdvanced = false
  @State private var useSharedDrive = false
  @State private var isLoading = false
  @State private var isConfiguring = false
  @State private var question: RcloneProviderOption?
  @State private var questionState = ""
  @State private var answer = ""
  @State private var status: String?
  @State private var errorMessage: String?
  @State private var configurationTask: Task<Void, Never>?

  var body: some View {
    Group {
      if isLoading {
        HStack {
          ProgressView().controlSize(.small)
          Text("設定項目を読み込み中")
        }
      } else if provider != nil {
        Label(
          "Nafiはrcloneで接続します。認証画面にも「rclone」と表示されます",
          systemImage: "person.badge.key"
        )

        ForEach(visibleOptions) { option in
          optionControl(option)
        }

        if backend == "drive" || !detailOptions.isEmpty {
          DisclosureGroup("詳細設定", isExpanded: $showAdvanced) {
            if backend == "drive" {
              Toggle("共有ドライブを使用", isOn: $useSharedDrive)
            }
            ForEach(showAdvanced ? detailOptions : []) { option in
              optionControl(option)
            }
          }
        }

        if let question {
          configQuestionControl(question)
        } else {
          Button(isConfiguring ? "接続設定中" : "アカウントを設定") {
            startConfiguration()
          }
          .disabled(isConfiguring || !requiredOptionsArePresent)
        }

        if isConfiguring {
          HStack {
            ProgressView().controlSize(.small)
            Button("認証をキャンセル", role: .cancel) { cancelConfiguration() }
          }
        }
        if let status { Label(status, systemImage: "checkmark.circle.fill") }
      } else {
        Picker("サービス", selection: $backend) {
          Text("選択してください").tag("")
          ForEach(providers.sorted(by: { $0.description < $1.description })) { provider in
            Text(provider.description).tag(provider.name)
          }
        }
      }
    }
    .task(id: backend) { await loadProvider() }
    .onChange(of: parametersJSON) { _, newValue in
      let decoded = Self.decodeObject(newValue)
      if decoded != values { values = decoded }
    }
    .onChange(of: secretJSON) { _, newValue in
      let decoded = Self.decodeObject(newValue)
      if decoded != secrets { secrets = decoded }
    }
    .onChange(of: useSharedDrive) { _, enabled in
      if !enabled, values["team_drive"] != nil {
        values["team_drive"] = nil
        persistJSON()
      }
    }
    .onDisappear { cancelConfiguration() }
    .alert(
      "接続設定を完了できません",
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

  private var visibleOptions: [RcloneProviderOption] {
    provider?.options.filter { option in
      option.hide == 0 && optionApplies(option) && isEssential(option)
    } ?? []
  }

  private var detailOptions: [RcloneProviderOption] {
    return provider?.options.filter { option in
      option.hide == 0 && optionApplies(option) && !isEssential(option)
    } ?? []
  }

  private func isEssential(_ option: RcloneProviderOption) -> Bool {
    option.required && option.defaultText.isEmpty
  }

  private var requiredOptionsArePresent: Bool {
    visibleOptions.allSatisfy { option in
      guard option.required, option.defaultText.isEmpty else { return true }
      return !value(for: option).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  private func optionApplies(_ option: RcloneProviderOption) -> Bool {
    guard let requiredProvider = option.provider, !requiredProvider.isEmpty else { return true }
    return value(named: "provider") == requiredProvider
  }

  @ViewBuilder
  private func optionControl(_ option: RcloneProviderOption) -> some View {
    let label = Self.label(for: option.name)
    if option.type == "bool" {
      Toggle(label, isOn: boolBinding(for: option))
    } else if !option.examples.isEmpty, option.exclusive {
      Picker(label, selection: stringBinding(for: option)) {
        if !option.required { Text("指定なし").tag("") }
        ForEach(option.examples) { example in
          Text(Self.exampleLabel(example)).tag(example.value)
        }
      }
    } else if Self.concealsValue(option) {
      SecureField(label, text: stringBinding(for: option))
    } else {
      TextField(label, text: stringBinding(for: option))
    }
  }

  @ViewBuilder
  private func configQuestionControl(_ option: RcloneProviderOption) -> some View {
    if option.type == "bool" {
      Toggle(Self.label(for: option.name), isOn: Binding(
        get: { answer == "true" },
        set: { answer = $0 ? "true" : "false" }
      ))
    } else if !option.examples.isEmpty {
      Picker(Self.label(for: option.name), selection: $answer) {
        ForEach(option.examples) { example in
          Text(Self.exampleLabel(example)).tag(example.value)
        }
      }
    } else if Self.concealsValue(option) {
      SecureField(Self.label(for: option.name), text: $answer)
    } else {
      TextField(Self.label(for: option.name), text: $answer)
    }
    Button("続ける") { continueConfiguration() }
      .disabled(isConfiguring || (option.required && answer.isEmpty))
  }

  private func stringBinding(for option: RcloneProviderOption) -> Binding<String> {
    Binding(
      get: { value(for: option) },
      set: { setValue($0, for: option) }
    )
  }

  private func boolBinding(for option: RcloneProviderOption) -> Binding<Bool> {
    Binding(
      get: { value(for: option).lowercased() == "true" },
      set: { setValue($0 ? "true" : "false", for: option) }
    )
  }

  private func value(for option: RcloneProviderOption) -> String {
    value(named: option.name) ?? option.defaultText
  }

  private func value(named name: String) -> String? {
    if let stored = Self.text(from: secrets[name] ?? values[name]) { return stored }
    return provider?.options.first(where: { $0.name == name })?.defaultText
  }

  private func setValue(_ text: String, for option: RcloneProviderOption) {
    if option.isPassword || option.sensitive {
      secrets[option.name] = text.isEmpty ? nil : .string(text)
    } else {
      values[option.name] = text.isEmpty ? nil : .string(text)
    }
    persistJSON()
    status = nil
  }

  @MainActor
  private func loadProvider() async {
    isLoading = true
    status = nil
    question = nil
    values = Self.decodeObject(parametersJSON)
    secrets = Self.decodeObject(secretJSON)
    useSharedDrive = Self.text(from: values["team_drive"])?.isEmpty == false
    do {
      let catalog = try await RcloneRuntime.shared.providerCatalog()
      providers = catalog.providers
      provider = catalog.providers.first { $0.name == backend }
    } catch {
      provider = nil
      errorMessage = error.localizedDescription
    }
    isLoading = false
  }

  private func startConfiguration() {
    configurationTask?.cancel()
    isConfiguring = true
    status = nil
    configurationTask = Task {
      do {
        let response = try await RcloneRuntime.shared.beginProviderConfiguration(
          profileID: profileID,
          backend: backend,
          parameters: mergedParameters
        )
        try await handle(response)
      } catch {
        if !Task.isCancelled { errorMessage = error.localizedDescription }
      }
      if !Task.isCancelled { isConfiguring = false }
      configurationTask = nil
    }
  }

  private func continueConfiguration() {
    let state = questionState
    let result = answer
    configurationTask?.cancel()
    isConfiguring = true
    configurationTask = Task {
      do {
        let response = try await RcloneRuntime.shared.continueProviderConfiguration(
          profileID: profileID,
          backend: backend,
          parameters: mergedParameters,
          state: state,
          result: result
        )
        try await handle(response)
      } catch {
        if !Task.isCancelled { errorMessage = error.localizedDescription }
      }
      if !Task.isCancelled { isConfiguring = false }
      configurationTask = nil
    }
  }

  private func cancelConfiguration() {
    guard configurationTask != nil || isConfiguring else { return }
    configurationTask?.cancel()
    configurationTask = nil
    isConfiguring = false
    question = nil
    questionState = ""
    answer = ""
    status = nil
    Task { try? await RcloneRuntime.shared.restart() }
  }

  @MainActor
  private func handle(_ response: RcloneConfigResponse) async throws {
    guard response.error.isEmpty else {
      throw RcloneRuntimeError.remoteConfiguration(response.error)
    }
    if let next = response.option {
      if let automaticAnswer = Self.automaticAnswer(
        for: next,
        useSharedDrive: useSharedDrive
      ) {
        let continued = try await RcloneRuntime.shared.continueProviderConfiguration(
          profileID: profileID,
          backend: backend,
          parameters: mergedParameters,
          state: response.state,
          result: automaticAnswer
        )
        try await handle(continued)
        return
      }
      question = next
      questionState = response.state
      answer = next.defaultText
      return
    }

    let generated = try await RcloneRuntime.shared.providerConfiguration(profileID: profileID)
    let sensitiveNames = Set(provider?.options.filter { $0.isPassword || $0.sensitive }.map(\.name) ?? [])
    for (key, value) in generated where key != "type" {
      if sensitiveNames.contains(key) {
        if secrets[key] == nil { secrets[key] = value }
      } else {
        values[key] = value
      }
    }
    persistJSON()
    try onConfigurationCompleted()
    question = nil
    answer = ""
    status = "アカウント設定済み"
  }

  private var mergedParameters: [String: JSONValue] {
    values.merging(secrets) { _, secret in secret }
  }

  private func persistJSON() {
    let publicText = Self.encodeObject(values)
    let secretText = secrets.isEmpty ? "" : Self.encodeObject(secrets)
    if parametersJSON != publicText { parametersJSON = publicText }
    if secretJSON != secretText { secretJSON = secretText }
  }

  private static func decodeObject(_ text: String) -> [String: JSONValue] {
    guard let data = text.data(using: .utf8),
      let object = try? JSONDecoder().decode([String: JSONValue].self, from: data)
    else { return [:] }
    return object
  }

  private static func encodeObject(_ object: [String: JSONValue]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(object) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
  }

  private static func text(from value: JSONValue?) -> String? {
    switch value {
    case .string(let text): text
    case .bool(let value): value ? "true" : "false"
    case .integer(let value): String(value)
    case .double(let value): String(value)
    case .null, .array, .object, nil: nil
    }
  }

  private static func exampleLabel(_ example: RcloneProviderOption.Example) -> String {
    let firstLine = example.help.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    return firstLine.isEmpty ? example.value : firstLine
  }

  static func automaticAnswer(
    for option: RcloneProviderOption,
    useSharedDrive: Bool = false
  ) -> String? {
    if option.name == "config_is_local" { return "true" }
    if option.name == "config_change_team_drive" { return useSharedDrive ? "true" : "false" }
    if !option.defaultText.isEmpty || !option.required { return option.defaultText }
    return nil
  }

  private static func label(for name: String) -> String {
    labels[name] ?? name.replacingOccurrences(of: "_", with: " ").capitalized
  }

  private static func concealsValue(_ option: RcloneProviderOption) -> Bool {
    if option.isPassword { return true }
    let name = option.name.lowercased()
    return name == "key" || name.contains("password") || name.contains("passphrase")
      || name.contains("secret") || name.contains("token") || name.contains("credential")
  }

  private static let labels: [String: String] = [
    "account": "アカウント",
    "access_key_id": "アクセスキーID",
    "client_id": "クライアントID",
    "client_secret": "クライアントシークレット",
    "endpoint": "エンドポイント",
    "key": "アプリキー",
    "key_id": "キーID",
    "pass": "パスワード",
    "provider": "サービス提供元",
    "region": "リージョン",
    "root_folder_id": "ルートフォルダID",
    "scope": "アクセス範囲",
    "secret_access_key": "シークレットアクセスキー",
    "service_account_file": "サービスアカウントファイル",
    "tenant": "テナントID",
    "token": "認証トークン",
    "url": "接続URL",
    "user": "ユーザー名",
    "config_is_local": "このMacのブラウザで認証",
    "config_token": "認証結果",
  ]
}
