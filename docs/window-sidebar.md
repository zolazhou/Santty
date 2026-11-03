# Window Sidebar

Use **Cmd+B**, **Pane → Toggle Sidebar**, or **Toggle Sidebar** in the command palette to open
this window's fixed tool area. It starts on the left with a fresh local terminal.
**Pane → Sidebar** adds Browser, Workspaces or Agents,
and moves the area to either side. Drag its outer divider to change its width;
its internal panes use the same split layout as the main workspace. The sidebar
ends above the bottom Tab toolbar, which spans the full window width.

The sidebar has one internal tab and never appears in the workspace picker or
main tab strip. Switching workspaces keeps its content and layout. Directional
**Focus Left / Right / Above / Below Pane** commands cross between the sidebar
and the main area; Next/Previous Pane stays inside the current area. Pane actions
operate on the focused area, while Tab and Workspace actions target the main
area. Terminal splitting and **Toggle Floating Pane** (**Shift+Cmd+F**) work in
both areas. Sidebar panes float at the center of the window and return to their
original slot when toggled again; hiding the sidebar also returns them. Detaching
remains a main-area action. When a sidebar pane has no internal horizontal split,
**Move Divider Left / Right** (**Shift+Cmd+H / L**) adjusts the sidebar's width.
**New Terminal Pane**, **New Browser Pane**, **New Agents Pane**
and **New Workspaces Pane** split the focused pane side by side when it is wider
than it is tall (including square panes), or stack panes when it is taller.
Explicit **Split Horizontally / Vertically** commands keep their chosen direction.

Hiding the sidebar preserves its content. Closing its final pane hides it;
opening an empty sidebar creates a fresh local terminal. Position, preferred
width, pane layout and Browser URLs restore with the window. Restored local
terminals ask you to start a new shell, just like those in the main workspace.
Customize the Toggle Sidebar shortcut in **Settings → Keybindings**.
