import SwiftUI

struct SyncCenterView: View {
  @ObservedObject var manager: SyncManager
  let currentURL: URL
  @State private var selection: UUID?
  @State private var draft: SavedSyncProfile?
  @State private var sourceText = ""
  @State private var destinationText = ""
  @State private var pendingInitialBisync: SavedSyncProfile?

  var body: some View {
    NavigationSplitView {
      VStack(spacing: 0) {
        List(selection: $selection) {
          ForEach(manager.profiles) { profile in
            SyncProfileRow(profile: profile, status: manager.statuses[profile.id])
              .tag(profile.id)
              .contextMenu {
                Button("プレビュー") { Task { _ = await manager.preview(profile) } }
                Button("実行") { requestRun(profile, saveFirst: false) }
                Divider()
                Button("削除", role: .destructive) { manager.remove(profile) }
              }
          }
        }
        Divider()
        HStack {
          Button { createProfile() } label: { Label("追加", systemImage: "plus") }
          Spacer()
          Button("削除", role: .destructive) {
            guard let selected = selectedProfile else { return }
            manager.remove(selected)
            selection = manager.profiles.first?.id
          }
          .disabled(selectedProfile == nil)
        }
        .padding(10)
      }
      .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
    } detail: {
      if var draft {
        SyncProfileEditor(
          profile: Binding(get: { draft }, set: { self.draft = $0 }),
          sourceText: $sourceText,
          destinationText: $destinationText,
          currentURL: currentURL,
          status: manager.statuses[draft.id],
          preview: manager.selectedPreview?.profileID == draft.id ? manager.selectedPreview : nil,
          save: saveDraft,
          previewAction: { Task { if let saved = parseDraft() { _ = await manager.preview(saved) } } },
          run: { if let saved = parseDraft() { requestRun(saved, saveFirst: true) } },
          stop: { manager.stop(profileID: draft.id) }
        )
      } else {
        ContentUnavailableView(
          "同期設定を選択",
          systemImage: "arrow.triangle.2.circlepath",
          description: Text("同期前の差分、削除予定、進捗、速度、残り時間を確認できます。")
        )
      }
    }
    .frame(minWidth: 980, minHeight: 650)
    .onAppear {
      selection = selection ?? manager.profiles.first?.id
      loadSelection()
    }
    .onChange(of: selection) { _, _ in loadSelection() }
    .confirmationDialog(
      "初回の双方向同期",
      isPresented: Binding(
        get: { pendingInitialBisync != nil },
        set: { if !$0 { pendingInitialBisync = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("同期元を基準に状態を初期化", role: .destructive) {
        guard let profile = pendingInitialBisync else { return }
        pendingInitialBisync = nil
        manager.run(profile, requiringPreview: true, allowingInitialBisync: true)
      }
      Button("キャンセル", role: .cancel) { pendingInitialBisync = nil }
    } message: {
      Text("双方の現在状態だけでは変更方向を完全には判定できません。差分プレビューを確認し、同期元を基準としてよい場合だけ続行してください。")
    }
    .alert(
      "同期",
      isPresented: Binding(
        get: { manager.errorMessage != nil },
        set: { if !$0 { manager.errorMessage = nil } }
      )
    ) { Button("OK", role: .cancel) {} } message: { Text(manager.errorMessage ?? "") }
  }

  private var selectedProfile: SavedSyncProfile? {
    guard let selection else { return nil }
    return manager.profiles.first { $0.id == selection }
  }

  private func requestRun(_ profile: SavedSyncProfile, saveFirst: Bool) {
    if saveFirst, !manager.save(profile) { return }
    if manager.requiresInitialBisyncConfirmation(profile) {
      Task {
        guard let preview = await manager.preview(profile), preview.canRun else { return }
        pendingInitialBisync = profile
      }
      return
    }
    manager.run(profile)
  }

  private func createProfile() {
    let home = FileManager.default.homeDirectoryForCurrentUser
    var profile = manager.makeProfile(source: currentURL, destination: home)
    profile.name = "新しい同期"
    draft = profile
    sourceText = displayURL(profile.source)
    destinationText = displayURL(profile.destination)
    selection = profile.id
  }

  private func loadSelection() {
    guard let selectedProfile else {
      if draft == nil { draft = nil }
      return
    }
    draft = selectedProfile
    sourceText = displayURL(selectedProfile.source)
    destinationText = displayURL(selectedProfile.destination)
  }

  private func saveDraft() {
    guard let profile = parseDraft() else { return }
    guard manager.save(profile) else { return }
    selection = profile.id
    draft = profile
  }

  private func parseDraft() -> SavedSyncProfile? {
    guard var value = draft,
      let source = parseURL(sourceText),
      let destination = parseURL(destinationText)
    else {
      manager.errorMessage = "同期元と同期先を正しく入力してください。"
      return nil
    }
    value.source = source
    value.destination = destination
    value.clamp()
    return value
  }

  private func parseURL(_ raw: String) -> URL? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("\(NafiURL.remoteScheme)://") { return URL(string: value).map(NafiURL.normalized) }
    let expanded = NSString(string: value).expandingTildeInPath
    return expanded.isEmpty ? nil : URL(fileURLWithPath: expanded).standardizedFileURL
  }

  private func displayURL(_ url: URL) -> String { NafiURL.isRemote(url) ? url.absoluteString : url.path }
}

private struct SyncProfileRow: View {
  let profile: SavedSyncProfile
  let status: SyncRunStatus?

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: profile.mode == .bidirectional ? "arrow.left.arrow.right" : "arrow.right")
        .foregroundStyle(profile.enabled ? Color.accentColor : .secondary)
      VStack(alignment: .leading, spacing: 3) {
        Text(profile.name).lineLimit(1)
        HStack(spacing: 5) {
          Text(profile.mode.label)
          Text("•")
          Text(profile.trigger.label)
          if let status { Text("•"); Text(statusLabel(status.phase)) }
        }
        .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func statusLabel(_ phase: SyncRunPhase) -> String {
    switch phase {
    case .idle: "待機"
    case .previewing: "比較中"
    case .waitingForStability: "安定待ち"
    case .running: "同期中"
    case .verifying: "検証中"
    case .completed: "完了"
    case .failed: "失敗"
    case .cancelled: "取消"
    }
  }
}

private struct SyncProfileEditor: View {
  @Binding var profile: SavedSyncProfile
  @Binding var sourceText: String
  @Binding var destinationText: String
  let currentURL: URL
  let status: SyncRunStatus?
  let preview: SyncPreview?
  let save: () -> Void
  let previewAction: () -> Void
  let run: () -> Void
  let stop: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        HStack {
          TextField("同期名", text: $profile.name).font(.title2.weight(.semibold))
          Toggle("有効", isOn: $profile.enabled).toggleStyle(.switch)
        }

        GroupBox("場所") {
          Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
              Text("同期元")
              TextField("/path または nafi-remote://…", text: $sourceText)
              Button("現在") { sourceText = displayURL(currentURL) }
            }
            GridRow {
              Text("同期先")
              TextField("/path または nafi-remote://…", text: $destinationText)
              Button("現在") { destinationText = displayURL(currentURL) }
            }
          }
          .textFieldStyle(.roundedBorder)
          .padding(.top, 4)
        }

