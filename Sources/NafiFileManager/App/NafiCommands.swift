import SwiftUI

struct NafiCommands: Commands {
  @ObservedObject var appState: AppState

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("新規ウインドウタブ") { appState.newNativeTab() }
        .keyboardShortcut("t", modifiers: .command)
      Button("新規ファイル") { appState.activeModel.requestNewFile() }
        .keyboardShortcut("n", modifiers: [.command, .option])
      Button("新規フォルダ") { appState.activeModel.requestNewFolder() }
        .keyboardShortcut("n", modifiers: [.command, .shift])
      Divider()
      Button("ウインドウタブを閉じる") { appState.closeActiveNativeTab() }
        .keyboardShortcut("w", modifiers: .command)
    }

    CommandGroup(replacing: .pasteboard) {
      Button("コピー") { appState.activeModel.copySelection() }
        .keyboardShortcut("c", modifiers: .command)
      Button("移動用にカット") { appState.activeModel.copySelection(cut: true) }
        .keyboardShortcut("x", modifiers: .command)
      Button("ペースト") { appState.activeModel.paste() }
        .keyboardShortcut("v", modifiers: .command)
      Button("すべてを選択") { appState.activeModel.selectAll() }
        .keyboardShortcut("a", modifiers: .command)
    }

    CommandMenu("ファイル") {
      Button("開く") { appState.activeModel.openSelected() }
        .keyboardShortcut("o", modifiers: .command)
      Button("名前を変更") { appState.activeModel.requestRenameSelected() }
        .keyboardShortcut(.return, modifiers: [])
      Button("複製") { appState.activeModel.duplicateSelection() }
        .keyboardShortcut("d", modifiers: .command)
      Button("エイリアスを作成") { appState.activeModel.createAliasSelection() }
      Button("圧縮") { appState.activeModel.compressSelection() }
      Button("Quick Look") { appState.activeModel.previewSelected() }
        .keyboardShortcut(.space, modifiers: [])
      Button("クイックエディット") { appState.quickEditSelected() }
        .keyboardShortcut("e", modifiers: [.command, .option])
        .disabled(!appState.canQuickEditSelection)
      Divider()
      Button(appState.activeModel.isRemote ? "削除" : "ゴミ箱に入れる") {
        appState.activeModel.trashSelection()
      }
      .keyboardShortcut(.delete, modifiers: .command)
    }

    CommandMenu("移動") {
      Button("戻る") { appState.activeModel.goBack() }
        .keyboardShortcut("[", modifiers: .command)
        .disabled(!appState.activeModel.canGoBack)
      Button("進む") { appState.activeModel.goForward() }
        .keyboardShortcut("]", modifiers: .command)
        .disabled(!appState.activeModel.canGoForward)
      Button("親フォルダ") { appState.activeModel.goUp() }
        .keyboardShortcut(.upArrow, modifiers: .command)
      Divider()
      Button("新しいタブで開く") {
        if let item = appState.activeModel.selectedItem, item.isDirectory {
          appState.openInNewTab(item.url)
        }
      }
      Button("新しいペインで開く") {
        if let item = appState.activeModel.selectedItem, item.isDirectory {
          appState.openInNewPane(item.url)
        }
      }
    }

    CommandMenu("表示") {
      Button("リスト") { appState.activeModel.viewMode = .list }
        .keyboardShortcut("1", modifiers: .command)
      Button("マトリクス") { appState.activeModel.viewMode = .matrix }
        .keyboardShortcut("2", modifiers: .command)
      Button("カラム") { appState.activeModel.viewMode = .columns }
        .keyboardShortcut("3", modifiers: .command)
      Button("ギャラリー") { appState.activeModel.viewMode = .gallery }
        .keyboardShortcut("4", modifiers: .command)
      Divider()
      Button("左右にペインを追加") { appState.workspace.splitActive(axis: .horizontal) }
        .keyboardShortcut("\\", modifiers: [.command, .option])
      Button("上下にペインを追加") { appState.workspace.splitActive(axis: .vertical) }
      Button("現在のペインを閉じる") { appState.workspace.closePane(appState.workspace.activePaneID) }
        .disabled(appState.workspace.paneCount == 1)
      Divider()
      Button(appState.activeModel.showHidden ? "隠しファイルを隠す" : "隠しファイルを表示") {
        appState.activeModel.showHidden.toggle()
        appState.activeModel.load()
      }
      .keyboardShortcut(".", modifiers: [.command, .shift])
    }

    CommandMenu("サーバー") {
      Button("ここでターミナルを開く") { appState.activeModel.openTerminalHere() }
        .disabled(!appState.activeModel.canOpenTerminalHere)
      Divider()
      Button("接続先を追加") { appState.presentServerEditor() }
        .keyboardShortcut("k", modifiers: [.command, .shift])
      Button("自動接続を実行") { Task { await appState.serverManager.connectAutoProfiles() } }
      Button("マウントを再検出") { appState.serverManager.refreshMountedVolumes() }
    }
  }
}
