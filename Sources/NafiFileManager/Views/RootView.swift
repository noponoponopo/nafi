import SwiftUI

struct RootView: View {
  let request: NativeTabRequest?
  @EnvironmentObject private var appState: AppState

  var body: some View {
    BrowserWindowHost(appState: appState, request: request)
  }
}

private struct BrowserWindowHost: View {
  @ObservedObject var appState: AppState
  @StateObject private var windowState: BrowserWindowState
  @Environment(\.openWindow) private var openWindow

  init(appState: AppState, request: NativeTabRequest?) {
    self.appState = appState
    _windowState = StateObject(wrappedValue: BrowserWindowState(request: request))
  }

  var body: some View {
    BrowserWindowView(appState: appState, windowState: windowState)
      .task {
        appState.openServerEditor = { profile in
          openWindow(id: "server-editor", value: profile)
        }
        appState.openInspector = { url in
          openWindow(id: "file-inspector", value: url)
        }
      }
  }
}

/// Browser content shared by the initial SwiftUI scene and AppKit-created
/// native tabs. AppKit-created tabs do not call `openWindow`, which prevents a
/// Finder open from first creating a separate visible SwiftUI window.
struct BrowserWindowView: View {
  @ObservedObject var appState: AppState
  @ObservedObject var windowState: BrowserWindowState

  var body: some View {
    RootViewContent(
      appState: appState,
      windowState: windowState,
      workspace: windowState.workspace,
      serverManager: appState.serverManager
    )
    .task { windowState.start() }
  }
}

private struct RootViewContent: View {
  @ObservedObject var appState: AppState
  @ObservedObject var windowState: BrowserWindowState
  @ObservedObject var workspace: WorkspaceModel
  @ObservedObject var serverManager: ServerManager

  var body: some View {
    NavigationSplitView(columnVisibility: $appState.sidebarVisibility) {
      SidebarView(
        serverManager: appState.serverManager, model: appState.sidebarModel, workspace: workspace
      )
      .navigationSplitViewColumnWidth(min: 120, ideal: 240, max: 380)
    } detail: {
      WorkspaceView(workspace: workspace)
        .background(Color(nsColor: .textBackgroundColor))
    }
    .navigationSplitViewStyle(.balanced)
    .background(
      ActiveWindowChromeCoordinator(appState: appState, windowState: windowState)
    )
    .toolbarRole(.automatic)
    .toolbar { windowToolbar }
    .sheet(isPresented: $appState.isSidebarEditorPresented) {
      SidebarCustomizationView(model: appState.sidebarModel)
    }
    .sheet(item: $appState.quickEditRequest) { request in
      QuickEditView(url: request.url) { savedURL in
        appState.quickEditDidSave(savedURL)
      }
    }
    .alert(
      "nafi",
      isPresented: Binding(
        get: { appState.presentationErrorMessage != nil },
        set: { if !$0 { appState.presentationErrorMessage = nil } }
      )
    ) {
      Button("OK", role: .cancel) { appState.presentationErrorMessage = nil }
    } message: {
      Text(appState.presentationErrorMessage ?? "")
    }
  }

  @ToolbarContentBuilder
  private var windowToolbar: some ToolbarContent {
    ToolbarItemGroup(placement: .navigation) {
      ActiveNavigationControls(session: workspace.activeSession)
    }

    ToolbarItemGroup {
      Menu {
        Button("左右に追加") { workspace.splitActive(axis: .horizontal) }
        Button("上下に追加") { workspace.splitActive(axis: .vertical) }
        Divider()
        Button("現在のペインを閉じる") {
          workspace.closePane(workspace.activePaneID)
        }
        .disabled(workspace.paneCount == 1)
      } label: {
        Image(systemName: "rectangle.split.2x1")
      }
      .help("ペイン")
    }

    ToolbarItem {
      ActiveViewModePicker(session: workspace.activeSession)
    }

    ToolbarItemGroup {
      Button {
        appState.presentServerEditor()
      } label: {
        Image(systemName: "network.badge.shield.half.filled")
      }
      .help("サーバーへ接続")

      ActiveInspectorButton(session: workspace.activeSession) { item in
        appState.presentInspector(for: item.url)
      }
    }
  }
}

private struct ActiveNavigationControls: View {
  @ObservedObject var session: PaneSession

  var body: some View {
    ActiveNavigationButtons(model: session.activeModel)
      .id(session.activeTabID)
  }
}

private struct ActiveNavigationButtons: View {
  @ObservedObject var model: FilePaneModel

  var body: some View {
    Group {
      Button {
        model.goBack()
      } label: {
        Image(systemName: "chevron.left")
      }
      .disabled(!model.canGoBack)
      .help("戻る")
      Button {
        model.goForward()
      } label: {
        Image(systemName: "chevron.right")
      }
      .disabled(!model.canGoForward)
      .help("進む")
      Button {
        model.goUp()
      } label: {
        Image(systemName: "chevron.up")
      }
      .help("親フォルダ")
    }
  }
}

private struct ActiveViewModePicker: View {
  @ObservedObject var session: PaneSession

  var body: some View {
    ActiveViewModePickerContent(model: session.activeModel)
      .id(session.activeTabID)
  }
}

private struct ActiveViewModePickerContent: View {
  @ObservedObject var model: FilePaneModel

  var body: some View {
    Picker(selection: $model.viewMode) {
      ForEach(FileViewMode.allCases) { mode in
        Image(systemName: mode.systemImage)
          .accessibilityLabel(Text(mode.label))
          .tag(mode)
      }
    } label: {
      EmptyView()
    }
    .labelsHidden()
    .pickerStyle(.segmented)
    .controlSize(.regular)
    .fixedSize(horizontal: true, vertical: true)
    .padding(.vertical, 4)
    .help("表示形式")
  }
}

private struct ActiveInspectorButton: View {
  @ObservedObject var session: PaneSession
  let action: (FileItem) -> Void

  var body: some View {
    ActiveInspectorButtonContent(model: session.activeModel, action: action)
      .id(session.activeTabID)
  }
}

private struct ActiveInspectorButtonContent: View {
  @ObservedObject var model: FilePaneModel
  @ObservedObject private var selection: FileSelectionController
  let action: (FileItem) -> Void

  init(model: FilePaneModel, action: @escaping (FileItem) -> Void) {
    self.model = model
    _selection = ObservedObject(wrappedValue: model.selectionController)
    self.action = action
  }

  var body: some View {
    Button {
      guard let item = model.selectedItem else { return }
      action(item)
    } label: {
      Image(systemName: "info.circle")
    }
    .disabled(model.selectedItem == nil)
    .help("情報を見る")
  }
}