        GroupBox("動作") {
          Form {
            Picker("方式", selection: $profile.mode) {
              ForEach(SyncMode.allCases) { Text($0.label).tag($0) }
            }
            Text(profile.mode.description).font(.caption).foregroundStyle(.secondary)
            Picker("実行", selection: $profile.trigger) {
              ForEach(SyncTrigger.allCases) { Text($0.label).tag($0) }
            }
            LabeledContent("ファイルの安定待ち") {
              TextField("秒", value: $profile.stableForSeconds, format: .number).frame(width: 90)
              Text("秒")
            }
            LabeledContent("大容量ファイル") {
              TextField(
                "MiB",
                value: Binding(
                  get: { Double(profile.largeFileThresholdBytes) / 1_048_576 },
                  set: { profile.largeFileThresholdBytes = Int64(max(1, $0) * 1_048_576) }
                ),
                format: .number
              ).frame(width: 100)
              Text("MiB以上は安定スナップショット")
            }
            LabeledContent("安全照合") {
              TextField(
                "時間",
                value: Binding(
                  get: { profile.fullReconciliationInterval / 3600 },
                  set: { profile.fullReconciliationInterval = max(0.25, $0) * 3600 }
                ),
                format: .number
              ).frame(width: 90)
              Text("時間ごと")
            }
            LabeledContent("変更集約") {
              Stepper("\(profile.incrementalBatchThreshold)件で一括照合", value: $profile.incrementalBatchThreshold, in: 25...10_000, step: 25)
            }
            LabeledContent("同時差分転送") {
              Stepper("\(profile.maxConcurrentIncrementalTransfers)件", value: $profile.maxConcurrentIncrementalTransfers, in: 1...16)
            }
          }
          .formStyle(.grouped)
        }

