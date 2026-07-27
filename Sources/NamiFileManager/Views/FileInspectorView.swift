import AppKit
import SwiftUI

struct FileInspectorView: View {
  @Environment(\.dismiss) private var dismiss
  let item: FileItem

  @State private var details = InspectorDetails.loading
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
        Image(nsImage: item.icon)
          .resizable()
          .interpolation(.high)
          .frame(width: 56, height: 56)
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
          LabeledContent("場所", value: item.url.deletingLastPathComponent().path)
          LabeledContent("サイズ", value: item.sizeLabel)
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
            .disabled(selectedApplicationURL == nil || isApplyingDefaultApplication)

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
        }
      }
      .formStyle(.grouped)

      Divider()
      HStack {
        Button("Finderで表示") { FileSystemService.revealInFinder(item.url) }
        Button("パスをコピー") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(item.url.path, forType: .string)
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
        InspectorDetails.reading(item.url)
      }
      loadApplications()
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
  let permissionLabel: String

  static let loading = InspectorDetails(ownerName: "…", groupName: "…", permissionLabel: "…")

  static func reading(_ url: URL) -> InspectorDetails {
    let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
    let owner = attributes[.ownerAccountName] as? String ?? "—"
    let group = attributes[.groupOwnerAccountName] as? String ?? "—"
    let permissions: String
    if let number = attributes[.posixPermissions] as? NSNumber {
      permissions = String(format: "%03o", number.intValue & 0o777)
    } else {
      permissions = "—"
    }
    return InspectorDetails(ownerName: owner, groupName: group, permissionLabel: permissions)
  }
}
