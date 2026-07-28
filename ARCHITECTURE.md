# nafi architecture

## State hierarchy

`AppState` owns app-wide services, settings, sidebar state, and a registry of open browser windows. The initial SwiftUI browser scene and every AppKit-created native tab each own a `BrowserWindowState`, and each browser state owns one `WorkspaceModel`. AppKit groups those windows with `NSWindow.addTabbedWindow`, so every visible tab is a real macOS window tab with an independent workspace. The key/selected `NSWindow` updates `AppState.activeWindowID`, which keeps commands and sidebar actions pointed at the selected native tab.

`WorkspaceModel` owns a recursive `PaneLayoutNode` tree and a dictionary of `PaneSession` objects. Every `PaneSession` owns exactly one `FilePaneModel`; app-drawn pane tabs no longer exist. Split panes remain independent, while browser-level tab creation, selection, reordering, detaching, and closing are handled by the native window tab group.

`ActiveWindowChromeCoordinator` connects browser content to its `NSWindow`, assigns a shared tabbing identifier, registers key-window changes, and mirrors the active pane title and represented URL into the window. Because each native tab is its own `NSWindow`, selecting a tab also selects the correct workspace and title automatically.

## Native window tab flow

Command-T, the plus button in the macOS tab bar, Finder/Launch Services opens configured for a new tab, and every “新しいタブで開く” command create a unique `NativeTabRequest`. `AppState` creates a hidden AppKit `NSWindow` with shared SwiftUI browser content and adds it directly to the requesting window’s native tab group before it is shown. No SwiftUI `openWindow` call or provisional visible window is involved. Closing with Command-W closes the selected `NSWindow` tab, while macOS supplies native tab reordering and “Move Tab to New Window” behavior.

Files opened from Finder create a workspace rooted at the containing folder and schedule the file for selection after the first load. Opening multiple Finder items places each additional item in its own native tab, preventing one item from overwriting another.

## Selection and rendering

`FileSelectionController` owns the selected URL set and a lightweight `SelectionFlag` per rendered row. `FileSelectionSurface` observes AppKit mouse-down events before SwiftUI gesture completion, so selection backgrounds update immediately and a context-click selects its target before the menu appears. Ordinary click replaces selection, Command-click toggles, Shift-click uses the ordered item scope as an anchor, and Command-Shift adds a range. The same surface records visible item frames for drag-marquee selection; plain marquee replaces, Command-marquee toggles against the starting selection, and Shift-marquee adds. Only rows whose selected state changed publish an update; the pane and unaffected rows do not redraw. Selected items are resolved from cached URL order and dictionary lookups rather than a full visible-item scan.

The list view presents an expandable tree: a folder row's disclosure triangle fetches its children through `UnifiedFileSystemService` on first expansion, indents descendants by depth, and collapses a folder's descendants when it is folded. Expanded children are reloaded when the pane sort, filter, or root contents change, and the whole expansion state resets on navigation.

## File-system execution and synchronization

Directory enumeration, filtering, sorting, metadata formatting, inspector reads, and mutating file operations run outside the main actor. Stale loads are cancellable. `UnifiedFileSystemService` receives ordinary URLs and routes each operation to the local `FileSystemService` or to a live `RemoteServerSession`. Local roots use `file:` URLs. Direct SFTP/FTP/FTPS/S3 roots use internal `nafi-remote://<profile-id>/<path>` URLs; that URL is an address inside nafi, not a mounted Finder path. The UI does not branch into a second browser: every root is loaded into the same `FilePaneModel`, selection controller, views, native window tabs, sidebar destinations, context menus, and transfer-conflict flow.

Cross-root transfers are selected from the source and destination URL kinds. Local-to-local operations retain native file-system behavior. A same-session remote move uses the server rename operation. Other local/remote or remote/remote combinations stream through a private staging location before the source is removed for a move. Notifications name both affected roots so every matching native window tab or pane reloads. This keeps local and server roots coherent without storing nafi metadata in the browsed directories.

The gallery uses a dedicated fixed-height filmstrip outside the Quick Look preview's layout region. Quick Look therefore cannot compress or scroll the filmstrip away.


## Server connections

`ServerManager` never hands a saved server profile to an external GUI application. SMB, WebDAV, NFS, and AFP are mounted by calling the macOS NetFS framework directly; the returned mount URL is therefore an ordinary local root. SFTP password authentication uses Citadel over SwiftNIO. SFTP private-key authentication is exposed through the same `RemoteServerSession` interface but delegates key parsing and SSH negotiation to macOS OpenSSH, allowing encrypted and unencrypted RSA, Ed25519, ECDSA, FIDO, OpenSSH, PEM, and PKCS#8 keys without opening a GUI application. FTP and FTPS use an in-process SwiftNIO client with NIOSSL; explicit FTPS upgrades the existing control channel after `AUTH TLS`, while implicit FTPS starts TLS before the server greeting. Protected FTPS passive data channels use the same certificate policy as the control channel.

SFTP, FTP, FTPS, and S3-compatible sessions register with `RemoteFileSystemRegistry`. S3/R2 uses a native URLSession Signature V4 client, maps prefixes to folders, performs server-side object copies where possible, and switches to multipart upload for large local files. Their roots are internal `nafi-remote` URLs, and `UnifiedFileSystemService` translates ordinary pane operations into protocol operations. A disconnected remote tab or Favorite can request its profile to reconnect through the registry's connector. No `RemoteServerBrowserView`, Cyberduck handoff, Finder handoff, or protocol-specific browsing window is used.

Passwords, SFTP private-key passphrases, S3 secret access keys, and S3 session tokens remain in Keychain and are passed only to the selected in-process or system-framework connection implementation. Private-key file paths are stored in the profile, but key contents are read only when connecting. `TerminalApplicationService` creates a short-lived executable `.command` file and lets macOS open it with the associated terminal application. Local roots execute a shell in the local directory; SFTP roots execute `ssh -t`, change to the current server path, and start the remote login shell.

## Component tree and view ownership

The UI follows the component tree documented in `COMPONENT_TREE.md`. Feature roots (`SidebarView`, `PaneNavigationBar`, and `SearchResultsView`) are composition-only nodes. Section and row components own rendering, while reusable drag/drop behavior is implemented as modifiers. In particular, the final Favorites insertion target is an overlay on the last row and contributes zero layout height, so its indicator has no spacer above or below it.

Search state belongs to `FilePaneModel`. Current-folder search filters the pane's cached items. Descendant and storage-wide search delegates to `FileSearchService`, which enumerates local roots off the main actor and remote roots through `UnifiedFileSystemService`. Recursive results are rendered as a flat result tree with parent locations so duplicate names remain distinguishable. The same `FileSearchFilter` value is used for folders-only, selected content kinds, and user-specified extension groups.
