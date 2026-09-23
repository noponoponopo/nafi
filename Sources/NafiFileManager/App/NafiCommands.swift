import AppKit
import SwiftUI

struct NafiCommands: Commands {
  @ObservedObject var appState: AppState

  /// テキストフィールド（リネームのプロンプト、検索、パスバー、サイドバー、
  /// エディタ類）に入力中は、メニューショートカットがファイル選択に対して
  /// 裏で作用してはいけない。修飾キー付きのショートカットはメニューが
  /// 先に横取りするため、アクション側で判定して退避する。
  private var isTextEditingActive: Bool {
    if appState.activeModel.prompt != nil { return true }
    return NSApp.keyWindow?.firstResponder is NSTextView
  }

  /// ファイル選択に対する操作を、テキスト編集中は実行しない。
  private func performPaneAction(_ action: () -> Void) {
    guard !isTextEditingActive else { return }
    action()
  }

  /// テキスト編集中は標準テキスト操作（copy: など）をフィールドエディタへ
  /// 転送して普通の文字編集として機能させ、そうでなければファイル操作を行う。
  private func performPasteboardAction(textAction: Selector, paneAction: () -> Void) {
    if isTextEditingActive {
      _ = NSApp.sendAction(textAction, to: nil, from: nil)
    } else {
      paneAction()
    }
  }

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("新規ウインドウ") { appState.newWindow() }
        .keyboardShortcut("n", modifiers: .command)
      Button("新規ウインドウタブ") { appState.newNativeTab() }
        .keyboardShortcut("t", modifiers: .command)
      Button("新規ファイル") { performPaneAction { appState.activeModel.requestNewFile() } }
        .keyboardShortcut("n", modifiers: [.command, .option])
      Button("新規フォルダ") { performPaneAction { appState.activeModel.requestNewFolder() } }
        .keyboardShortcut("n", modifiers: [.command, .shift])
      Divider()
      Button("ウインドウタブを閉じる") { appState.closeActiveNativeTab() }
        .keyboardShortcut("w", modifiers: .command)
    }

    CommandGroup(replacing: .pasteboard) {
      Button("コピー") {
        performPasteboardAction(textAction: #selector(NSText.copy(_:))) {
          appState.activeModel.copySelection()
        }
      }
      .keyboardShortcut("c", modifiers: .command)
      Button("移動用にカット") {
        performPasteboardAction(textAction: #selector(NSText.cut(_:))) {
          appState.activeModel.copySelection(cut: true)
        }
      }
      .keyboardShortcut("x", modifiers: .command)
      Button("ペースト") {
        performPasteboardAction(textAction: #selector(NSText.paste(_:))) {
          appState.activeModel.paste()
        }
      }
      .keyboardShortcut("v", modifiers: .command)
      Button("すべてを選択") {
        performPasteboardAction(textAction: #selector(NSText.selectAll(_:))) {
          appState.activeModel.selectAll()
        }
      }
      .keyboardShortcut("a", modifiers: .command)
    }

    CommandMenu("操作") {
      Button("Quick Open") { performPaneAction { appState.presentQuickOpen() } }
        .keyboardShortcut(.space, modifiers: [.command, .option])

      Menu("選択項目") {
        Button("開く") { performPaneAction { appState.activeModel.openSelected() } }
          .keyboardShortcut("o", modifiers: .command)
        Button("名前を変更") { performPaneAction { appState.activeModel.requestRenameSelected() } }
          .keyboardShortcut(.return, modifiers: [])
        Button("一括名称変更") { appState.activeModel.requestBatchRenameSelected() }
          .disabled(appState.activeModel.selectedItems.count < 2)
        Button("複製") { performPaneAction { appState.activeModel.duplicateSelection() } }
          .keyboardShortcut("d", modifiers: .command)
        Button("エイリアスを作成") { appState.activeModel.createAliasSelection() }
        Button("圧縮") { appState.activeModel.compressSelection() }
        Button("ZIPを展開") { appState.activeModel.extractSelection() }
          .disabled(!appState.activeModel.canExtractSelection)
        Divider()
        Button("Quick Look") { performPaneAction { appState.activeModel.previewSelected() } }
          .keyboardShortcut(.space, modifiers: [])
        Button("ダウンロード…") { appState.activeModel.downloadSelection() }
          .disabled(!appState.activeModel.canDownloadSelection)
        Button("クイックエディット") { performPaneAction { appState.quickEditSelected() } }
          .keyboardShortcut("e", modifiers: [.command, .option])
          .disabled(!appState.canQuickEditSelection)
        Button("Drop Stackへ追加") { appState.addSelectionToDropStack() }
          .disabled(appState.activeModel.selectedItems.isEmpty)
        Divider()
        Button(appState.activeModel.isRemote ? "削除" : "ゴミ箱に入れる") {
          if isTextEditingActive {
            // cmd+delete はテキスト編集では「行頭まで削除」。ファイルは消さない。
            _ = NSApp.sendAction(NSSelectorFromString("deleteToBeginningOfLine:"), to: nil, from: nil)
          } else {
            appState.activeModel.trashSelection()
          }
        }
        .keyboardShortcut(.delete, modifiers: .command)
      }

      Menu("移動と表示") {
        Button("戻る") { appState.activeModel.goBack() }
          .keyboardShortcut("[", modifiers: .command)
          .disabled(!appState.activeModel.canGoBack)
        Button("進む") { appState.activeModel.goForward() }
          .keyboardShortcut("]", modifiers: .command)
          .disabled(!appState.activeModel.canGoForward)
        Button("親フォルダ") { appState.activeModel.goUp() }
          .keyboardShortcut(.upArrow, modifiers: .command)
        Divider()
        ForEach(FileViewMode.allCases) { mode in
          Button(mode.label) { appState.activeModel.viewMode = mode }
        }
        Divider()
        Button(appState.activeModel.showHidden ? "隠しファイルを隠す" : "隠しファイルを表示") {
          appState.activeModel.showHidden.toggle()
          appState.activeModel.load()
        }
        .keyboardShortcut(".", modifiers: [.command, .shift])
      }

      Menu("ペイン") {
        Button("左右に追加") { appState.workspace.splitActive(axis: .horizontal) }
          .keyboardShortcut("\\", modifiers: [.command, .option])
        Button("上下に追加") { appState.workspace.splitActive(axis: .vertical) }
        Button("現在のペインを閉じる") {
          appState.workspace.closePane(appState.workspace.activePaneID)
        }
        .disabled(appState.workspace.paneCount == 1)
      }

      Divider()
      Button("同期") { appState.isSyncCenterPresented = true }
      Button("Drop Stack") { appState.openDropStack?() }
      Button("ワークスペース") { appState.isWorkspaceLibraryPresented = true }
      Divider()
      Button("ここでターミナルを開く") { appState.activeModel.openTerminalHere() }
        .disabled(!appState.activeModel.canOpenTerminalHere)
      Button("接続先を追加") { appState.presentServerEditor() }
        .keyboardShortcut("k", modifiers: [.command, .shift])
    }
  }
}
