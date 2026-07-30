# nafi architecture

This document describes the implementation at `v0.8.9`. `COMPONENT_TREE.md` is the companion document for SwiftUI composition and search data flow.

## State hierarchy

`AppState` owns application-wide services, settings, sidebar state, and the registry of browser windows. The initial SwiftUI browser scene and every AppKit-created native tab own a `BrowserWindowState`. Each browser state owns one `WorkspaceModel`.

`WorkspaceModel` owns a recursive `PaneLayoutNode` tree and a dictionary of `PaneSession` objects. Each `PaneSession` owns exactly one `FilePaneModel`. Browser-level tabs are real `NSWindow` tabs; split panes remain independent models inside the selected window tab.

`ActiveWindowChromeCoordinator` connects browser content to its `NSWindow`, assigns the shared tabbing identifier, observes key-window changes, and mirrors the active pane title and represented URL into the native window. `AppState.activeWindowID` keeps commands and sidebar actions pointed at the selected tab.

## Native window tab flow

Command-T, the plus button in the macOS tab bar, Finder or Launch Services requests configured for a new tab, and the “新しいタブで開く” command create a unique `NativeTabRequest`. `AppState` creates an AppKit `NSWindow` with shared SwiftUI browser content and adds it directly to the requesting window’s tab group before showing it. It does not create a provisional visible SwiftUI window through `openWindow`.

Closing with Command-W closes the selected `NSWindow` tab. macOS provides tab selection, reordering, detaching, and the native tab-bar UI. Each tab gets its own `BrowserWindowState`, so navigation, selection, pane layout, and active title do not leak between tabs.

Finder and Launch Services file events pass through `ExternalOpenRouter`. A folder opens at the configured current-tab or new-tab destination. A file opens its containing folder and schedules the file for selection after the first load. Multiple selected files use separate native tabs so later events cannot overwrite earlier selections.

## Pane and selection flow

`WorkspaceView` recursively renders `WorkspaceModel.root`. A leaf node becomes a `PaneHostView`; a split node becomes a native `HSplitView` or `VSplitView`. Splitting creates a new `PaneSession` with the active pane’s display settings and current location. Closing a pane collapses the surrounding split and keeps at least one pane.

`FileSelectionController` owns the selected URL set, primary selection, and selection flags. `FileSelectionSurface` observes AppKit mouse-down events before SwiftUI gesture completion, so ordinary and context-click selection updates immediately. It implements ordinary replacement, Command-toggle, Shift range, Command-Shift additive range, and drag-marquee selection. Only rows whose selection flag changes publish a row update. The displayed-item index provides constant-time lookups for the active range and keyboard-selection anchors.

The list view presents an expandable tree. A disclosure action loads a folder’s children through `UnifiedFileSystemService`, indents descendants by depth, and removes descendants when the folder is collapsed. Navigation or changes to the root contents, sort, or filter reset or reload the relevant expansion state.

## File-system execution

`FilePaneModel` owns navigation, history, search state, display settings, selection, and operation prompts for one pane. `UnifiedFileSystemService` accepts both local file URLs and internal `nafi-remote://<profile-id>/<path>` URLs and routes each operation to the appropriate local service or `RemoteServerSession`.

Local directory enumeration uses `FileSystemService`, which caches short-lived directory snapshots, reads metadata for each item, and coalesces change notifications. Expensive local operations and remote protocol operations run through detached tasks or actor-isolated sessions. Stale loads and searches are cancellable and are discarded when their token no longer matches the current location or query.

Local-to-local operations retain native file-system behavior. A move within one remote session uses the server rename operation. Local-to-remote, remote-to-local, and different-remote transfers use a private temporary staging location when a direct operation is unavailable. `TransferQueue` persists jobs before execution and exposes pause, resume, cancel, retry, progress, and bounded terminal history through Settings. Replacements transfer to hidden sibling names, verify size or SHA-256 content, then commit by rename; a move removes the source only after the destination commits. Failures restore replaced items and clean staged data where possible. Notifications name all affected roots so matching native tabs and panes reload.

