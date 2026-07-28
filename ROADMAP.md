# nafi roadmap after the workspace redesign

## Transfer reliability

- Persistent copy/move queue with progress, pause, resume, cancellation, and collision policy
- NSFileCoordinator integration and a complete Undo/Redo operation journal
- Transfer history, retry controls, checksum verification, and background-safe recovery

## Finder-depth metadata and search

- Spotlight content search, saved searches, and smart folders
- Finder comments, extended attributes, ACL editor, locked flag, and batch permissions
- Batch rename, archive extraction, labels, and richer Get Info editing

## Remote-native layer

- Complete host-key management for password-based SFTP, host fingerprint UI, and resumable SFTP/FTP/FTPS/S3 transfers
- Transfer progress, cancellation, checksum verification, partial-file cleanup, and retry across mixed local/remote roots
- Connection-health monitoring, backoff, server capability detection, symlink semantics, permissions, and remote metadata editing
- S3 multipart-copy optimization, versioned-object UI, storage-class/metadata editing, optional File Provider extension, and additional cloud-provider integrations

## Productization

- FSEvents-backed scalable live updates and very-large-directory performance work
- VoiceOver, keyboard navigation, localization, and visual-density audits
- Hardened Runtime, Developer ID signing, notarization, crash recovery, and test suites
