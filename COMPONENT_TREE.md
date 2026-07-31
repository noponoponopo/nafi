# nafi component tree

The SwiftUI surface is organized as a component tree rather than feature-sized monolithic view files. Definitions and implementation paths remain in the Swift source; this document records the composition and data-flow contract.

## Rules

1. **Feature roots compose; they do not implement leaf behavior.** A root view chooses sections and passes models or actions downward.
2. **State lives at the lowest common owner.** Application navigation belongs to `AppState`; window-tab state belongs to `BrowserWindowState`; pane navigation and search belong to `FilePaneModel`; transient hover, popover, and editing state belongs to the leaf that renders it.
3. **Containers observe models; leaves receive values and actions.** This keeps presentation components testable and prevents environment dependencies from spreading through the tree.
4. **Reusable interaction behavior is a modifier or surface.** File drops, selection hit targets, favorite reorder targets, and the zero-layout end insertion target do not become spacer rows or duplicated feature logic.
5. **A component owns one reason to change.** Search controls, result rendering, sidebar rows, reorder behavior, customization UI, and file-pane rendering remain separate source components.
6. **Cross-feature operations go through models and services.** Views do not enumerate storage, access Keychain, or perform remote protocol operations directly.
7. **Native browser tabs are outside the SwiftUI tree.** The macOS `NSWindow` tab group owns browser-tab selection, ordering, detaching, and closing. SwiftUI owns the content of each tab.

## Main window

```text
RootView
└─ BrowserWindowHost
   └─ BrowserWindowView
      └─ RootViewContent
         ├─ ActiveWindowChromeCoordinator
         ├─ SidebarView
         │  ├─ SidebarFavoritesSection
         │  │  ├─ SidebarSectionHeader
         │  │  └─ SidebarDestinationRow
         │  │     ├─ SidebarReorderDropModifier
         │  │     └─ SidebarReorderEndDropOverlay
         │  ├─ SidebarICloudSection
         │  ├─ SidebarVolumesSection
         │  ├─ SidebarServersSection
         │  │  └─ ServerSidebarRow
         │  └─ SidebarFooter
         └─ WorkspaceView
            └─ PaneTreeView
               ├─ PaneHostView
               │  ├─ PaneNavigationBar
               │  │  ├─ PanePathControl
               │  │  ├─ PaneSearchControl
               │  │  │  └─ FileSearchOptionsPopover
               │  │  └─ PaneDisplayOptionsMenu
               │  └─ FilePaneView
               │     ├─ SearchResultsView (recursive or storage-wide search)
               │     │  ├─ SearchResultsHeader
               │     │  └─ FileSelectionSurface / SearchResultRow
               │     ├─ FileListView
               │     │  └─ FileSelectionSurface / TreeListRow
               │     ├─ FileMatrixView
               │     │  └─ FileSelectionSurface / MatrixCell
               │     ├─ FileColumnBrowserView
               │     │  └─ FileSelectionSurface / ColumnItemRow
               │     ├─ FileGalleryView
               │     │  ├─ GalleryPreview
               │     │  └─ GalleryFilmstrip / GalleryThumbnail
               │     └─ FilePaneStatusBar
                └─ HSplitView or VSplitView
                   ├─ PaneTreeView
                   └─ PaneTreeView
```

`PaneTreeView` renders the recursive `PaneLayoutNode`. A leaf uses `PaneHostView`; a split uses the native horizontal or vertical split view. `FileFolderDropModifier`, `FileSelectionSurface`, and sidebar reorder modifiers are interaction boundaries shared by the relevant leaf views.

`RootViewContent` also owns the shared toolbar, sidebar customization sheet, Quick Edit sheet, inspector presentation callback, application-level presentation errors, and the SFTP host-key approval alert. The toolbar sends commands to the active `WorkspaceModel` or active `FilePaneModel`; it does not perform storage operations itself.

## State ownership

```text
AppState
├─ ServerManager
│  └─ pending SFTP host-key approval → RootViewContent alert
├─ SidebarModel
├─ DefaultFileManagerService
├─ CloudStorageService
├─ TransferQueue (actor singleton)
└─ BrowserWindowState[]
   └─ WorkspaceModel
      ├─ PaneLayoutNode
      └─ PaneSession[]
         └─ FilePaneModel
            ├─ FileSelectionController
            ├─ navigation and history
            ├─ search and display settings
            └─ file-operation prompts and status
```

