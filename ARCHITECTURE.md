# nafi architecture

## State hierarchy

`AppState` owns the `WorkspaceModel`, sidebar state, settings, and server manager. `WorkspaceModel` owns a recursive `PaneLayoutNode` tree and a dictionary of `PaneSession` objects. Every `PaneSession` owns one or more `FilePaneModel` tabs. A `FilePaneModel` owns navigation, display, selection, and file-operation state for exactly one tab.

This hierarchy prevents one pane's navigation or selection from leaking into another pane while allowing the native toolbar to observe the active pane and active tab.

## Pane and tab drag flow

Tabs use a typed `Transferable` payload. Dropping on a tab strip inserts or reorders the tab. Dropping on a 24-point edge target asks `WorkspaceModel` to replace the target leaf with a new split node. A source pane with multiple tabs transfers the model; a source pane with only one tab clones it so the pane tree never becomes invalid.

Files use a separate typed payload. Drops resolve to the target folder represented by a pane or directory row. Move is the default; holding Option at the destination requests a copy. Folder, tab, pane-edge, and sidebar targets expose visible destination indicators, and hover targets activate after a short delay.

## Selection and rendering

`FileSelectionController` owns the selected URL set and a lightweight `SelectionFlag` per rendered row. `FileSelectionSurface` observes AppKit mouse-down events before SwiftUI gesture completion, so selection backgrounds update immediately and a context-click selects its target before the menu appears. Ordinary click replaces selection, Command-click toggles, Shift-click uses the ordered item scope as an anchor, and Command-Shift adds a range. The same surface records visible item frames for drag-marquee selection; plain marquee replaces, Command-marquee toggles against the starting selection, and Shift-marquee adds. Only rows whose selected state changed publish an update; the pane and unaffected rows do not redraw. Selected items are resolved from cached URL order and dictionary lookups rather than a full visible-item scan.

The list view presents an expandable tree: a folder row's disclosure triangle fetches its children through `UnifiedFileSystemService` on first expansion, indents descendants by depth, and collapses a folder's descendants when it is folded. Expanded children are reloaded when the pane sort, filter, or root contents change, and the whole expansion state resets on navigation.

## File-system execution and synchronization

Directory enumeration, filtering, sorting, metadata formatting, inspector reads, and mutating file operations run outside the main actor. Stale loads are cancellable. `UnifiedFileSystemService` receives ordinary URLs and routes each operation to the local `FileSystemService` or to a live `RemoteServerSession`. Local roots use `file:` URLs. Direct SFTP/FTP/FTPS/S3 roots use internal `nafi-remote://<profile-id>/<path>` URLs; that URL is an address inside nafi, not a mounted Finder path. The UI does not branch into a second browser: every root is loaded into the same `FilePaneModel`, selection controller, views, tab strip, sidebar destinations, context menus, and transfer-conflict flow.

Cross-root transfers are selected from the source and destination URL kinds. Local-to-local operations retain native file-system behavior. A same-session remote move uses the server rename operation. Other local/remote or remote/remote combinations stream through a private staging location before the source is removed for a move. Notifications name both affected roots so every matching tab or pane reloads. This keeps local and server roots coherent without storing nafi metadata in the browsed directories.

The gallery uses a dedicated fixed-height filmstrip outside the Quick Look preview's layout region. Quick Look therefore cannot compress or scroll the filmstrip away.


## Server connections

`ServerManager` never hands a saved server profile to an external GUI application. SMB, WebDAV, NFS, and AFP are mounted by calling the macOS NetFS framework directly; the returned mount URL is therefore an ordinary local root. SFTP password authentication uses Citadel over SwiftNIO. SFTP private-key authentication is exposed through the same `RemoteServerSession` interface but delegates key parsing and SSH negotiation to macOS OpenSSH, allowing encrypted and unencrypted RSA, Ed25519, ECDSA, FIDO, OpenSSH, PEM, and PKCS#8 keys without opening a GUI application. FTP and FTPS use an in-process SwiftNIO client with NIOSSL; explicit FTPS upgrades the existing control channel after `AUTH TLS`, while implicit FTPS starts TLS before the server greeting. Protected FTPS passive data channels use the same certificate policy as the control channel.

SFTP, FTP, FTPS, and S3-compatible sessions register with `RemoteFileSystemRegistry`. S3/R2 uses a native URLSession Signature V4 client, maps prefixes to folders, performs server-side object copies where possible, and switches to multipart upload for large local files. Their roots are internal `nafi-remote` URLs, and `UnifiedFileSystemService` translates ordinary pane operations into protocol operations. A disconnected remote tab or Favorite can request its profile to reconnect through the registry's connector. No `RemoteServerBrowserView`, Cyberduck handoff, Finder handoff, or protocol-specific browsing window is used.

Passwords, SFTP private-key passphrases, S3 secret access keys, and S3 session tokens remain in Keychain and are passed only to the selected in-process or system-framework connection implementation. Private-key file paths are stored in the profile, but key contents are read only when connecting. `TerminalApplicationService` creates a short-lived executable `.command` file and lets macOS open it with the associated terminal application. Local roots execute a shell in the local directory; SFTP roots execute `ssh -t`, change to the current server path, and start the remote login shell.