The same `FilePaneModel`, selection controller, views, sidebar destinations, context menus, collision dialog, Quick Look path, and Quick Edit path are used for local and supported remote roots. The UI does not open a separate server browser.

## Search and preview

Current-folder search filters the pane’s cached items in memory. Descendant and storage-wide searches use `FileSearchService`: local roots use a detached `FileManager` enumerator, and remote roots use `UnifiedFileSystemService`. Results are rendered as a flat list with parent locations so duplicate names remain distinguishable. The shared `FileSearchFilter` value keeps folder, content-kind, and extension-group filtering consistent across both paths. Recursive searches stop at `FileSearchService.resultLimit`, currently 5,000 items.

Quick Look and gallery preview use local URLs. Remote items are downloaded to a temporary local copy first. Gallery keeps its filmstrip outside the Quick Look preview layout region so the filmstrip cannot be compressed or scrolled away by the preview.

Quick Edit uses `QuickEditService` and `NSFileCoordinator`. It supports recognized text and source files up to 8 MiB, preserves encoding, BOM, and line endings, requests an iCloud Drive download when needed, and checks the modification date before replacing the file. Remote editing downloads a temporary local copy and uploads the saved result after a successful local write.

## Server connections

`ServerManager` persists non-secret `ServerProfile` values in `servers.json`, keeps credentials in `KeychainStore`, and registers live sessions with `RemoteFileSystemRegistry`.

- SMB, WebDAV, NFS, and AFP call macOS NetFS directly and expose the resulting mount as an ordinary local file URL.
- SFTP password and private-key authentication both use the installed macOS `/usr/bin/sftp` process without opening a GUI client. A private temporary askpass helper supplies the secret. `SSHHostKeyService` scans fingerprints for explicit approval, stores trusted keys in the app-owned `known_hosts`, and all connections use `StrictHostKeyChecking=yes` with the global known-hosts files disabled.
- FTP, explicit FTPS, and implicit FTPS use the in-process SwiftNIO client. FTPS uses TLS 1.2 or later, supports protected passive data channels, and verifies certificates by default.
- S3-compatible storage uses `URLSession`, AWS Signature V4, paginated prefix listing, server-side copy where possible, and multipart upload for local files at least 128 MiB. Objects and common prefixes are mapped to ordinary file items.

External OpenSSH, `ssh-keyscan`, `ssh-keygen`, `zip`, `unzip`, and `ditto` invocations run through `BoundedProcessRunner`, which limits execution time, standard output, standard error, and cancellation cleanup. FTP control replies and listings, S3 control responses and pagination, and persisted JSON files also have explicit size and count bounds.

`TerminalApplicationService` creates a short-lived `.command` file and asks macOS to open it with the associated terminal application. Local roots run a shell in the local directory; SFTP roots run `ssh -t` and change to the displayed remote path. FTP and FTPS roots do not expose an interactive shell.

## Persistence and privacy

`AppStoragePaths` stores application-owned files under `~/Library/Application Support/nafi`. The current files are:

- `servers.json` for server profiles
- `sidebar.json` for sidebar configuration
- `icloud-drive.bookmark` for a user-selected security-scoped iCloud Drive location
- `known_hosts` for explicitly trusted SFTP host keys
- `transfers.json` for the bounded persistent transfer queue and recent terminal history

Passwords, SFTP key passphrases, S3 secret access keys, and temporary S3 session tokens are stored separately in the macOS Keychain. Private-key file contents are not copied into the profile. nafi does not write its own view metadata or `.DS_Store` files into browsed folders. Temporary local staging files can exist during remote preview, editing, or cross-root transfer operations.

## macOS integration

`NafiApp` provides the browser scene, server editor, file inspector, and Settings scene. `DefaultFileManagerService` uses modern `NSWorkspace` APIs with Launch Services fallback to request nafi or Finder as the default handler for folders, volumes, and mount points. `Info.plist` also declares supported document types and the Finder Service for opening selected files and folders in nafi.

`CloudStorageService` first resolves a saved security-scoped bookmark, then detects the conventional iCloud Drive location under `~/Library/Mobile Documents/com~apple~CloudDocs`. It starts and releases security-scoped access with the service lifetime.
