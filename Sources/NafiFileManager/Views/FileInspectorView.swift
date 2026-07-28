import AppKit
import SwiftUI

struct InspectorWindow: View {
  let url: URL
  @State private var item: FileItem?

  var body: some View {
    Group {
      if let item {
        FileInspectorView(item: item)
      } else {
        ProgressView("情報を読み込み中…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .task(id: url) {
      await loadItem()
    }
  }

  private func loadItem() async {
    if NafiURL.isRemote(url) {
      let parent = NafiURL.parent(of: url)
      let items = (try? await UnifiedFileSystemService.contents(of: parent, showHidden: true)) ?? []
      item = items.first(where: { $0.url == url })
    } else {
      item = FileItem.make(from: url)
    }
  }
}

struct FileInspectorView: View {
  @Environment(\.dismiss) private var dismiss
  let item: FileItem

  @State private var details = InspectorDetails.loading
  @State private var folderSize: Int64?
  @State private var applications: [URL] = []
  @State private var selectedApplicationURL: URL?
  @State private var currentDefaultApplicationURL: URL?
  @State private var isApplyingDefaultApplication = false
  @State private var applicationStatus: String?
  @State private var applicationError: String?
  @State private var isChangeAllConfirmationPresented = false

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 14) {
        FileThumbnailView(
          item: item,
          width: 56,
          height: 56,
          contentMode: .fit,
          cornerRadius: 7
        )
        VStack(alignment: .leading, spacing: 4) {
          Text(item.name)
            .font(.title3.weight(.semibold))
            .lineLimit(2)
          Text(item.kindLabel)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(20)
      .background(.bar)

      Form {
        Section("一般") {
          LabeledContent("場所", value: locationLabel)
          LabeledContent("サイズ", value: sizeLabel)
          LabeledContent("作成日", value: date(item.creationDate))
          LabeledContent("更新日", value: date(item.modificationDate))
          LabeledContent("隠し項目", value: item.isHidden ? "はい" : "いいえ")
          LabeledContent("パッケージ", value: item.isPackage ? "はい" : "いいえ")
          LabeledContent(
            "タグ", value: item.tagNames.isEmpty ? "—" : item.tagNames.joined(separator: ", "))
        }

        Section("このアプリケーションで開く") {
          HStack(spacing: 10) {
            Menu {
              ForEach(applications, id: \.self) { applicationURL in
                Button {
                  selectedApplicationURL = applicationURL
                  applicationStatus = nil
                } label: {
                  Label {
                    Text(applicationName(applicationURL))
                  } icon: {
                    Image(nsImage: applicationIcon(applicationURL))
                  }
                }
              }
              Divider()
              Button("その他…") { chooseOtherApplication() }
            } label: {
              HStack(spacing: 8) {
                if let selectedApplicationURL {
                  Image(nsImage: applicationIcon(selectedApplicationURL))
                    .resizable()
                    .frame(width: 20, height: 20)
                  Text(applicationName(selectedApplicationURL))
                    .lineLimit(1)
                } else {
                  Image(systemName: "app.dashed")
                  Text("アプリケーションを選択")
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
              .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: .infinity)

            if isApplyingDefaultApplication {
              ProgressView().controlSize(.small)
            }
          }

          HStack {
            Button("この項目だけ変更") {
              applyDefaultApplicationToItem()
            }
            .disabled(
              NafiURL.isRemote(item.url) || selectedApplicationURL == nil
                || isApplyingDefaultApplication)

            Button(changeAllButtonLabel) {
              isChangeAllConfirmationPresented = true
            }
            .disabled(
              !canChangeAll || selectedApplicationURL == nil || isApplyingDefaultApplication)
          }

          if let currentDefaultApplicationURL {
            LabeledContent(
              "現在の既定",
              value: applicationName(currentDefaultApplicationURL)
            )
          }

          if let applicationStatus {
            Label(applicationStatus, systemImage: "checkmark.circle.fill")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

        }

        Section("共有とアクセス権") {
          LabeledContent("所有者", value: details.ownerName)
          LabeledContent("グループ", value: details.groupName)
          LabeledContent("アクセス権", value: details.permissionLabel)
          if item.url.isFileURL, let posix = details.posixPermissions {
            PermissionEditor(url: item.url, posixPermissions: posix & 0o777)
          }
        }
      }
      .formStyle(.grouped)

      Divider()
      HStack {
        if item.url.isFileURL {
          Button("Finderで表示") { FileSystemService.revealInFinder(item.url) }
        }
        Button("パスをコピー") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(
            NafiURL.isRemote(item.url)
              ? (NafiURL.remotePath(in: item.url) ?? item.url.absoluteString) : item.url.path,
            forType: .string)
        }
        Spacer()
        Button("閉じる") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
      .padding(16)
    }
    .frame(width: 580, height: 650)
    .task(id: item.url) {
      let detailsTask = Task.detached(priority: .userInitiated) {
        item.url.isFileURL ? InspectorDetails.reading(item.url) : .unavailable
      }
      loadApplications()
      if item.isDirectory && !item.isPackage && item.url.isFileURL {
        folderSize = await Task.detached(priority: .userInitiated) {
          FileSystemService.directorySize(at: item.url)
        }.value
      }
      details = await detailsTask.value
    }
    .confirmationDialog(
      changeAllConfirmationTitle,
      isPresented: $isChangeAllConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button(changeAllButtonLabel) { applyDefaultApplicationToMatchingExtension() }
      Button("キャンセル", role: .cancel) {}
    } message: {
      Text("同じ種類のファイルをダブルクリックしたときにも、選択したアプリケーションで開くよう変更します。")
    }
    .alert(
      "既定のアプリケーションを変更できませんでした",
      isPresented: Binding(
        get: { applicationError != nil },
        set: { if !$0 { applicationError = nil } }
      )
    ) {
      Button("OK", role: .cancel) { applicationError = nil }
    } message: {
      Text(applicationError ?? "不明なエラーです。")
    }
  }

  private var locationLabel: String {
    if NafiURL.isRemote(item.url) {
      return NafiURL.remotePath(in: NafiURL.parent(of: item.url)) ?? "/"
    }
    return item.url.deletingLastPathComponent().path
  }

  private var sizeLabel: String {
    if item.isDirectory && !item.isPackage {
      if let folderSize {
        return ByteCountFormatter.string(fromByteCount: folderSize, countStyle: .file)
      }
      return "計算中…"
    }
    return item.sizeLabel
  }

  private var canChangeAll: Bool {
    !item.isDirectory && !item.url.pathExtension.isEmpty
  }

  private var changeAllButtonLabel: String {
    guard canChangeAll else { return "同じ種類すべてに適用" }
    return "すべての .\(item.url.pathExtension.lowercased()) に適用…"
  }

  private var changeAllConfirmationTitle: String {
    "すべての .\(item.url.pathExtension.lowercased()) ファイルを変更しますか？"
  }

  private func date(_ date: Date?) -> String {
    guard let date else { return "—" }
    return date.formatted(date: .long, time: .standard)
  }

  private func applicationName(_ url: URL) -> String {
    url.deletingPathExtension().lastPathComponent
  }

  private func applicationIcon(_ url: URL) -> NSImage {
    NSWorkspace.shared.icon(forFile: url.path)
  }

  private func loadApplications() {
    let service = OpenWithApplicationCache.shared
    let defaultURL = service.defaultApplication(for: item)
    var candidates = service.applications(for: item)
    if let defaultURL, !candidates.contains(defaultURL) {
      candidates.insert(defaultURL, at: 0)
    }
    applications = candidates
    currentDefaultApplicationURL = defaultURL
    selectedApplicationURL = defaultURL ?? candidates.first
  }

  private func chooseOtherApplication() {
    guard let applicationURL = OpenWithApplicationCache.shared.chooseApplication() else { return }
    if !applications.contains(applicationURL) {
      applications.append(applicationURL)
      applications.sort {
        applicationName($0).localizedStandardCompare(applicationName($1)) == .orderedAscending
      }
    }
    selectedApplicationURL = applicationURL
    applicationStatus = nil
  }

  private func applyDefaultApplicationToItem() {
    guard let selectedApplicationURL else { return }
    isApplyingDefaultApplication = true
    applicationStatus = nil
    Task { @MainActor in
      do {
        try await OpenWithApplicationCache.shared.setDefaultApplication(
          selectedApplicationURL,
          forFileAt: item.url
        )
        currentDefaultApplicationURL = selectedApplicationURL
        applicationStatus = "この項目の既定アプリケーションを変更しました。"
      } catch {
        applicationError = error.localizedDescription
      }
      isApplyingDefaultApplication = false
    }
  }

  private func applyDefaultApplicationToMatchingExtension() {
    guard let selectedApplicationURL else { return }
    isApplyingDefaultApplication = true
    applicationStatus = nil
    Task { @MainActor in
      do {
        try await OpenWithApplicationCache.shared.setDefaultApplicationForMatchingExtension(
          selectedApplicationURL,
          fileURL: item.url
        )
        currentDefaultApplicationURL = selectedApplicationURL
        applicationStatus = "同じ種類のファイルすべてへ適用しました。"
      } catch {
        applicationError = error.localizedDescription
      }
      isApplyingDefaultApplication = false
    }
  }
}

private struct InspectorDetails: Sendable {
  let ownerName: String
  let groupName: String
  let posixPermissions: Int?

  var permissionLabel: String {
    guard let posixPermissions else { return "—" }
    return String(format: "%03o", posixPermissions & 0o777)
  }

  static let loading = InspectorDetails(ownerName: "…", groupName: "…", posixPermissions: nil)
  static let unavailable = InspectorDetails(ownerName: "—", groupName: "—", posixPermissions: nil)

  static func reading(_ url: URL) -> InspectorDetails {
    let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
    let owner = attributes[.ownerAccountName] as? String ?? "—"
    let group = attributes[.groupOwnerAccountName] as? String ?? "—"
    let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
    return InspectorDetails(ownerName: owner, groupName: group, posixPermissions: permissions)
  }
}

private struct PermissionTriad: Hashable {
  var read: Bool
  var write: Bool
  var execute: Bool

  init(octalDigit: Int) {
    read = octalDigit & 0o4 != 0
    write = octalDigit & 0o2 != 0
    execute = octalDigit & 0o1 != 0
  }

  var octalDigit: Int {
    (read ? 0o4 : 0) | (write ? 0o2 : 0) | (execute ? 0o1 : 0)
  }
}

private struct PermissionEditor: View {
  let url: URL
  let posixPermissions: Int

  @State private var owner = PermissionTriad(octalDigit: 0)
  @State private var group = PermissionTriad(octalDigit: 0)
  @State private var others = PermissionTriad(octalDigit: 0)
  @State private var isApplying = false
  @State private var status: String?
  @State private var didLoad = false

  var body: some View {
    DisclosureGroup("権限を編集") {
      VStack(alignment: .leading, spacing: 6) {
        triadRow("所有者", $owner)
        triadRow("グループ", $group)
        triadRow("その他", $others)
        HStack {
          Button("適用") { apply() }
            .disabled(isApplying || !hasChanges)
          if isApplying {
            ProgressView().controlSize(.small)
          }
          if let status {
            Text(status).font(.caption).foregroundStyle(.secondary)
          }
        }
        .padding(.top, 4)
      }
      .padding(.top, 4)
    }
    .font(.callout)
    .onAppear {
      guard !didLoad else { return }
      owner = PermissionTriad(octalDigit: (posixPermissions >> 6) & 0o7)
      group = PermissionTriad(octalDigit: (posixPermissions >> 3) & 0o7)
      others = PermissionTriad(octalDigit: posixPermissions & 0o7)
      didLoad = true
    }
  }

  private var currentValue: Int {
    (owner.octalDigit << 6) | (group.octalDigit << 3) | others.octalDigit
  }

  private var hasChanges: Bool {
    currentValue != posixPermissions
  }

  private func triadRow(_ label: String, _ triad: Binding<PermissionTriad>) -> some View {
    HStack {
      Text(label).foregroundStyle(.secondary)
      Spacer()
      Toggle("読み", isOn: triad.read).toggleStyle(.checkbox)
      Toggle("書き", isOn: triad.write).toggleStyle(.checkbox)
      Toggle("実行", isOn: triad.execute).toggleStyle(.checkbox)
    }
  }

  private func apply() {
    isApplying = true
    status = nil
    let target = url
    let value = currentValue
    Task { @MainActor in
      do {
        try FileManager.default.setAttributes(
          [.posixPermissions: NSNumber(value: value)],
          ofItemAtPath: target.path
        )
        status = "権限を変更しました。"
      } catch {
        status = "変更できませんでした: \(error.localizedDescription)"
      }
      isApplying = false
    }
  }
}
