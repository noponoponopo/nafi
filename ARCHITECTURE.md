# Nami architecture

## State hierarchy

`AppState` owns the `WorkspaceModel`, sidebar state, settings, and server manager. `WorkspaceModel` owns a recursive `PaneLayoutNode` tree and a dictionary of `PaneSession` objects. Every `PaneSession` owns one or more `FilePaneModel` tabs. A `FilePaneModel` owns navigation, display, selection, and file-operation state for exactly one tab.

This hierarchy prevents one pane's navigation or selection from leaking into another pane while allowing the native toolbar to observe the active pane and active tab.

## Pane and tab drag flow

Tabs use a typed `Transferable` payload. Dropping on a tab strip inserts or reorders the tab. Dropping on a 12-point edge target asks `WorkspaceModel` to replace the target leaf with a new split node. A source pane with multiple tabs transfers the model; a source pane with only one tab clones it so the pane tree never becomes invalid.

Files use a separate typed payload. Drops resolve to the target folder represented by a pane or directory row. Copy is the default; Command-drag requests a move.

## Selection and rendering

`FileSelectionController` owns the selected URL set and a lightweight `SelectionFlag` per rendered row. `FileSelectionSurface` observes AppKit mouse-down events before SwiftUI gesture completion, so selection backgrounds update immediately and a context-click selects its target before the menu appears. Ordinary click replaces selection, Command-click toggles, Shift-click uses the ordered item scope as an anchor, and Command-Shift adds a range. The same surface records visible item frames for drag-marquee selection; plain marquee replaces, Command-marquee toggles against the starting selection, and Shift-marquee adds. Only rows whose selected state changed publish an update; the pane and unaffected rows do not redraw. Selected items are resolved from cached URL order and dictionary lookups rather than a full visible-item scan.

## File-system execution and synchronization

Directory enumeration, filtering, sorting, metadata formatting, inspector reads, and mutating file operations run outside the main actor. Stale loads are cancellable. A short-lived shared snapshot cache avoids duplicate immediate scans when several panes show the same local or server directory, while change notifications are coalesced before affected tabs reload. This keeps multiple panes coherent without storing metadata inside the folders being browsed.

The gallery uses a dedicated fixed-height filmstrip outside the Quick Look preview's layout region. Quick Look therefore cannot compress or scroll the filmstrip away.
