# nafi roadmap

This roadmap separates the reliability baseline implemented in the current workspace from larger platform and product work that still requires dedicated UI, extension targets, infrastructure, or release credentials. Current behavior is documented in [`README.md`](README.md) and [`README.ja.md`](README.ja.md).

## Completed reliability baseline

- Persistent copy and move queue with progress, pause, resume, cancellation, retry controls, bounded history, startup recovery, and corruption quarantine
- Transactional local and remote replacement, SHA-256 or size verification, source deletion only after commit, partial-file cleanup, and non-destructive rollback
- Safe ZIP extraction with traversal, absolute-path, symlink, Unicode-collision, entry-count, expanded-size, compression-ratio, free-space, and post-extraction tree validation
- Transactional local and remote batch rename, including swaps, case-only changes, extension preservation, collision checks, and rollback
- Explicit SFTP host-fingerprint scan and trust management for both password and private-key authentication; unknown or changed keys are rejected
- Bounded and cancellable external processes, FTP replies/listings, S3 control responses and pagination, and application-owned JSON persistence
- Atomic profile, Keychain, sidebar, bookmark, and transfer-queue updates with rollback or corrupt-file quarantine
- Unit tests for URL/path normalization, archive rejection, batch naming, integrity checks, process limits, non-finite settings, and rclone job validation, plus a CI test gate before the macOS build
- Replicated File Provider extension with enumeration, materialization, mutations, change snapshots, transaction recovery, strict version identity, task cancellation, and bounded runtime communication

## Remaining file-system depth

- `NSFileCoordinator` coverage for every mutating local operation and a complete durable Undo/Redo operation journal
- Spotlight content search, saved searches, and smart folders
- Finder comments, arbitrary extended attributes, ACL editing, locked-state editing, batch ownership and permissions, and richer Get Info editing
- Profiling, adaptive backpressure, and memory tuning for FSEvents and directory snapshots with hundreds of thousands of entries

## Remaining remote-native depth

- Protocol-native resumable transfer and remote checksum negotiation for SFTP, FTP/FTPS, and S3 instead of whole-item retry
- Connection-health monitoring, jittered backoff, capability discovery, remote symlink policy, permissions, timestamps, and metadata editing
- S3 multipart-copy, versioned-object browsing and restore, storage-class editing, object metadata, and lifecycle visibility
- File Provider fault-injection, provider-specific compatibility matrices, and additional cloud-provider integrations; these require disposable test environments and production signing/provisioning

## Remaining productization

- Full VoiceOver, keyboard-navigation, localization, high-contrast, reduced-motion, and visual-density audits
- Hardened Runtime, Developer ID signing, notarization, Sparkle or equivalent update delivery, symbol upload, and production crash reporting; release credentials are required
- Automated macOS UI tests and integration matrices against disposable SFTP, FTP, FTPS, WebDAV, SMB, NFS, S3, and failure-injection servers
- Performance, power, memory-pressure, disk-full, sleep/wake, network-change, and multi-window soak testing on supported macOS hardware
