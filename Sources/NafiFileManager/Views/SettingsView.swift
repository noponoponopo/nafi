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

      Section("対応内容") {
        Text(
          "iCloud Drive内のフォルダを通常のフォルダと同じように閲覧、作成、名前変更、移動、コピーできます。未ダウンロードのテキストファイルをクイックエディットするときは、macOSへダウンロードを要求してから読み書きします。"
        )
        Text(
          "Appleは他社アプリへiCloud Drive全体を返す専用APIを提供していないため、nafiはmacOS上のiCloud Drive保存場所を自動検出し、必要な場合だけユーザーが選んだ場所へのアクセス権を保存します。"
        )
        .foregroundStyle(.secondary)
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
