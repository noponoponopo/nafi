# nafi — native multi-pane file manager for macOS

nafi is a SwiftUI/AppKit file manager foundation for macOS 14 or later. A workspace starts with one pane. Tabs can be dragged into another pane or dropped on any pane edge to create additional left, right, top, or bottom panes. Split dividers remain draggable through the native macOS split views.

## Implemented in this revision

### Workspace and interaction

- Single-pane startup; splitting is optional rather than assumed
- Recursive pane tree supporting two, three, four, or more panes
- Horizontal and vertical splitting with draggable native dividers
- Native macOS window tabs with system tab reordering, detaching, closing, and the standard tab-bar plus button
- Mouse-down selection with no click-completion delay; right-click selects its target before the menu opens
- Normal click, Command-toggle, Shift range, Command-Shift additive range, Select All, arrow-key, and Escape behavior
- Finder-style drag-marquee selection in list, matrix, column, and gallery views; Command-drag toggles and Shift-drag adds
- Per-row selection state: clicking invalidates only the rows whose selection changed, not the whole pane
- O(1) selection/range anchors through a displayed-item index instead of repeated full-array scans
- Background directory enumeration, filtering, sorting, metadata formatting, file operations, and inspector reads
- The same native window-tab, pane, sidebar, selection, and file-operation model for local and remote roots
- Content-type icon caching, debounced search, coalesced file-change notifications, and cancellable stale loads
- Trackpad/Magic Mouse horizontal swipe navigation for Back and Forward
- Drag files to folders, sidebar destinations, or other panes to move; hold Option while dropping to copy
- Clear insertion markers for sidebar reordering and delayed hover-open for folders and sidebar destinations
- Return/Enter starts rename for the selected item
- Cross-window-tab and cross-pane refresh notifications after local or remote file operations
- Unified system toolbar, adaptive materials, current macOS spacing, rounded selection surfaces, and reduced per-pane chrome

### Browsing

- List, matrix, column, and gallery views sharing the same selection model
- Search in the current folder, the current hierarchy, or the whole volume/server
- Search filtering for folders, selected content kinds, or arbitrary extension groups
- Name/date/size/kind sorting, hidden-file toggle, adjustable matrix icon size
- History navigation, parent navigation, direct path entry, and mounted-volume browsing
- Quick Look panel and embedded gallery preview with a fixed, non-collapsing filmstrip
- Quick Edit directly below Quick Look for text files up to 8 MB, preserving detected encoding and line endings with external-change conflict checks
- iCloud Drive sidebar access with automatic location detection, bookmark fallback, and on-demand download before Quick Edit
- Native file icons, packages, Finder tags, and file information including POSIX permissions

### File operations

- Create an empty file or folder from the context menu
- Open, Open With for files and folders, an “Other…” application chooser, per-item default-app changes and extension-wide default-app changes from Get Info, show package contents, rename, duplicate, create Finder aliases, copy, cut, paste, move, Trash
- Multi-item ZIP creation, Quick Look, copy path, Reveal in Finder, and Open Terminal Here
- Defensive cross-volume move fallback with rollback when source removal fails

### Sidebar and servers

- Sidebar minimum/ideal/maximum widths to prevent collapsed layouts
- Full-row hit targets for favorites, volumes, servers, and footer actions
- Stable top spacing before the first sidebar section and clear row backgrounds
- Custom section visibility, favorite rename/remove/reorder, and current-folder insertion
- SMB, WebDAV, NFS, AFP, FTP/FTPS, SFTP, and S3-compatible connection profiles
- SMB, WebDAV, NFS, and AFP connections initiated directly through macOS NetFS without launching Finder or another GUI app
- SFTP, FTP, FTPS, AWS S3, Cloudflare R2, MinIO, Ceph, and other Signature V4-compatible object stores appear as ordinary roots in the same native window tabs and split panes as local folders; there is no separate server browser
- Local-to-server, server-to-local, and server-to-server drag, copy, move, rename, create-folder, delete, duplicate, ZIP, Quick Look, and Quick Edit flows use the same commands and collision dialog, including S3/R2 buckets and prefixes
- Remote and local roots can be mixed across native window tabs and split panes and saved in Favorites
- “Open Terminal Here” works for local folders and SFTP roots; SFTP opens SSH at the current remote path
- Launch-time auto-connect, reconnect, disconnect, and mounted-volume discovery
- Passwords, SFTP key passphrases, S3 secret keys, and temporary S3 session tokens stored separately in macOS Keychain

