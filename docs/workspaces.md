# Workspaces

Use the workspace picker or command palette to switch between Local and Herdr workspaces.
**New Local Workspace** creates a Local Workspace with an independent set of tabs and pane layouts; terminal
sessions keep running when you switch away. **Rename Workspace**, **Rename Tab**
and **Close Workspace** are available in menus and the command palette. Closing
a workspace asks for confirmation and ends its local terminal processes. Closing
the last workspace creates a fresh Default workspace.



## Persistence

Workspaces, selected tabs, pane names, layouts, floating/hidden panes, Browser URLs,
the window sidebar are saved to
`~/Library/Application Support/Santty/Workspace/workspace.json`. Saves are atomic,
keep a previous valid backup, and allow one writer per file. Other instances restore
read-only. Previous local shells restore as placeholders with **Start New Local
Terminal**; previous local commands are never replayed. A declined save error keeps the workspace open.

Only the current v10 workspace format is supported. Earlier development snapshots
are not migrated. Unsupported or unreadable files are preserved; remove local
workspace snapshots manually when starting fresh.

See [Herdr Workspaces](herdr.md) for persistent local and remote terminals.
