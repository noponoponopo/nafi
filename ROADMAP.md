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

- Direct SFTP browser without a mount helper
- Connection-health monitoring, backoff, per-server bookmarks, and capability detection
- Optional File Provider extension and cloud-provider integrations

## Productization

- FSEvents-backed scalable live updates and very-large-directory performance work
- VoiceOver, keyboard navigation, localization, and visual-density audits
- Hardened Runtime, Developer ID signing, notarization, crash recovery, and test suites
