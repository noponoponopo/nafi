import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class DefaultFileManagerService: ObservableObject {
  enum OperationState: Equatable {
    case idle
    case changing
    case succeeded(String)
    case failed(String)
  }

  @Published private(set) var folderIsHandledByNafi = false
  @Published private(set) var directoryIsHandledByNafi = false
  @Published private(set) var volumeIsHandledByNafi = false
  @Published private(set) var mountPointIsHandledByNafi = false
  @Published private(set) var operationState: OperationState = .idle

  var isFullyDefault: Bool {
    folderIsHandledByNafi && directoryIsHandledByNafi && volumeIsHandledByNafi
      && mountPointIsHandledByNafi
  }

  var isRunningFromApplicationBundle: Bool {
    Bundle.main.bundleURL.pathExtension.lowercased() == "app"
  }

  func refresh() {
    folderIsHandledByNafi = isNafi(NSWorkspace.shared.urlForApplication(toOpen: .folder))
    directoryIsHandledByNafi = isNafi(NSWorkspace.shared.urlForApplication(toOpen: .directory))
    volumeIsHandledByNafi = isNafi(NSWorkspace.shared.urlForApplication(toOpen: .volume))
    mountPointIsHandledByNafi = isNafi(
      NSWorkspace.shared.urlForApplication(toOpen: .mountPoint))
  }

  func makeNafiDefault() async {
    guard isRunningFromApplicationBundle else {
      operationState = .failed("標準アプリの変更は、ビルド済みの nafi.app から実行してください。")
      return
    }

    operationState = .changing
    do {
      let applicationURL = Bundle.main.bundleURL
      for contentType in [UTType.folder, .directory, .volume, .mountPoint] {
        try await setDefaultApplication(applicationURL, for: contentType)
      }
      refresh()
      operationState =
        isFullyDefault
        ? .succeeded("フォルダ、ボリューム、マウントポイントを開く標準アプリを nafi に設定しました。")
        : .failed("一部の種類だけが変更されました。macOS の確認画面で許可した後、もう一度お試しください。")
    } catch {
      refresh()
      operationState = .failed(error.localizedDescription)
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
      for contentType in [UTType.folder, .directory, .volume, .mountPoint] {
        try await setDefaultApplication(finderURL, for: contentType)
      }
      refresh()
      operationState = .succeeded("フォルダ、ボリューム、マウントポイントの標準アプリを Finder に戻しました。")
    } catch {
      refresh()
      operationState = .failed(error.localizedDescription)
    }
  }

  func clearMessage() {
    if operationState != .changing {
      operationState = .idle
    }
  }

  private func setDefaultApplication(_ applicationURL: URL, for contentType: UTType) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
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

  private func isNafi(_ applicationURL: URL?) -> Bool {
    guard let applicationURL else { return false }

    let currentURL = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
    let candidateURL = applicationURL.resolvingSymlinksInPath().standardizedFileURL
    if currentURL == candidateURL { return true }

    guard let currentIdentifier = Bundle.main.bundleIdentifier,
      let candidateIdentifier = Bundle(url: applicationURL)?.bundleIdentifier
    else { return false }
    return currentIdentifier == candidateIdentifier
  }
}
