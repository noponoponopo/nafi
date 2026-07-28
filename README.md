# nafi — native multi-pane file manager for macOS

nafi is a SwiftUI/AppKit file manager foundation for macOS 14 or later. A workspace starts with one pane. Tabs can be dragged into another pane or dropped on any pane edge to create additional left, right, top, or bottom panes. Split dividers remain draggable through the native macOS split views.

## Implemented in this revision

### Workspace and interaction

- Single-pane startup; splitting is optional rather than assumed
- Recursive pane tree supporting two, three, four, or more panes
- Horizontal and vertical splitting with draggable native dividers
- Tabs in every pane, tab reordering, cross-pane tab movement, and edge-drop splitting
- Mouse-down selection with no click-completion delay; right-click selects its target before the menu opens
- Normal click, Command-toggle, Shift range, Command-Shift additive range, Select All, arrow-key, and Escape behavior
- Finder-style drag-marquee selection in list, matrix, column, and gallery views; Command-drag toggles and Shift-drag adds
- Per-row selection state: clicking invalidates only the rows whose selection changed, not the whole pane
- O(1) selection/range anchors through a displayed-item index instead of repeated full-array scans
- Background directory enumeration, filtering, sorting, metadata formatting, file operations, and inspector reads
- Short-lived shared directory snapshots so several panes do not immediately rescan the same server folder
- Content-type icon caching, debounced search, coalesced file-change notifications, and cancellable stale loads
- Trackpad/Magic Mouse horizontal swipe navigation for Back and Forward
- Drag files to folders, tabs, sidebar destinations, or other panes to move; hold Option while dropping to copy
- Clear insertion markers for tab/sidebar reordering and delayed hover-open for folders, tabs, and sidebar destinations
- Return/Enter starts rename for the selected item
- Cross-tab refresh notifications after local file operations
- Unified system toolbar, adaptive materials, current macOS spacing, rounded selection surfaces, and reduced per-pane chrome

### Browsing

- List, matrix, column, and gallery views sharing the same selection model
- Search, name/date/size/kind sorting, hidden-file toggle, adjustable matrix icon size
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
- SMB, WebDAV, NFS, AFP, FTP, and SFTP connection profiles
- Launch-time auto-connect, reconnect, disconnect, and mounted-volume discovery
- Passwords stored separately in macOS Keychain

### macOS integration

- Registers folders, directories, volumes, and mount points as supported document types
- Settings control to request nafi as the default application for those types and to restore Finder
- Opens folders received from Finder, Services, other apps, or Launch Services in the current tab or a new tab
- Finder Services entry for opening selected files and folders in nafi

### Metadata policy

nafi stores application state under `~/Library/Application Support/nafi` and does not write its own view metadata into browsed folders. It therefore does not create `.DS_Store`; Finder may still create one if the folder is opened in Finder.

## Build

Install Xcode 16 or newer and its command-line tools, then open `Package.swift` in Xcode or run:

```bash
./scripts/build-app.sh
```

The script builds `.build/nafi.app` and applies an ad-hoc signature for local use.

To rebuild after replacing an earlier copy:

```bash
rm -rf .build
./scripts/build-app.sh
```

## Server notes

- Native mounts may trigger a macOS Automation permission prompt.
- Protocol availability and authentication behavior depend on the installed macOS version and server configuration.
- SFTP unattended reconnect uses SSH keys. Automatic SFTP mounting requires macFUSE and `sshfs`; passwords are never placed on a command line.

## Honest scope

This revision provides a substantially redesigned, usable architecture, but it is not literal Finder parity. Remaining production work includes a persistent transfer queue with progress/pause/collision UI, comprehensive Undo/Redo, Spotlight content search and smart folders, Finder comments and full xattr/ACL editing, archive extraction, batch rename, File Provider/cloud integrations, live FSEvents coordination at scale, accessibility/localization audits, notarization, and automated macOS UI tests.
