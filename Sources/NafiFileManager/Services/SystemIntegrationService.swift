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
  @Published private(set) var fileProviderStoreUsable = true
  private var fileProviderRecords: [UUID: FileProviderDomainRecord] = [:]
  private var attemptedLegacyDomainRecovery = false
  @Published private(set) var fileProviderStatus = "未構成"
  @Published var errorMessage: String?

  private let shellURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".local/bin/nafi")
  private var fileProviderStoreURL: URL? {
    AppStoragePaths.fileProviderFile(named: "file-provider-domains.json")
  }
  private var legacyFileProviderStoreURL: URL {
    AppStoragePaths.file(named: "file-provider-domains.json")
  }
  private let legacyAppGroupStoreURL = AppStoragePaths.legacyAppGroupDirectory
    .appendingPathComponent("file-provider-domains.json")
  private let shellMarker = "# Managed by nafi (app.nafi.filemanager)"

  init() {
    refresh()
    if fileProviderStoreURL == nil {
      fileProviderStoreUsable = false
      fileProviderStatus = "利用不可（File Providerの保存先にアクセスできません）"
    } else {
      migrateLegacyFileProviderStoreIfNeeded()
      loadFileProviderProfiles()
    }
  }

  func refresh() {
    #if canImport(ServiceManagement)
    if #available(macOS 13.0, *) {
      launchesAtLogin = loginService.status == .enabled
    }
    #endif
    shellCommandInstalled = shellCommandIsManaged
  }

  func refreshRcloneVersion() {
    Task(priority: .utility) { [weak self] in
      guard let binary = await RcloneRuntime.shared.binaryURL() else {
        await MainActor.run { self?.rcloneVersion = nil }
        return
      }
      do {
        let result = try await BoundedProcessRunner.run(
          executableURL: binary,
          arguments: ["version"],
          timeout: 8,
          maximumStandardOutputBytes: 64 * 1_024,
          maximumStandardErrorBytes: 64 * 1_024
        )
        guard result.terminationStatus == 0 else {
          await MainActor.run { self?.rcloneVersion = nil }
          return
        }
        let text = String(data: result.stdout, encoding: .utf8) ?? ""
        let version = text.split(whereSeparator: \.isNewline).first.map(String.init)
        await MainActor.run { self?.rcloneVersion = version }
      } catch {
        await MainActor.run { self?.rcloneVersion = nil }
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

  func refreshFileProvider(profileID: UUID) {
    guard fileProviderProfileIDs.contains(profileID) else { return }
    fileProviderStatus = "更新を要求中…"
    Task {
      do {
        try await FileProviderChangeNotifier.refreshNow(profileID: profileID)
        await MainActor.run {
          self.fileProviderStatus = "\(self.fileProviderProfileIDs.count)接続を公開・更新要求済み"
        }
      } catch {
        await MainActor.run {
          self.fileProviderStatus = self.fileProviderProfileIDs.isEmpty
            ? "未構成" : "\(self.fileProviderProfileIDs.count)接続を公開"
          self.errorMessage = "File Providerへ最新状態の確認を要求できませんでした。\n\(error.localizedDescription)"
        }
      }
    }
  }

  func setFileProviderEnabled(_ enabled: Bool, profile: ServerProfile) {
    Task {
      do {
        guard fileProviderStoreUsable, fileProviderStoreURL != nil else {
          throw CocoaError(.fileWriteNoPermission, userInfo: [
            NSLocalizedDescriptionKey: "File Provider拡張の保存先に書き込めません。nafi内でのサーバー接続は引き続き利用できます。"
          ])
        }
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
          self.errorMessage = "File Providerを変更できません。\n\(error.localizedDescription)"
        }
      }
    }
  }

  private func migrateLegacyFileProviderStoreIfNeeded() {
    do {
      try Self.migrateLegacyFileProviderStoreIfNeeded(
        to: AppStoragePaths.fileProviderDirectory,
        legacyAppGroupStoreURL: legacyAppGroupStoreURL,
        legacyFileProviderStoreURL: legacyFileProviderStoreURL
      )
    } catch {
      errorMessage = "旧File Provider設定を拡張領域へ移行できません。\n\(error.localizedDescription)"
    }
  }

  static func migrateLegacyFileProviderStoreIfNeeded(
    to sharedDirectory: URL?,
    legacyAppGroupStoreURL: URL,
    legacyFileProviderStoreURL: URL
  ) throws {
    guard let sharedDirectory else { return }
    let destination = sharedDirectory.appendingPathComponent("file-provider-domains.json")
    guard !FileManager.default.fileExists(atPath: destination.path) else { return }
    // Legacy files may be visible but unreadable. Never replace current records
    // with unvalidated data, and leave every failed source untouched.
    let candidates = [legacyFileProviderStoreURL, legacyAppGroupStoreURL]
      .filter { FileManager.default.fileExists(atPath: $0.path) }
      .sorted {
        if $0 == $1 { return false }
        let left = (try? URL(fileURLWithPath: $0.path)
          .resourceValues(forKeys: [.contentModificationDateKey]))?
          .contentModificationDate ?? .distantPast
        let right = (try? URL(fileURLWithPath: $1.path)
          .resourceValues(forKeys: [.contentModificationDateKey]))?
          .contentModificationDate ?? .distantPast
        return left == right ? $0 == legacyFileProviderStoreURL : left > right
      }
    for source in candidates {
      guard let data = try? AppStoragePaths.readRegularFile(
        at: source, maximumBytes: 4 * 1_024 * 1_024),
        (try? Self.decodeFileProviderProfiles(data)) != nil
      else { continue }
      let temporary = sharedDirectory.appendingPathComponent(".nafi-import-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: temporary) }
      try data.write(to: temporary, options: [.atomic, .completeFileProtectionUnlessOpen])
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: temporary.path)
      do {
        try FileManager.default.moveItem(at: temporary, to: destination)
      } catch {
        if !FileManager.default.fileExists(atPath: destination.path) { throw error }
      }
      return
    }
  }

  private static func decodeFileProviderProfiles(
    _ data: Data
  ) throws -> (records: [UUID: FileProviderDomainRecord], ids: Set<UUID>) {
    if let records = try? JSONDecoder().decode([FileProviderDomainRecord].self, from: data),
      records.count <= 10_000 {
      var unique: [UUID: FileProviderDomainRecord] = [:]
      for record in records where unique[record.id] == nil { unique[record.id] = record }
      return (unique, Set(unique.keys))
    }
    if let ids = try? JSONDecoder().decode(Set<UUID>.self, from: data), ids.count <= 10_000 {
      return ([:], ids)
    }
    throw CocoaError(.fileReadCorruptFile)
  }

  private func loadFileProviderProfiles() {
    guard let fileProviderStoreURL,
      FileManager.default.fileExists(atPath: fileProviderStoreURL.path) else { return }
    let data: Data
    do {
      data = try AppStoragePaths.readRegularFile(
        at: fileProviderStoreURL, maximumBytes: 4 * 1_024 * 1_024)
    } catch {
      fileProviderStoreUsable = false
      fileProviderStatus = "利用不可（File Provider設定を読み取れません）"
      errorMessage = "File Provider設定を読み取れません。元のファイルは保持しています。\n\(error.localizedDescription)"
      return
    }
    do {
      let decoded = try Self.decodeFileProviderProfiles(data)
      fileProviderRecords = decoded.records
      fileProviderProfileIDs = decoded.ids
    } catch {
      AppStoragePaths.quarantineCorruptFile(at: fileProviderStoreURL)
      if FileManager.default.fileExists(atPath: fileProviderStoreURL.path) {
        fileProviderStoreUsable = false
        fileProviderStatus = "利用不可（File Provider設定を隔離できません）"
        errorMessage = "File Provider設定を読み取れず、元のファイルを隔離できません。上書きせず保持しています。\n\(error.localizedDescription)"
        return
      }
      errorMessage = "File Provider設定が破損していたため隔離しました。\n\(error.localizedDescription)"
      fileProviderRecords = [:]
      fileProviderProfileIDs = []
    }
    fileProviderStatus = fileProviderProfileIDs.isEmpty ? "未構成" : "\(fileProviderProfileIDs.count)接続を公開"
  }

  func reconcileFileProviderProfiles(_ profiles: [ServerProfile]) {
    guard fileProviderStoreUsable, let fileProviderStoreURL else { return }
    let byID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
    if !attemptedLegacyDomainRecovery {
      attemptedLegacyDomainRecovery = true
      if !FileManager.default.fileExists(atPath: fileProviderStoreURL.path) {
        // If no readable legacy store was available, reconstruct missing records
        // from registered Finder domains and the saved server profiles.
        Task { [weak self] in
          guard let self else { return }
          do {
            let domains = try await registeredFileProviderDomains()
            guard !FileManager.default.fileExists(atPath: fileProviderStoreURL.path) else {
              loadFileProviderProfiles()
              reconcileFileProviderProfiles(profiles)
              return
            }
            let prefix = "app.nafi.filemanager.remote."
            let recovered = domains.compactMap { domain -> FileProviderDomainRecord? in
              let raw = domain.identifier.rawValue
              guard raw.hasPrefix(prefix),
                let id = UUID(uuidString: String(raw.dropFirst(prefix.count))),
                let profile = byID[id]
              else { return nil }
              return FileProviderDomainRecord(profile: profile)
            }
            guard !recovered.isEmpty else { return }
            let records = Dictionary(uniqueKeysWithValues: recovered.map { ($0.id, $0) })
            try persistFileProviderProfiles(records)
            fileProviderRecords = records
            fileProviderProfileIDs = Set(records.keys)
            fileProviderStatus = "\(records.count)接続を復元"
            reconcileFileProviderProfiles(profiles)
          } catch {
            errorMessage = "旧File Provider設定を復元できません。Finderの公開状態を確認してください。\n\(error.localizedDescription)"
          }
        }
      }
    }
    let removed = fileProviderRecords.values.filter { byID[$0.id] == nil }
    var changed = false
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
      }
    }
    if changed {
      do { try persistFileProviderProfiles(fileProviderRecords) }
      catch { errorMessage = "File Provider設定を更新できません。\n\(error.localizedDescription)" }
    }

    // Reconcile every published domain, not only renamed ones. This upgrades
    // existing Tahoe registrations to supportsStringSearchRequest=true without
    // asking the user to remove and re-add the File Provider domain.
    for id in fileProviderProfileIDs {
      guard let profile = byID[id] else { continue }
      Task {
        do { try await addFileProviderDomain(profile) }
        catch {
          await MainActor.run {
            self.errorMessage = "File Providerドメインを更新できません。\n\(error.localizedDescription)"
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
    guard fileProviderStoreUsable, let fileProviderStoreURL else {
      throw CocoaError(.fileWriteNoPermission)
    }
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

  // No clock-driven File Provider polling. Nafi-originated mutations signal the
  // affected domain immediately, while remote-only changes are picked up the next
  // time macOS enumerates that directory. This removes a permanent wake source.

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
    #if compiler(>=6.2)
    if #available(macOS 26.0, *) {
      // Tahoe can ask File Provider directly for remote-only search results.
      // Older systems continue to expose the working set through Spotlight.
      domain.supportsStringSearchRequest = true
      if existing?.displayName == domain.displayName, existing?.supportsStringSearchRequest == true { return }
    } else if existing?.displayName == domain.displayName {
      return
    }
    #else
    if existing?.displayName == domain.displayName { return }
    #endif
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

  /// Recovery path for a poisoned fileproviderd database (for example after a
  /// pathological traversal filled it with junk items). Removes every nafi File
  /// Provider domain so the daemon drops its per-domain databases, clears the
  /// regenerable enumeration snapshots, and re-registers the persisted domains.
  /// Runs from `nafi --repair-file-providers`; the normal app reconcile loop
  /// republishes records on the next launch regardless.
  static func repairFileProviderDomains() async {
    #if canImport(FileProvider)
    guard let root = AppStoragePaths.fileProviderDirectory else {
      print("repair aborted: File Provider storage is inaccessible")
      return
    }
    let storeURL = root.appendingPathComponent("file-provider-domains.json")
    var records: [FileProviderDomainRecord] = []
    if let data = try? AppStoragePaths.readRegularFile(at: storeURL, maximumBytes: 4 * 1_024 * 1_024),
      let decoded = try? JSONDecoder().decode([FileProviderDomainRecord].self, from: data)
    {
      records = decoded
    }
    guard !records.isEmpty else {
      print("repair aborted: no persisted File Provider records")
      return
    }

    let registered = (try? await registeredFileProviderDomains()) ?? []
    let prefix = "app.nafi.filemanager.remote."
    let stale = registered.filter { $0.identifier.rawValue.hasPrefix(prefix) }
    for domain in stale {
      try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        NSFileProviderManager.remove(domain) { _ in continuation.resume() }
      }
      print("removed domain: \(domain.displayName)")
    }

    // Delete the stale materialized FPFS tree. After NSFileProviderManager.remove
    // these are plain directories (not mounts) and keep whatever the daemon
    // materialized historically — including junk from a poisoned crawl. A
    // re-added domain that finds them on disk re-imports the old rows
    // (materialization|itemChangedRem churn), so they must go before re-adding.
    let cloudStorage = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/CloudStorage", isDirectory: true)
    if let volumes = try? FileManager.default.contentsOfDirectory(
      at: cloudStorage, includingPropertiesForKeys: nil
    ) {
      let wanted = Set(records.map { "nafi-\($0.displayName)" })
      for volume in volumes where wanted.contains(volume.lastPathComponent) {
        try? FileManager.default.removeItem(at: volume)
        print("removed materialized volume: \(volume.lastPathComponent)")
      }
    }
    let snapshots = root.appendingPathComponent("FileProviderSnapshots", isDirectory: true)
    if let files = try? FileManager.default.contentsOfDirectory(
      at: snapshots, includingPropertiesForKeys: nil
    ) {
      var removed = 0
      for file in files where file.pathExtension == "json" {
        try? FileManager.default.removeItem(at: file)
        removed += 1
      }
      print("removed snapshots: \(removed)")
    }

    if !stale.isEmpty {
      try? await Task.sleep(nanoseconds: 5_000_000_000)
    }

    for record in records {
      let domain = NSFileProviderDomain(
        identifier: NSFileProviderDomainIdentifier(
          rawValue: "app.nafi.filemanager.remote.\(record.id.uuidString.lowercased())"
        ),
        displayName: record.displayName
      )
      #if compiler(>=6.2)
      if #available(macOS 26.0, *) {
        domain.supportsStringSearchRequest = true
      }
      #endif
      try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        NSFileProviderManager.add(domain) { _ in continuation.resume() }
      }
      print("re-added domain: \(record.displayName)")
    }
    print("repair complete")
    #else
    print("File Provider is unavailable on this system")
    #endif
  }

  private static func registeredFileProviderDomains() async throws -> [NSFileProviderDomain] {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<[NSFileProviderDomain], Error>) in
      NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: domains) }
      }
    }
  }
}
