import AppKit
import CoreServices
import Foundation
import UniformTypeIdentifiers

@MainActor
final class DefaultFileManagerService: ObservableObject {
  enum OperationState: Equatable {
    case idle
    case changing
    case succeeded(String)
    case partial(String)
    case failed(String)
  }

  private struct HandlerDefinition {
    let title: String
    let contentType: UTType
    let roles: [LSRolesMask]
    let usesConcreteFolderSample: Bool
  }

  private struct HandlerFailure {
    let definition: HandlerDefinition
    let error: Error
  }

  private struct InstalledApplication {
    let url: URL
    let wasInstalled: Bool
  }

  private struct LaunchServicesError: LocalizedError {
    let operation: String
    let status: OSStatus

    var errorDescription: String? {
      let systemMessage = NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        .localizedDescription
      return "\(operation)に失敗しました（\(status): \(systemMessage)）。"
    }
  }

  private struct DefaultApplicationError: LocalizedError {
    let typeName: String
    let modernError: Error
    let fallbackError: Error

    var errorDescription: String? {
      "\(typeName)の標準アプリ設定に失敗しました。macOS API: \(modernError.localizedDescription) / Launch Services: \(fallbackError.localizedDescription)"
    }
  }

  @Published private(set) var folderIsHandledByNafi = false
  @Published private(set) var directoryIsHandledByNafi = false
  @Published private(set) var volumeIsHandledByNafi = false
  @Published private(set) var mountPointIsHandledByNafi = false
  @Published private(set) var operationState: OperationState = .idle

  private let handlers = [
    HandlerDefinition(
      title: "通常のフォルダ",
      contentType: .folder,
      roles: [.viewer, .shell],
      usesConcreteFolderSample: true
    ),
    HandlerDefinition(
      title: "ボリューム",
      contentType: .volume,
      roles: [.viewer, .shell],
      usesConcreteFolderSample: false
    ),
    HandlerDefinition(
      title: "マウントポイント",
      contentType: .mountPoint,
      roles: [.viewer, .shell],
      usesConcreteFolderSample: false
    ),
  ]

  var isFullyDefault: Bool {
    folderIsHandledByNafi && directoryIsHandledByNafi && volumeIsHandledByNafi
      && mountPointIsHandledByNafi
  }

  var isRunningFromApplicationBundle: Bool {
    Bundle.main.bundleURL.pathExtension.lowercased() == "app"
  }

  func refresh() {
    folderIsHandledByNafi = isNafiDefaultHandler(
      for: .folder,
      roles: [.viewer, .shell]
    )
    // public.directory is an abstract parent type. A normal on-disk directory is
    // identified as public.folder, so the folder association is the effective
    // setting used when directories are opened from Launch Services.
    directoryIsHandledByNafi =
      folderIsHandledByNafi
      || isNafiDefaultHandler(for: .directory, roles: [.viewer, .shell])
    volumeIsHandledByNafi = isNafiDefaultHandler(
      for: .volume,
      roles: [.viewer, .shell]
    )
    mountPointIsHandledByNafi = isNafiDefaultHandler(
      for: .mountPoint,
      roles: [.viewer, .shell]
    )
  }

  func makeNafiDefault() async {
    guard isRunningFromApplicationBundle else {
      operationState = .failed("標準アプリの変更は、ビルド済みの nafi.app から実行してください。")
      return
    }

    operationState = .changing
    do {
      let installedApplication = try prepareStableApplication()
      try registerApplication(at: installedApplication.url)
      let failures = await applyDefaultHandlers(applicationURL: installedApplication.url)
      refresh()

      let installationMessage =
        installedApplication.wasInstalled
        ? " 今後も開けるように ~/Applications/nafi.app へインストールしました。" : ""
      updateOperationState(
        appName: "nafi",
        failures: failures,
        successMessage:
          "通常フォルダ（ディレクトリを含む）、ボリューム、マウントポイントを開く標準アプリをnafiに設定しました。\(installationMessage)"
      )
    } catch {
      refresh()
      operationState = .failed(friendlyMessage(for: error))
    }
  }

  func restoreFinder() async {
    guard
      let finderURL = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: "com.apple.finder")
    else {
      operationState = .failed("Finder.app が見つかりませんでした。")
      return
    }

