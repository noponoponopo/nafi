# nafi component tree

The SwiftUI surface is organized as a component tree rather than as feature-sized monolithic view files.

## Rules

1. **Feature roots compose; they do not implement leaf behavior.** A root view chooses sections and passes dependencies or actions downward.
2. **State lives at the lowest common owner.** App-wide navigation remains in `AppState`; pane search/navigation state remains in `FilePaneModel`; transient hover, popover, and editing state stays in the leaf view that renders it.
3. **Containers observe models; leaves receive values and actions.** This keeps presentation components testable and prevents environment dependencies from spreading through the tree.
4. **Reusable interaction behavior is a modifier.** File drops, favorite reorder targets, and the zero-layout end insertion target are modifiers rather than spacer rows.
5. **A component owns one reason to change.** Search controls, result rendering, sidebar rows, reorder behavior, and customization UI are separate source files.
6. **Cross-feature operations go through models/services.** Views do not enumerate storage, access Keychain, or perform remote operations directly.

## Main window

```text
RootView
└─ RootViewContent
   ├─ SidebarView
   │  ├─ SidebarFavoritesSection
   │  │  ├─ SidebarSectionHeader
   │  │  └─ SidebarDestinationRow
   │  │     └─ SidebarReorderEndDropOverlay
   │  ├─ SidebarICloudSection
   │  ├─ SidebarVolumesSection
   │  ├─ SidebarServersSection
   │  │  └─ ServerSidebarRow
   │  └─ SidebarFooter
    └─ WorkspaceView
       └─ PaneHostView
          └─ FilePaneView
             ├─ PaneSplitDropOverlay
             ├─ PaneNavigationBar
             │  ├─ PanePathControl
             │  ├─ PaneSearchControl
             │  │  └─ FileSearchOptionsPopover
             │  └─ PaneDisplayOptionsMenu
             ├─ SearchResultsView (recursive/global search)
             │  ├─ SearchResultsHeader
             │  └─ SearchResultRow
             ├─ FileListView / FileMatrixView / FileColumnBrowserView / FileGalleryView
             └─ FilePaneStatusBar
```

## Search data flow

```text
PaneSearchControl
└─ FilePaneModel
   ├─ current-folder query → in-memory arrange/filter
   └─ recursive/global query → FileSearchService
      ├─ local FileManager enumerator
      └─ UnifiedFileSystemService for remote roots
```

`FileSearchFilter` is a value object shared by the in-memory and recursive search paths, so folders, selected content kinds, and extension groups behave consistently.
