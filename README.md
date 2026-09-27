# nafi

[日本語版](README.ja.md)

nafi is a native multi-pane file manager for macOS 14 or later. It uses SwiftUI and AppKit, keeps browser tabs as real macOS window tabs, and presents local folders and supported remote locations through the same pane and file-operation model. It includes an on-demand rclone runtime that shuts down when idle, Sync Center, incremental sync, a File Provider extension, Drop Stack, Quick Open, named workspaces, login-item support, and shell integration.

## Requirements

- macOS 14 or later
- Xcode 16 or later and the Xcode command-line tools for building
- Homebrew `librsvg` for generating the application icon during a local build; the build continues without the icon when `rsvg-convert` is unavailable

## Build

Build the application bundle with:

```bash
./scripts/build-app.sh
```

The script runs a release build, creates `.build/nafi.app`, signs it with a local development identity when one is available, otherwise uses an ad-hoc signature, and verifies the bundle. Staging builds are not registered with Launch Services, which prevents their File Provider extension from competing with an installed copy. Set `NAFI_REGISTER_BUILD=true` to register the staging app or `NAFI_REVEAL_BUILD=true` to show it in Finder. File Provider continues to share records with the host through the extension's existing application-support directory. If the host cannot safely read and write there, Settings disables Finder publishing without overwriting existing records.

To rebuild from a clean SwiftPM build directory:

```bash
rm -rf .build
./scripts/build-app.sh
```

GitHub Actions builds on `macos-15`, selects Xcode 16.4 when available, and publishes ZIP and DMG artifacts for version tags matching `v*.*.*`.

## Features

### Workspace

- Starts with one pane; split panes are optional.
- Supports recursive horizontal and vertical splits with draggable native dividers.
- Uses the native macOS tab bar for browser tabs, including Command-T, the plus button, selection, reordering, detaching, and closing.
- Keeps one independent workspace per native browser tab and one file model per split pane.
- Supports mouse-down selection, right-click selection, Command-toggle, Shift range selection, Command-Shift additive ranges, Select All, keyboard navigation, Escape, and Finder-style drag-marquee selection.
- Moves dragged files by default and copies them when Option is held.
- Refreshes affected tabs and panes after local or remote file operations.

### Browsing and editing

- Provides list, matrix, column, and gallery views.
- Supports history navigation, parent navigation, direct path entry, mounted-volume browsing, and horizontal swipe navigation.
- Searches the current folder, its descendants, or the entire local volume or remote server.
- Filters search results by folders, content kind, or extension groups. Recursive searches are limited to 5,000 results.
- Sorts by name, modification date, size, or kind, with hidden-file visibility and matrix icon-size controls.
- Provides Quick Look, native file icons, packages, Finder tags, permissions, and file information.
- Provides Quick Edit for supported text and source files up to 8 MiB. It preserves the detected encoding, byte-order mark, and line endings, and checks for external changes before saving.
- Downloads an iCloud Drive item on demand before Quick Edit when macOS has not already downloaded it.

### File operations

- Creates files and folders, renames, batch-renames, duplicates, creates Finder aliases, compresses selected items into ZIP archives, safely extracts ZIP archives, and sends local items to the Trash.
- Opens items normally or with another application, including an application chooser and default-application changes from Get Info.
- Supports copy, cut, paste, drag-and-drop, collision handling, copy-path, Reveal in Finder, and Open Terminal Here.
- Uses the same operation and collision flow for local and supported remote roots. Copy and move jobs are persisted, can be paused, resumed, cancelled, or retried from Settings, and use transactional staging plus size or SHA-256 verification before replacement. Cross-root transfers use a private staging directory when a direct rename is unavailable.
- Uses server-side copy for compatible S3 operations and multipart upload for local files at least 128 MiB in size.

### Servers and cloud storage

| Profile | Connection implementation | Pane representation |
| --- | --- | --- |
| NFS, AFP | macOS NetFS | Mounted local file URL |
| SFTP, FTP/FTPS, SMB, WebDAV, S3, named cloud providers | On-demand rclone runtime | Internal `nafi-remote://` URL |

Supported S3-compatible configurations include AWS S3, Cloudflare R2, MinIO, Ceph, anonymous public buckets, custom HTTPS endpoints, virtual-host or path addressing, prefixes, temporary session tokens, server-side copy, and multipart uploads. Cloudflare R2 uses its account endpoint and the `auto` region.

SMB, WebDAV, NFS, and AFP do not launch Finder or another GUI client. SFTP, FTP, FTPS, and S3-compatible storage do not require macFUSE, `sshfs`, Cyberduck, or another external browser. Local and remote roots can be mixed across native tabs and split panes and can be saved in Favorites.

Additional server behavior:

- Launch-time auto-connect retries each enabled profile up to three times with backoff.
- FTP supports plain FTP, explicit FTPS with `AUTH TLS`, and implicit FTPS. TLS 1.2 or later is required for FTPS, and certificate verification is enabled by default.
- SFTP connections use rclone with host-key verification against `~/.ssh/known_hosts`. Unregistered or changed keys require explicit review before they are trusted.
- Open Terminal Here works for local folders and SFTP roots. FTP and FTPS do not provide an interactive shell.
- Passwords, SFTP key passphrases, S3 secret keys, and temporary S3 session tokens share one authenticated encrypted vault protected by a single macOS Keychain key. Unlock requests are coalesced; legacy credentials that cannot be read without another authorization require explicit re-entry, not repeated prompts. Private-key file contents remain at the selected path and are read only when connecting.

### macOS integration

- Registers folders, directories, volumes, mount points, and common file types with Launch Services.
- Provides Settings controls to request nafi as the default handler for folders, volumes, and mount points, or to restore Finder.
- Opens folders and files received from Finder, Services, other applications, or Launch Services in the current native tab or a new native tab. Files are revealed in their containing folder.
- Provides a Finder Services entry for opening selected files and folders in nafi.
- Detects iCloud Drive automatically and supports a security-scoped bookmark when the user selects a location manually.

## Data and privacy

Application state is stored under `~/Library/Application Support/nafi`:

- `servers.json` stores server profiles without their secret values.
- `credentials.encrypted` stores the authenticated encrypted credential vault; its single encryption key is held in Keychain.
- `sidebar.json` stores sidebar configuration.
- `icloud-drive.bookmark` stores the selected iCloud Drive security-scoped bookmark when one is configured.
- `~/.ssh/known_hosts` stores trusted SFTP host keys.
- `transfers.json` stores the bounded persistent transfer queue and recent terminal history.
- File Provider domain records and temporary rclone runtime discovery live in the extension's application-support directory. Existing records take precedence; only if they are absent does nafi recover from a readable legacy file or registered Finder domains. Legacy Keychain entries are migrated automatically only when readable without additional authorization; otherwise the original items are preserved and the connection editor requests re-entry rather than repeatedly prompting.

nafi does not write its own view metadata into browsed folders and does not create `.DS_Store`. Finder or another application may still create its own metadata. Remote Quick Look, thumbnails, editing, and cross-root transfers may create temporary local staging files while an operation is running.

## Project documentation

- [`ARCHITECTURE.md`](ARCHITECTURE.md): state ownership, native tab flow, file-system execution, and server connections
- [`COMPONENT_TREE.md`](COMPONENT_TREE.md): SwiftUI component and data-flow structure
- [`ROADMAP.md`](ROADMAP.md): planned work grouped by reliability, metadata, remote support, and productization