    operationState = .changing
    do {
      try registerApplication(at: finderURL)
      let failures = await applyDefaultHandlers(applicationURL: finderURL)
      refresh()
      updateOperationState(
        appName: "Finder",
        failures: failures,
        successMessage: "通常フォルダ（ディレクトリを含む）、ボリューム、マウントポイントの標準アプリをFinderに戻しました。"
      )
    } catch {
      refresh()
      operationState = .failed(friendlyMessage(for: error))
    }
  }

  func clearMessage() {
    if operationState != .changing {
      operationState = .idle
    }
  }

  private func applyDefaultHandlers(applicationURL: URL) async -> [HandlerFailure] {
    var failures: [HandlerFailure] = []
    for definition in handlers {
      do {
        try await setDefaultApplication(
          applicationURL,
          definition: definition
        )
      } catch {
        failures.append(HandlerFailure(definition: definition, error: error))
      }
    }
    return failures
  }

  private func updateOperationState(
    appName: String,
    failures: [HandlerFailure],
    successMessage: String
  ) {
    guard !failures.isEmpty else {
      operationState =
        isFullyDefault || appName == "Finder"
        ? .succeeded(successMessage)
        : .partial("macOSへ設定を要求しましたが、状態の反映を確認できませんでした。状態を更新してください。")
      return
    }

    let failedNames = failures.map(\.definition.title).joined(separator: "、")
    let succeededCount = handlers.count - failures.count
    if succeededCount > 0 {
      operationState = .partial(
        "一部を\(appName)に設定しました。設定できなかった項目: \(failedNames)。状態を更新して、必要ならもう一度実行してください。"
      )
    } else {
      let firstError = failures[0].error
      operationState = .failed(friendlyMessage(for: firstError))
    }
  }

  private func setDefaultApplication(
    _ applicationURL: URL,
    definition: HandlerDefinition
  ) async throws {
    let expectedBundleIdentifier = try bundleIdentifier(for: applicationURL)
    var modernError: Error?

    if definition.usesConcreteFolderSample {
      do {
        try await setDefaultApplicationUsingConcreteFolder(applicationURL)
        if await waitForDefaultHandler(
          expectedBundleIdentifier,
          contentType: definition.contentType,
          roles: definition.roles
        ) {
          return
        }
      } catch {
        modernError = error
      }
    }

    do {
      try await setDefaultApplicationUsingContentType(
        applicationURL,
        contentType: definition.contentType
      )
      if await waitForDefaultHandler(
        expectedBundleIdentifier,
        contentType: definition.contentType,
        roles: definition.roles
      ) {
        return
      }
    } catch {
      modernError = error
    }

    do {
      try setDefaultApplicationUsingLaunchServices(
        applicationURL,
        for: definition.contentType,
        roles: definition.roles
      )
      if await waitForDefaultHandler(
        expectedBundleIdentifier,
        contentType: definition.contentType,
        roles: definition.roles
      ) {
        return
      }
      throw CocoaError(
        .fileWriteUnknown,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Launch Servicesは成功を返しましたが、関連付けを確認できませんでした。"
        ]
      )
    } catch let fallbackError {
      throw DefaultApplicationError(
        typeName: definition.title,
        modernError: modernError ?? fallbackError,
        fallbackError: fallbackError
      )
    }
  }

  private func setDefaultApplicationUsingContentType(
    _ applicationURL: URL,
    contentType: UTType
  ) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      NSWorkspace.shared.setDefaultApplication(
        at: applicationURL,
        toOpen: contentType
      ) { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: ())
        }
      }
    }
  }

  private func setDefaultApplicationUsingConcreteFolder(_ applicationURL: URL) async throws {
    let fileManager = FileManager.default
    let sampleURL = fileManager.temporaryDirectory.appendingPathComponent(
      "nafi-default-folder-\(UUID().uuidString)",
      isDirectory: true
    )
    try fileManager.createDirectory(at: sampleURL, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: sampleURL) }

    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      NSWorkspace.shared.setDefaultApplication(
        at: applicationURL,
        toOpenContentTypeOfFileAt: sampleURL
      ) { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: ())
        }
      }
    }
  }

  private func setDefaultApplicationUsingLaunchServices(
    _ applicationURL: URL,
    for contentType: UTType,
    roles: [LSRolesMask]
  ) throws {
    let bundleIdentifier = try bundleIdentifier(for: applicationURL)
    var firstFailure: LaunchServicesError?

    for role in roles {
      let status = LSSetDefaultRoleHandlerForContentType(
        contentType.identifier as CFString,
        role,
        bundleIdentifier as CFString
      )
      if status != noErr, firstFailure == nil {
        firstFailure = LaunchServicesError(
          operation: "\(contentType.identifier)（role: \(role.rawValue)）の関連付け",
          status: status
        )
      }
    }

    if !isDefaultHandler(
      bundleIdentifier,
      for: contentType,
      roles: roles
    ), let firstFailure {
      throw firstFailure
    }
  }

  private func bundleIdentifier(for applicationURL: URL) throws -> String {
    guard let bundleIdentifier = Bundle(url: applicationURL)?.bundleIdentifier else {
      throw CocoaError(
        .fileReadCorruptFile,
        userInfo: [
          NSLocalizedDescriptionKey: "アプリのBundle Identifierを取得できませんでした。"
        ]
      )
    }
    return bundleIdentifier
  }

  private func waitForDefaultHandler(
    _ bundleIdentifier: String,
    contentType: UTType,
    roles: [LSRolesMask]
  ) async -> Bool {
    for _ in 0..<12 {
      if isDefaultHandler(bundleIdentifier, for: contentType, roles: roles) {
        return true
      }
      try? await Task.sleep(for: .milliseconds(150))
    }
    return false
  }

  private func registerApplication(at applicationURL: URL) throws {
    guard FileManager.default.fileExists(atPath: applicationURL.path) else {
      throw CocoaError(
        .fileNoSuchFile,
        userInfo: [
          NSLocalizedDescriptionKey: "登録するアプリが見つかりません: \(applicationURL.path)"
        ])
    }

    let status = LSRegisterURL(applicationURL as CFURL, true)
    guard status == noErr else {
      throw LaunchServicesError(operation: "Launch Servicesへのアプリ登録", status: status)
    }
  }

  private func prepareStableApplication() throws -> InstalledApplication {
    let currentURL = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
    if isInApplicationsFolder(currentURL) {
      return InstalledApplication(url: currentURL, wasInstalled: false)
    }

    let fileManager = FileManager.default
    let applicationsURL =
      fileManager.urls(for: .applicationDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
        "Applications", isDirectory: true)
    try fileManager.createDirectory(at: applicationsURL, withIntermediateDirectories: true)

    let destinationURL = applicationsURL.appendingPathComponent("nafi.app", isDirectory: true)
    let stagingURL = applicationsURL.appendingPathComponent(
      ".nafi-install-\(UUID().uuidString).app",
      isDirectory: true
    )
    let backupURL = applicationsURL.appendingPathComponent(
      ".nafi-backup-\(UUID().uuidString).app",
      isDirectory: true
    )

    try fileManager.copyItem(at: currentURL, to: stagingURL)
    var movedExistingApplication = false
    do {
      if fileManager.fileExists(atPath: destinationURL.path) {
        try fileManager.moveItem(at: destinationURL, to: backupURL)
        movedExistingApplication = true
      }
      try fileManager.moveItem(at: stagingURL, to: destinationURL)
      if movedExistingApplication {
        try? fileManager.removeItem(at: backupURL)
      }
    } catch {
      try? fileManager.removeItem(at: stagingURL)
      if movedExistingApplication, !fileManager.fileExists(atPath: destinationURL.path) {
        try? fileManager.moveItem(at: backupURL, to: destinationURL)
      }
      throw error
    }

    guard Bundle(url: destinationURL)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
      throw CocoaError(
        .fileReadCorruptFile,
        userInfo: [
          NSLocalizedDescriptionKey: "~/Applications/nafi.appの検証に失敗しました。"
        ])
    }

    return InstalledApplication(url: destinationURL, wasInstalled: true)
  }

  private func isInApplicationsFolder(_ url: URL) -> Bool {
    let normalizedURL = url.resolvingSymlinksInPath().standardizedFileURL
    let fileManager = FileManager.default
    let roots = [
      URL(fileURLWithPath: "/Applications", isDirectory: true),
      fileManager.urls(for: .applicationDirectory, in: .userDomainMask).first
        ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
          "Applications", isDirectory: true),
    ]

    return roots.contains { root in
      let normalizedRoot = root.resolvingSymlinksInPath().standardizedFileURL
      return normalizedURL == normalizedRoot
        || normalizedURL.path.hasPrefix(normalizedRoot.path + "/")
    }
  }

  private func isNafiDefaultHandler(
    for contentType: UTType,
    roles: [LSRolesMask]
  ) -> Bool {
    guard let currentIdentifier = Bundle.main.bundleIdentifier else { return false }
    return isDefaultHandler(currentIdentifier, for: contentType, roles: roles)
  }

  private func isDefaultHandler(
    _ bundleIdentifier: String,
    for contentType: UTType,
    roles: [LSRolesMask]
  ) -> Bool {
    for role in roles {
      if let unmanagedHandler = LSCopyDefaultRoleHandlerForContentType(
        contentType.identifier as CFString,
        role
      ) {
        let handler = unmanagedHandler.takeRetainedValue() as String
        if handler.caseInsensitiveCompare(bundleIdentifier) == .orderedSame {
          return true
        }
      }
    }

    guard let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: contentType),
      let candidateIdentifier = Bundle(url: applicationURL)?.bundleIdentifier
    else { return false }
    return candidateIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
  }

  private func friendlyMessage(for error: Error) -> String {
    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain,
      nsError.code == NSFileReadNoPermissionError
        || nsError.code == 256
    {
      return
        "macOSが標準アプリの変更を拒否しました。nafiを~/Applicationsへ登録し、実在フォルダ方式とLaunch ServicesのViewer／Shell役割でも再試行しましたが変更できませんでした。"
    }
    return error.localizedDescription
  }
}
