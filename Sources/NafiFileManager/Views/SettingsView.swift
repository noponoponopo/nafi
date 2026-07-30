import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var appState: AppState
  @AppStorage("Nafi.defaultShowHidden") private var defaultShowHidden = false
  @AppStorage("Nafi.defaultViewMode") private var defaultViewMode = FileViewMode.list.rawValue
  @AppStorage(ThumbnailPreferenceKey.localImages) private var localImageThumbnails = true
  @AppStorage(ThumbnailPreferenceKey.localVideos) private var localVideoThumbnails = true
  @AppStorage(ThumbnailPreferenceKey.remoteImages) private var remoteImageThumbnails = false
  @AppStorage(ThumbnailPreferenceKey.remoteVideos) private var remoteVideoThumbnails = false

  var body: some View {
    TabView {
      generalSettings
        .tabItem { Label("一般", systemImage: "gearshape") }

      DefaultFileManagerSettingsView(service: appState.defaultFileManager)
        .tabItem { Label("標準ファイラー", systemImage: "folder.badge.gearshape") }

      ICloudSettingsView(service: appState.cloudStorage) {
        appState.openICloudDrive()
      }
      .tabItem { Label("iCloud", systemImage: "icloud") }

      TransferQueueSettingsView(
        model: appState.transferQueueModel,
        serverManager: appState.serverManager
      )
      .tabItem { Label("転送", systemImage: "arrow.left.arrow.right") }

      IntegrationSettingsView(
        service: appState.systemIntegration,
        serverManager: appState.serverManager,
        quickOpenChanged: appState.configureGlobalQuickOpen
      )
      .tabItem { Label("統合", systemImage: "puzzlepiece.extension") }

      privacySettings
        .tabItem { Label("プライバシー", systemImage: "hand.raised") }
    }
    .padding(12)
  }

  private var generalSettings: some View {
    Form {
      Section("表示") {
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
      }

      Section("サムネイル") {
        Toggle("ローカル画像のサムネイルを表示", isOn: $localImageThumbnails)
        Toggle("ローカル動画のサムネイルを表示", isOn: $localVideoThumbnails)
        Toggle("サーバー上の画像のサムネイルを表示", isOn: $remoteImageThumbnails)
        Toggle("サーバー上の動画のサムネイルを表示", isOn: $remoteVideoThumbnails)

        Text("サーバー上の項目は、サムネイル生成のため一時的にダウンロードします。特に動画は通信量と表示時間が増える場合があります。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section {
        Text("起動時は1ペインです。必要なときだけツールバーまたはタブの端ドラッグでペインを追加できます。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private var privacySettings: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("フォルダを汚さない設計", systemImage: "checkmark.shield")
        .font(.headline)
      Text(
        "nafiの表示設定・サーバープロファイル・サイドバー構成は ~/Library/Application Support/nafi に保存します。閲覧したフォルダ内へ .DS_Store や独自メタデータを作成しません。"
      )
      Text("Finder自身や他のアプリが作成する .DS_Store までは抑止しません。")
        .foregroundStyle(.secondary)
      Divider()
      Label("接続用の秘密情報", systemImage: "key")
        .font(.headline)
      Text("サーバーのパスワード、秘密鍵のパスフレーズ、S3シークレットとセッショントークンはmacOS Keychainに保存します。")
      Spacer()
    }
    .padding(24)
  }
}

private struct DefaultFileManagerSettingsView: View {
  @ObservedObject var service: DefaultFileManagerService
  @AppStorage("Nafi.externalOpenBehavior") private var externalOpenBehavior =
    ExternalOpenBehavior.newTab.rawValue

  private var isChanging: Bool {
    if case .changing = service.operationState { return true }
    return false
  }

  var body: some View {
    Form {
      Section("標準ファイラー") {
        DefaultHandlerStatusRow(
          title: "通常のフォルダ",
          systemImage: "folder",
          isEnabled: service.folderIsHandledByNafi
        )
        DefaultHandlerStatusRow(
          title: "ディレクトリ互換",
          systemImage: "folder.fill",
          isEnabled: service.directoryIsHandledByNafi
        )
        DefaultHandlerStatusRow(
          title: "ボリューム",
          systemImage: "externaldrive",
          isEnabled: service.volumeIsHandledByNafi
        )
        DefaultHandlerStatusRow(
          title: "マウントポイント",
          systemImage: "externaldrive.badge.checkmark",
          isEnabled: service.mountPointIsHandledByNafi
        )

        HStack {
          Button("nafiを標準に設定") {
            Task { await service.makeNafiDefault() }
          }
          .disabled(isChanging || service.isFullyDefault)

          Button("Finderに戻す") {
            Task { await service.restoreFinder() }
          }
          .disabled(isChanging)

          Spacer()
          Button {
            service.refresh()
          } label: {
            Label("状態を更新", systemImage: "arrow.clockwise")
          }
          .disabled(isChanging)
        }

        operationStatus
      }

      Section("外部からフォルダやファイルを開いたとき") {
        Picker("開く場所", selection: $externalOpenBehavior) {
          ForEach(ExternalOpenBehavior.allCases) { behavior in
            Text(behavior.label).tag(behavior.rawValue)
          }
        }
      }
    }
    .formStyle(.grouped)
    .task { service.refresh() }
  }

  @ViewBuilder
  private var operationStatus: some View {
    switch service.operationState {
    case .idle:
      EmptyView()
    case .changing:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("macOSへ変更を要求しています…")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    case .succeeded(let message):
      Label(message, systemImage: "checkmark.circle.fill")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .partial(let message):
      Label(message, systemImage: "exclamationmark.circle.fill")
        .font(.caption)
        .foregroundStyle(.orange)
    case .failed(let message):
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

private struct DefaultHandlerStatusRow: View {
  let title: String
  let systemImage: String
  let isEnabled: Bool

  var body: some View {
    HStack {
      Label(title, systemImage: systemImage)
      Spacer()
      Label(
        isEnabled ? "nafi" : "別のアプリ",
        systemImage: isEnabled ? "checkmark.circle.fill" : "circle"
      )
      .font(.caption)
      .foregroundStyle(isEnabled ? Color.accentColor : .secondary)
    }
  }
}

private struct ICloudSettingsView: View {
  @ObservedObject var service: CloudStorageService
  let open: () -> Void

  var body: some View {
    Form {
      Section("iCloud Drive") {
        HStack(alignment: .top, spacing: 12) {
          Image(systemName: service.isAvailable ? "icloud.fill" : "icloud.slash")
            .font(.title2)
            .foregroundStyle(service.isAvailable ? Color.accentColor : .secondary)
          VStack(alignment: .leading, spacing: 4) {
            Text(service.isAvailable ? "利用可能" : "場所を確認できません")
              .font(.headline)
            Text(service.statusText)
              .font(.caption)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
        }

        HStack {
          Button("iCloud Driveを開く", action: open)
            .disabled(!service.isAvailable)
          Button(service.isAvailable ? "場所を選び直す…" : "場所を選択…") {
            service.chooseICloudDriveLocation()
          }
          Button("再検出") { service.refresh() }
          if service.usesUserSelectedLocation {
            Button("自動検出に戻す") { service.forgetSelectedLocation() }
          }
        }
      }
    }
    .formStyle(.grouped)
    .task { service.refresh() }
    .alert(
      "iCloud Drive",
      isPresented: Binding(
        get: { service.errorMessage != nil },
        set: { if !$0 { service.errorMessage = nil } }
      )
    ) {
      Button("OK", role: .cancel) { service.errorMessage = nil }
    } message: {
      Text(service.errorMessage ?? "")
    }
  }
}


private struct TransferQueueSettingsView: View {
  @ObservedObject var model: TransferQueueModel
  @ObservedObject var serverManager: ServerManager

  private var hasFinishedJobs: Bool {
    model.jobs.contains { [.completed, .failed, .cancelled].contains($0.state) }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("転送キュー")
            .font(.headline)
          Text("転送は順番に実行され、未完了の処理はアプリ再起動後も復元されます。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          Task { await model.refresh() }
        } label: {
          Label("更新", systemImage: "arrow.clockwise")
        }
        .disabled(model.isRefreshing)

        Button("完了・失敗履歴を削除") {
          model.removeFinished()
        }
        .disabled(!hasFinishedJobs)
      }
      .padding(16)

      Divider()

      if model.jobs.isEmpty {
        ContentUnavailableView(
          "転送はありません",
          systemImage: "arrow.left.arrow.right",
          description: Text("コピーまたは移動を開始すると、ここで進行状況を確認できます。")
        )
      } else {
        List(model.jobs) { job in
          TransferQueueJobRow(
            job: job,
            destination: displayPath(for: job.destination),
            pause: { model.pause(job) },
            resume: { model.resume(job) },
            cancel: { model.cancel(job) },
            remove: { model.remove(job) }
          )
          .padding(.vertical, 4)
        }
        .listStyle(.inset)
      }
    }
    .task { await model.refresh() }
    .alert(
      "転送キュー",
      isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { if !$0 { model.errorMessage = nil } }
      )
    ) {
      Button("OK", role: .cancel) { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "")
    }
  }

  private func displayPath(for url: URL) -> String {
    guard let id = NafiURL.profileID(in: url),
      let profile = serverManager.profiles.first(where: { $0.id == id })
    else {
      return NafiURL.displayPath(url)
    }
    return NafiURL.displayPath(url, profile: profile)
  }
}

private struct TransferQueueJobRow: View {
  let job: TransferQueue.Job
  let destination: String
  let pause: () -> Void
  let resume: () -> Void
  let cancel: () -> Void
  let remove: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Label(job.move ? "移動" : "コピー", systemImage: job.move ? "arrow.right" : "doc.on.doc")
          .font(.headline)
        Text(stateLabel)
          .font(.caption.weight(.semibold))
          .foregroundStyle(stateColor)
        Spacer()
        Text(job.updatedAt, style: .relative)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Text("\(job.sources.count)項目 → \(destination)")
        .font(.subheadline)
        .lineLimit(2)
        .truncationMode(.middle)
        .help(destination)

      ProgressView(value: job.fractionCompleted) {
        Text("\(job.completedSourceCount) / \(job.totalSourceCount) 項目")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let error = job.errorMessage, !error.isEmpty {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }

      HStack {
        Text("試行回数: \(job.attemptCount)")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        controls
      }
    }
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private var controls: some View {
    switch job.state {
    case .queued, .running:
      Button("一時停止", action: pause)
      Button("キャンセル", role: .destructive, action: cancel)
    case .paused:
      Button("再開", action: resume)
      Button("キャンセル", role: .destructive, action: cancel)
    case .failed:
      Button("再試行", action: resume)
      Button("削除", role: .destructive, action: remove)
    case .completed, .cancelled:
      Button("削除", role: .destructive, action: remove)
    }
  }

  private var stateLabel: String {
    switch job.state {
    case .queued: "待機中"
    case .running: "転送中"
    case .paused: "一時停止"
    case .completed: "完了"
    case .failed: "失敗"
    case .cancelled: "キャンセル済み"
    }
  }

  private var stateColor: Color {
    switch job.state {
    case .running: .accentColor
    case .failed: .red
    case .completed: .green
    case .paused, .queued, .cancelled: .secondary
    }
  }
}

private struct IntegrationSettingsView: View {
  @ObservedObject var service: SystemIntegrationService
  @ObservedObject var serverManager: ServerManager
  let quickOpenChanged: () -> Void
  @AppStorage("Nafi.globalQuickOpen") private var globalQuickOpen = true

  var body: some View {
    Form {
      Section("常駐とショートカット") {
        Toggle(
          "ログイン時にバックグラウンドで起動",
          isOn: Binding(
            get: { service.launchesAtLogin },
            set: { service.setLaunchAtLogin($0) }
          )
        )
        Toggle("⌘⌥SpaceでQuick Open", isOn: $globalQuickOpen)
          .onChange(of: globalQuickOpen) { _, _ in quickOpenChanged() }
        LabeledContent("rclone") {
          Text(service.rcloneVersion ?? "未検出").foregroundStyle(.secondary)
        }
      }

      Section("シェル") {
        Text("`nafi .`で開くほか、`--quick-open`、`--sync 名前`、`--sync-center`、`--drop-stack`、`--workspaces`を利用できます。~/.local/binには識別マーカー付きの標準openラッパーだけを設置し、既存の同名ファイルは上書きしません。")
          .font(.caption).foregroundStyle(.secondary)
        HStack {
          if service.shellCommandInstalled {
            Button("nafiコマンドを削除", role: .destructive) { service.uninstallShellCommand() }
          } else {
            Button("nafiコマンドを追加") { service.installShellCommand() }
          }
          Spacer()
          Text(service.shellCommandInstalled ? "~/.local/bin/nafi" : "未導入")
            .font(.caption).foregroundStyle(.secondary)
        }
      }

      Section("File Provider") {
        Text("有効にした接続をFinder、開く／保存パネル、他のmacOSアプリへ公開します。nafiのリモート通信は常駐rcloneを経由します。")
          .font(.caption).foregroundStyle(.secondary)
        if serverManager.profiles.isEmpty {
          Text("先にリモート接続を追加してください。").foregroundStyle(.secondary)
        } else {
          ForEach(serverManager.profiles.filter { ![.nfs, .afp].contains($0.kind) }) { profile in
            Toggle(
              isOn: Binding(
                get: { service.fileProviderProfileIDs.contains(profile.id) },
                set: { service.setFileProviderEnabled($0, profile: profile) }
              )
            ) {
              Label(profile.name, systemImage: profile.kind.systemImage)
            }
          }
        }
        LabeledContent("状態", value: service.fileProviderStatus)
      }
    }
    .formStyle(.grouped)
    .task { service.refresh() }
    .alert(
      "システム統合",
      isPresented: Binding(
        get: { service.errorMessage != nil },
        set: { if !$0 { service.errorMessage = nil } }
      )
    ) { Button("OK", role: .cancel) {} } message: { Text(service.errorMessage ?? "") }
  }
}