        GroupBox("削除安全制限") {
          HStack {
            Text("最大")
            TextField("件数", value: $profile.maxDeleteCount, format: .number).frame(width: 90)
            Text("項目、または全体の")
            TextField(
              "%",
              value: Binding(
                get: { profile.maxDeleteRatio * 100 },
                set: { profile.maxDeleteRatio = min(max($0 / 100, 0), 1) }
              ),
              format: .number
            ).frame(width: 80)
            Text("%まで")
          }
        }

        GroupBox("フィルター") {
          VStack(alignment: .leading, spacing: 8) {
            Text("除外（1行1ルール）").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: Binding(
              get: { profile.excludeRules.joined(separator: "\n") },
              set: { profile.excludeRules = $0.components(separatedBy: .newlines) }
            )).frame(minHeight: 90).font(.system(.body, design: .monospaced))
          }
        }

        if let status { SyncStatusView(status: status) }
        if let preview { SyncPreviewSummary(preview: preview) }

        HStack {
          Button("保存", action: save)
          Button("差分をプレビュー", action: previewAction)
          Spacer()
          if status?.phase == .running || status?.phase == .previewing || status?.phase == .verifying {
            Button("停止", role: .destructive, action: stop)
          } else {
            Button("同期を実行", action: run).buttonStyle(.borderedProminent)
          }
        }
      }
      .padding(22)
    }
  }

  private func displayURL(_ url: URL) -> String { NafiURL.isRemote(url) ? url.absoluteString : url.path }
}

private struct SyncStatusView: View {
  let status: SyncRunStatus
  var body: some View {
    GroupBox("進捗") {
      VStack(alignment: .leading, spacing: 8) {
        if let progress = status.progress {
          ProgressView(value: progress.fractionCompleted)
          HStack {
            Text(ByteCountFormatter.string(fromByteCount: progress.bytesTransferred, countStyle: .file))
            if progress.totalBytes > 0 { Text("/ \(ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))") }
            Spacer()
            Text(speed(progress.bytesPerSecond))
            if let eta = progress.estimatedSecondsRemaining, eta.isFinite, eta >= 0 {
              Text("残り \(Duration.seconds(eta).formatted(.time(pattern: .hourMinuteSecond)))")
            }
          }.font(.caption).foregroundStyle(.secondary)
        }
        if let item = status.currentItem { Text(item).font(.caption).lineLimit(1).truncationMode(.middle) }
        if let message = status.message { Text(message).font(.caption).foregroundStyle(status.phase == .failed ? .red : .secondary) }
      }
    }
  }

  private func speed(_ value: Double) -> String {
    guard value > 0 else { return "—" }
    return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file) + "/秒"
  }
}

private struct SyncPreviewSummary: View {
  let preview: SyncPreview
  var body: some View {
    GroupBox("差分プレビュー") {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Label("追加 \(preview.additions)", systemImage: "plus.circle")
          Label("更新 \(preview.updates)", systemImage: "arrow.triangle.2.circlepath")
          Label("削除 \(preview.deletions)", systemImage: "trash")
          Label("競合 \(preview.conflicts)", systemImage: "exclamationmark.triangle")
        }
        if !preview.blockingReasons.isEmpty {
          ForEach(preview.blockingReasons, id: \.self) { Label($0, systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
        }
        if !preview.warnings.isEmpty {
          ForEach(preview.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
        }
        if !preview.items.isEmpty {
          Table(Array(preview.items.prefix(2_000))) {
            TableColumn("操作") { Text($0.action.label) }.width(70)
            TableColumn("パス") { Text($0.path).lineLimit(1) }
            TableColumn("詳細") { Text($0.detail ?? "") }.width(min: 80, ideal: 150)
          }
          .frame(minHeight: 180, idealHeight: 280)
        }
      }
    }
  }
}
