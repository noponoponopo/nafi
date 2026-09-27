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
      ├─ local root → one-shot Spotlight (NSMetadataQuery)
      │  └─ unindexed/timeout fallback → detached FileManager enumerator
      └─ remote root → RemoteServerSession.recursiveCatalog
         ├─ one metadata-only recursive rclone listing on cache miss
         └─ short-lived normalized-name catalog on repeat queries
```

`FileSearchFilter` is a value object shared by the in-memory and recursive search paths. It keeps folder-only, content-kind, and extension-group behavior consistent. Query tokens are normalized and ANDed, including case/diacritic/full-width differences. When a previous recursive result is complete and the next query only narrows it, `FilePaneModel` filters that result directly without re-querying Spotlight or rescanning the remote catalog. Recursive results are flat rows with parent-location labels so duplicate names remain distinguishable. The result limit is `FileSearchService.resultLimit`, currently 5,000. See `SEARCH_ARCHITECTURE.md` for remote/Finder search behavior and energy invariants.

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
├─ server profile editor → supported protocols / named rclone provider presets
│  ├─ RcloneProviderEditor → provider fields / browser authentication / config questions
│  └─ ServerManager / SSHHostKeyService → user's ~/.ssh/known_hosts
│     └─ RcloneRuntime → serialized config writes → verified remotes → live sessions
├─ rclone OAuth refresh → RcloneRuntime token monitor
│  └─ ServerManager → encrypted credential vault (single Keychain key) / active RcloneRemoteSession
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
   ├─ extension application-support directory → domain records / current rclone RC descriptor
   ├─ folder enumeration → operations/list; point lookup/version check → operations/stat
   └─ fetchContents → operations/copyfile; read-only Box fallback → exact-filtered sync/copy
      └─ private extension transfer directory → macOS File Provider materialization
```

The containing app publishes records and the expiring RC descriptor into the extension's existing application-support directory, which the sandboxed extension reads. `AppStoragePaths` probes actual host write access; an inaccessible directory disables Finder publishing without writing a misleading copy into the host's storage or interrupting pane connections. A remote is published as ready only after its descriptor is written successfully. Existing extension records are not overwritten by older App Group data; missing records can be restored from a valid, readable legacy file or registered macOS domains. Unreadable files remain in place rather than being treated as corrupt. A new domain's macOS working-set request is rooted at the remote root before normal folder enumeration begins. Point lookups and version checks use operations/stat so a save/delete does not enumerate a large parent directory. File fetches use operations/copyfile for a single object and retain the parent-rooted exact-filter fallback only for the known read-only Box metadata failure. Manual refresh signals the root and working set without enabling periodic polling. Folder enumeration shares one process-local loopback URLSession capped at eight concurrent RC connections. Sync-anchor reads reuse cached snapshot generations, and snapshot cleanup runs only after writes with a 15-minute minimum interval.

Path identifiers are capped at macOS PATH_MAX (1024 bytes, 256 components); a child whose path would exceed the cap is skipped instead of failing the folder, and an identifier that no longer decodes is reported as noSuchItem so fileproviderd prunes the row instead of retrying. Because operations/stat resolves symlinks server-side, a child's recorded classification in its parent's enumeration snapshot is authoritative: item(for:) and enumerator(for:) never upgrade a recorded non-directory to a folder, which is what stops /proc/thread-self/root-style symlink-cycle descents when a domain root resolves to a Linux machine root. Machine-root proc/sys/dev paths are also rejected for stale direct container requests, not only hidden from the fresh root listing. The Finder search catalog excludes the proc/sys/dev pseudo-filesystems and is capped at 250,000 entries, matching the app-side recursive search catalog. `nafi --repair-file-providers` removes and re-adds the owning domains and clears materialized/snapshot caches when fileproviderd has already retained poisoned state.