### macOS integration

- Registers folders, directories, volumes, mount points, and ordinary files as supported document types
- Settings control to request nafi as the default application for those types and to restore Finder
- Opens folders received from Finder, Services, other apps, or Launch Services in the current native window tab or a new native window tab
- Accepts arbitrary files (including HTML, source, text, images, media, archives, and PDF) and reveals them in their containing folder
- Uses only the native macOS window tab bar; Command-T, its plus button, tab selection, tab closing, reordering, and detaching all operate on real NSWindow tabs whose titles follow the active folder
- Finder open events are attached directly to the currently visible native tab group without creating or repositioning a temporary two-tab window
- Finder Services entry for opening selected files and folders in nafi

### Metadata policy

nafi stores application state under `~/Library/Application Support/nafi` and does not write its own view metadata into browsed folders. It therefore does not create `.DS_Store`; Finder may still create one if the folder is opened in Finder.

## Build

Install Xcode 16 or newer and its command-line tools, then open `Package.swift` in Xcode or run:

```bash
./scripts/build-app.sh
```

The script builds `.build/nafi.app`.

To rebuild after replacing an earlier copy:

```bash
rm -rf .build
./scripts/build-app.sh
```

## Server notes

- Server connections no longer launch Finder, Cyberduck, or another external GUI application.
- SMB, WebDAV, NFS, and AFP use the macOS NetFS framework from inside nafi and appear as mounted folders in ordinary panes.
- SFTP, FTP, FTPS, and S3-compatible storage are represented as internal remote roots and are rendered by the ordinary `FilePaneModel`, so local and remote roots can be mixed freely across native window tabs and split panes. They do not require macFUSE, sshfs, Cyberduck, Finder, or another GUI client application.
- SFTP password authentication uses the in-process SSH/SFTP client. Private-key authentication uses the macOS OpenSSH engine without opening another application, supporting the key formats and algorithms accepted by the installed macOS OpenSSH, including RSA, Ed25519, ECDSA, FIDO/security-key, OpenSSH, PEM, and PKCS#8 keys with or without a passphrase. Key passphrases are stored in Keychain; the key file itself remains at the selected path.
- FTP supports plain FTP, explicit FTPS (`AUTH TLS`), and implicit FTPS. FTPS encrypts both control and passive data connections and validates the server certificate by default.
- S3-compatible roots support AWS Signature Version 4, arbitrary HTTPS endpoints, AWS S3 virtual-host addressing, R2/MinIO-style path addressing, access-key/secret authentication, temporary session tokens, anonymous public buckets, prefix navigation, server-side copy, and multipart uploads. Cloudflare R2 uses its account endpoint and the `auto` region.
- Copy, move, drag-and-drop, collision handling, native window tabs, split panes, Favorites, Quick Look, and text Quick Edit operate across local and remote roots. Cross-protocol transfers are staged internally when the two endpoints cannot rename directly.
- “Open Terminal Here” creates a temporary `.command` file and asks macOS to open it with the application associated with that type. For SFTP, the command starts `ssh` and changes to the displayed remote directory; FTP/FTPS do not expose an interactive shell.
- Private-key SFTP stores host keys in `~/Library/Application Support/nafi/known_hosts`, accepts a previously unseen host once, and rejects changed host keys. Password-based SFTP still needs the same host-key management migration.
- Protocol availability and authentication behavior still depend on the installed macOS version and server configuration.

## Honest scope

This revision provides a substantially redesigned, usable architecture, but it is not literal Finder parity. Remaining production work includes a persistent transfer queue with progress/pause UI, comprehensive Undo/Redo, resumable and checksum-verified remote transfers, SSH host-key management, Spotlight content search and smart folders, Finder comments and full xattr/ACL editing, archive extraction, batch rename, File Provider/cloud integrations, live FSEvents coordination at scale, accessibility/localization audits, notarization, and automated macOS and real-server integration tests.