Browser tabs are represented by `BrowserWindowState` and native `NSWindow` instances. A `PaneSession` has one `FilePaneModel`; app-drawn pane-tab state is not part of the current architecture.

## Search data flow

```text
PaneSearchControl
└─ FilePaneModel
   ├─ current-folder query → in-memory arrange/filter
   └─ recursive or storage-wide query → FileSearchService
      ├─ local root → detached FileManager enumerator
      └─ remote root → UnifiedFileSystemService → RemoteServerSession
```

`FileSearchFilter` is a value object shared by the in-memory and recursive search paths. It keeps folder-only, content-kind, and extension-group behavior consistent. Recursive results are flat rows with parent-location labels so duplicate names remain distinguishable. The result limit is `FileSearchService.resultLimit`, currently 5,000.

## File-operation data flow

```text
FilePaneView / SidebarDestinationRow / toolbar command
└─ FilePaneModel
   └─ UnifiedFileSystemService
      ├─ local file URL → FileSystemService
      └─ nafi-remote URL → RemoteFileSystemRegistry
         └─ RemoteServerSession
```

The model owns selection, conflict prompts, operation status, and reload timing. Services own enumeration, local file operations, protocol operations, temporary staging, and change notifications. This keeps the view layer responsible for composition and presentation only.

Remote reads from Quick Look, thumbnails, local application opening, archive staging, and explicit downloads share the same flow:

```text
FilePaneModel / FileThumbnailService / QuickEditView
└─ UnifiedFileSystemService.prepareLocalCopy / withTemporaryLocalCopy / transfer
   └─ RemoteServerSession.downloadItem
      ├─ normal backend → rclone copy to private local staging
      └─ read-only Box folder → parent listing + exact-name filtered copy
```

The explicit `ダウンロード…` action is available for remote selections and uses a native folder picker. It always copies to a local destination with `move` disabled. Remote-to-local transfers stage and verify locally; source deletion, rename, upload, and remote temporary files are outside this flow.


## Settings and transfer recovery

```text
SettingsView
├─ general and integration settings
├─ server profile editor → native protocols / named rclone provider presets
│  ├─ RcloneProviderEditor → provider fields / browser authentication / config questions
│  └─ ServerManager / SSHHostKeyService
│     └─ user's ~/.ssh/known_hosts
├─ rclone OAuth refresh → RcloneRuntime token monitor
│  └─ ServerManager → Keychain / active RcloneRemoteSession
└─ transfer tab → TransferQueueModel → TransferQueue
   ├─ pause / resume / retry / cancel / remove
   └─ persisted progress, result URLs, attempts, and bounded terminal history
```

The transfer tab is a recovery surface rather than a second file browser. It observes queue-change notifications, displays persistence failures, and delegates every mutation back to the actor so UI refreshes cannot race with the worker.

OAuth providers may rotate refresh tokens while rclone serves either the app or File Provider. `RcloneRuntime` captures a token changed during connection immediately and polls configured OAuth remotes for later changes. `ServerManager` merges only the new token into the existing secret JSON, saves it to Keychain, and updates the active session so a runtime or app restart cannot restore the consumed token.

## File Provider data flow

```text
Other macOS app / Finder
└─ NafiFileProvider
   ├─ extension container → domain records / current rclone RC descriptor
   ├─ working set / folder enumeration → parent operations/list + exact item selection
   └─ fetchContents → parent-rooted sync/copy + exact rooted filename filter
      └─ private local transfer directory → macOS File Provider materialization
```

The containing app is not sandboxed and publishes records and the expiring RC descriptor directly into the File Provider extension container. The extension needs only its own sandbox container and loopback network access, so local builds do not depend on a provisioned App Group. Existing App Group records are migrated once. A new domain's macOS working-set request is rooted at the remote root before normal folder enumeration begins. File fetches use the same parent-listing strategy for every rclone backend; this avoids Box upload-preflight metadata calls and prevents recursive traversal outside the selected item's parent.
