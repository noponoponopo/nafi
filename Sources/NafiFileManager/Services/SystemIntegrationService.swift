import AppKit
import Foundation
#if canImport(ServiceManagement)
import ServiceManagement
#endif
#if canImport(FileProvider)
import FileProvider
#endif

@MainActor
final class SystemIntegrationService: ObservableObject {
  @Published private(set) var launchesAtLogin = false
  @Published private(set) var shellCommandInstalled = false
  @Published private(set) var rcloneVersion: String?
  @Published private(set) var fileProviderProfileIDs = Set<UUID>()
  private var fileProviderRecords: [UUID: FileProviderDomainRecord] = [:]
  private var fileProviderPollingTask: Task<Void, Never>?
  @Published private(set) var fileProviderStatus = "未構成"
  @Published var errorMessage: String?

  private let shellURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".local/bin/nafi")
  private let fileProviderStoreURL = AppStoragePaths.sharedFile(named: "file-provider-domains.json")
  private let legacyFileProviderStoreURL = AppStoragePaths.file(named: "file-provider-domains.json")
  private let legacyAppGroupStoreURL = AppStoragePaths.legacyAppGroupDirectory
    .appendingPathComponent("file-provider-domains.json")
  private let shellMarker = "# Managed by nafi (app.nafi.filemanager)"

  init() {
    refresh()
    migrateLegacyFileProviderStoreIfNeeded()
    loadFileProviderProfiles()
    startFileProviderPolling()
  }

  deinit { fileProviderPollingTask?.cancel() }

  func refresh() {
    #if canImport(ServiceManagement)
    if #available(macOS 13.0, *) {
      launchesAtLogin = loginService.status == .enabled
    }
    #endif
    shellCommandInstalled = shellCommandIsManaged
    Task {
      do {
        let version = try await RcloneRuntime.shared.version()
        await MainActor.run { self.rcloneVersion = version }
      } catch {
        await MainActor.run { self.rcloneVersion = nil }
      }
    }
  }

  #if canImport(ServiceManagement)
  @available(macOS 13.0, *)
  private var loginService: SMAppService {
    let helper = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Library/LoginItems/NafiBackgroundAgent.app")
    if FileManager.default.fileExists(atPath: helper.path) {
      return SMAppService.loginItem(identifier: "app.nafi.filemanager.background")
    }
    return SMAppService.mainApp
  }
  #endif

  func setLaunchAtLogin(_ enabled: Bool) {
    #if canImport(ServiceManagement)
    guard #available(macOS 13.0, *) else { return }
    do {
      if enabled { try loginService.register() }
      else { try loginService.unregister() }
      refresh()
    } catch {
      errorMessage = "ログイン時起動を変更できません。\n\(error.localizedDescription)"
      refresh()
    }
    #endif
  }

  func installShellCommand() {
    do {
      if FileManager.default.fileExists(atPath: shellURL.path), !shellCommandIsManaged {
        throw CocoaError(.fileWriteFileExists, userInfo: [
          NSLocalizedDescriptionKey: "~/.local/bin/nafiにはNafi以外が作成したファイルがあります。既存ファイルを退避してから再実行してください。"
        ])
      }
      let directory = shellURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let script = #"""
      #!/bin/bash
      # Managed by nafi (app.nafi.filemanager)
      set -euo pipefail

      usage() {
        cat <<'EOF'
      Usage:
        nafi [PATH ...]
        nafi --quick-open
        nafi --sync [NAME_OR_UUID]
        nafi --sync-center
        nafi --drop-stack
        nafi --workspaces
      EOF
      }

      urlencode() {
        local LC_ALL=C value="${1-}" length index char encoded=""
        length=${#value}
        for ((index = 0; index < length; index++)); do
          char=${value:index:1}
          case "$char" in
            [a-zA-Z0-9.~_-]) encoded+="$char" ;;
            *) printf -v char '%%%02X' "'$char"; encoded+="$char" ;;
          esac
        done
        printf '%s' "$encoded"
      }

      case "${1-}" in
        "") /usr/bin/open -b app.nafi.filemanager ;;
        --quick-open) /usr/bin/open 'nafi://quick-open' ;;
        --sync)
          if (( $# >= 2 )); then
            /usr/bin/open "nafi://sync?profile=$(urlencode "$2")"
          else
            /usr/bin/open 'nafi://sync'
          fi
          ;;
        --sync-center) /usr/bin/open 'nafi://sync-center' ;;
        --drop-stack) /usr/bin/open 'nafi://drop-stack' ;;
        --workspaces) /usr/bin/open 'nafi://workspaces' ;;
        --help|-h) usage ;;
        --*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
        *) /usr/bin/open -b app.nafi.filemanager -- "$@" ;;
      esac
      """#
      let temporary = directory.appendingPathComponent(".nafi.\(UUID().uuidString).tmp")
      try Data(script.utf8).write(to: temporary, options: [.atomic])
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
      if FileManager.default.fileExists(atPath: shellURL.path) {
        _ = try FileManager.default.replaceItemAt(shellURL, withItemAt: temporary)
      } else {
        try FileManager.default.moveItem(at: temporary, to: shellURL)
      }
      shellCommandInstalled = true
    } catch {
      errorMessage = "シェルコマンドを追加できません。\n\(error.localizedDescription)"
    }
  }

  func uninstallShellCommand() {
    do {
      guard !FileManager.default.fileExists(atPath: shellURL.path) || shellCommandIsManaged else {
        throw CocoaError(.fileWriteNoPermission, userInfo: [
          NSLocalizedDescriptionKey: "~/.local/bin/nafiはNafiが設置したファイルではないため削除しません。"
        ])
      }
      if FileManager.default.fileExists(atPath: shellURL.path) { try FileManager.default.removeItem(at: shellURL) }
      shellCommandInstalled = false
    } catch {
      errorMessage = "シェルコマンドを削除できません。\n\(error.localizedDescription)"
    }
  }

  private var shellCommandIsManaged: Bool {
    guard FileManager.default.isExecutableFile(atPath: shellURL.path),
      let handle = try? FileHandle(forReadingFrom: shellURL)
    else { return false }
    defer { try? handle.close() }
    let prefix = (try? handle.read(upToCount: 512)) ?? nil
    guard let prefix, let text = String(data: prefix, encoding: .utf8) else { return false }
    return text.contains(shellMarker)
  }

  func setFileProviderEnabled(_ enabled: Bool, profile: ServerProfile) {
    Task {
      do {
        let previous = await MainActor.run { self.fileProviderRecords }
        var updated = previous
        if enabled { updated[profile.id] = FileProviderDomainRecord(profile: profile) }
        else { updated[profile.id] = nil }
        try await MainActor.run { try self.persistFileProviderProfiles(updated) }
        do {
          if enabled { try await addFileProviderDomain(profile) }
          else { try await removeFileProviderDomain(profile) }
        } catch {
          try? await MainActor.run { try self.persistFileProviderProfiles(previous) }
          throw error
        }
        await MainActor.run {
          self.fileProviderRecords = updated
          self.fileProviderProfileIDs = Set(updated.keys)
          self.fileProviderStatus = self.fileProviderProfileIDs.isEmpty ? "未構成" : "\(self.fileProviderProfileIDs.count)接続を公開"
        }
      } catch {
        await MainActor.run {
          self.errorMessage = "File Providerを変更できません。拡張の署名、App Group、File Provider entitlementを確認してください。\n\(error.localizedDescription)"
        }
      }
    }
  }

  var fskitStatus: String {
    guard #available(macOS 15.4, *) else { return "macOS 15.4以降が必要" }
    return NSClassFromString("FSKit.FSFileSystemBase") == nil
      ? "このSDKではネットワークボリューム公開を有効化できません"
      : "対応SDKを検出（File Providerを標準経路として使用）"
  }

  private func migrateLegacyFileProviderStoreIfNeeded() {
    guard !FileManager.default.fileExists(atPath: fileProviderStoreURL.path) else { return }
    let source = [legacyAppGroupStoreURL, legacyFileProviderStoreURL].first {
      FileManager.default.fileExists(atPath: $0.path)
    }
    guard let source else { return }
    do {
      let data = try AppStoragePaths.readRegularFile(
        at: source,
        maximumBytes: 4 * 1_024 * 1_024
      )
      try data.write(to: fileProviderStoreURL, options: [.atomic, .completeFileProtectionUnlessOpen])
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: fileProviderStoreURL.path
      )
    } catch {
      errorMessage = "旧File Provider設定を拡張領域へ移行できません。\n\(error.localizedDescription)"
    }
  }

  private func loadFileProviderProfiles() {
    guard FileManager.default.fileExists(atPath: fileProviderStoreURL.path) else { return }
    do {
      let data = try AppStoragePaths.readRegularFile(
        at: fileProviderStoreURL,
        maximumBytes: 4 * 1_024 * 1_024
      )
      if let records = try? JSONDecoder().decode([FileProviderDomainRecord].self, from: data),
        records.count <= 10_000
      {
        var unique: [UUID: FileProviderDomainRecord] = [:]
        for record in records where unique[record.id] == nil { unique[record.id] = record }
        fileProviderRecords = unique
        fileProviderProfileIDs = Set(unique.keys)
      } else if let ids = try? JSONDecoder().decode(Set<UUID>.self, from: data), ids.count <= 10_000 {
        fileProviderProfileIDs = ids
      } else {
        throw CocoaError(.fileReadCorruptFile)
      }
    } catch {
      AppStoragePaths.quarantineCorruptFile(at: fileProviderStoreURL)
      errorMessage = "File Provider設定が破損していたため隔離しました。\n\(error.localizedDescription)"
      fileProviderRecords = [:]
      fileProviderProfileIDs = []
    }
    fileProviderStatus = fileProviderProfileIDs.isEmpty ? "未構成" : "\(fileProviderProfileIDs.count)接続を公開"
  }

  func reconcileFileProviderProfiles(_ profiles: [ServerProfile]) {
    let byID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
    let removed = fileProviderRecords.values.filter { byID[$0.id] == nil }
    var changed = false
    var domainMetadataUpdates: [ServerProfile] = []
    for id in fileProviderProfileIDs {
      guard let profile = byID[id] else { continue }
      let previous = fileProviderRecords[id]
      let updated = FileProviderDomainRecord(profile: profile)
      if previous?.displayName != updated.displayName
        || previous?.fs != updated.fs
        || previous?.rootPath != updated.rootPath
        || previous?.configurationRevision != updated.configurationRevision
      {
        fileProviderRecords[id] = updated
        changed = true
        if previous?.displayName != updated.displayName { domainMetadataUpdates.append(profile) }
      }
    }
    if changed {
      do { try persistFileProviderProfiles(fileProviderRecords) }
      catch { errorMessage = "File Provider設定を更新できません。\n\(error.localizedDescription)" }
    }

    for profile in domainMetadataUpdates {
      Task {
        do { try await addFileProviderDomain(profile) }
        catch {
          await MainActor.run {
            self.errorMessage = "File Providerの表示名を更新できません。\n\(error.localizedDescription)"
          }
        }
      }
    }

    for record in removed {
      Task {
        do {
          try await removeFileProviderDomain(id: record.id, displayName: record.displayName)
          await MainActor.run {
            self.fileProviderRecords[record.id] = nil
            self.fileProviderProfileIDs.remove(record.id)
            try? self.persistFileProviderProfiles(self.fileProviderRecords)
            self.fileProviderStatus = self.fileProviderProfileIDs.isEmpty
              ? "未構成" : "\(self.fileProviderProfileIDs.count)接続を公開"
          }
        } catch {
          await MainActor.run {
            self.errorMessage = "削除済み接続のFile Providerドメインを解除できません。\n\(error.localizedDescription)"
          }
        }
      }
    }
  }

  private func persistFileProviderProfiles(
    _ values: [UUID: FileProviderDomainRecord]
  ) throws {
    guard values.count <= 10_000 else { throw CocoaError(.fileWriteOutOfSpace) }
    let records = values.values.sorted {
      $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
    }
    let data = try JSONEncoder().encode(records)
    guard data.count <= 4 * 1_024 * 1_024 else { throw CocoaError(.fileWriteOutOfSpace) }
    // The extension's own container is the single source of truth. The containing
    // app is unsandboxed, so both processes can use one atomically replaced file.
    try data.write(to: fileProviderStoreURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: fileProviderStoreURL.path
    )
  }

  private func startFileProviderPolling() {
    guard fileProviderPollingTask == nil else { return }
    fileProviderPollingTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
      while !Task.isCancelled {
        guard let self else { return }
        let ids = await MainActor.run { Array(self.fileProviderProfileIDs) }
        for id in ids {
          guard !Task.isCancelled else { return }
          await FileProviderChangeNotifier.signal(profileID: id)
        }
        try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
      }
    }
  }

  private func domainIdentifier(_ profile: ServerProfile) -> String {
    "app.nafi.filemanager.remote.\(profile.id.uuidString.lowercased())"
  }

  private func addFileProviderDomain(_ profile: ServerProfile) async throws {
    #if canImport(FileProvider)
    let domain = NSFileProviderDomain(
      identifier: NSFileProviderDomainIdentifier(rawValue: domainIdentifier(profile)),
      displayName: profile.name
    )
    let existing = try await registeredFileProviderDomains().first {
      $0.identifier == domain.identifier
    }
    if existing?.displayName == domain.displayName { return }
    // File Provider treats adding the same identifier as a domain metadata
    // update. This is also the standard way to update domain state.
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      NSFileProviderManager.add(domain) { error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
      }
    }
    #else
    throw CocoaError(.featureUnsupported)
    #endif
  }

  private func removeFileProviderDomain(_ profile: ServerProfile) async throws {
    try await removeFileProviderDomain(id: profile.id, displayName: profile.name)
  }

  private func removeFileProviderDomain(id: UUID, displayName: String) async throws {
    #if canImport(FileProvider)
    let identifier = NSFileProviderDomainIdentifier(
      rawValue: "app.nafi.filemanager.remote.\(id.uuidString.lowercased())"
    )
    guard let domain = try await registeredFileProviderDomains().first(where: {
      $0.identifier == identifier
    }) else { return }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      NSFileProviderManager.remove(domain) { error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
      }
    }
    #else
    throw CocoaError(.featureUnsupported)
    #endif
  }

  #if canImport(FileProvider)
  private func registeredFileProviderDomains() async throws -> [NSFileProviderDomain] {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<[NSFileProviderDomain], Error>) in
      NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: domains) }
      }
    }
  }
  #endif
}
