# Scroll Mode (Experimental)

Press **Shift-Command-S** to navigate and select within Ghostty's current viewport
and retained scrollback. Ghostty keeps rendering the terminal and selection,
preserving ANSI colors, fonts and grid layout. A transparent overlay adds a
keyboard cursor. Output remains live; entry and exit keep the current viewport.

| Key                      | Action                                                                     |
| ------------------------ | -------------------------------------------------------------------------- |
| `h/j/k/l` or arrow keys  | Move the cursor                                                            |
| `0` / `$`                | Beginning / end of the displayed line                                      |
| `^`                      | First nonblank cell of the displayed line                                  |
| `w` / `b` / `e`          | Next word start / previous word start / word end (punctuation is separate) |
| `W` / `B` / `E`          | Same motions for whitespace-delimited words                                |
| `Ctrl-U/D`               | Move half a page                                                           |
| `Ctrl-B/F`, Page Up/Down | Move a page                                                                |
| `gg` / `G`, Home/End     | Beginning / end of the retained buffer                                     |
| `v` / `V`                | Toggle character / whole displayed row selection                           |
| `y` or Command-C         | Copy, preserving mode, selection, cursor and scroll position               |
| Escape                   | Cancel selection, then exit on the next press                              |
| `q`, `i` or Return       | Exit scroll mode                                                           |

Mouse selection and scrolling are supported. Switching panes or tabs exits the
mode; an empty selection leaves the clipboard unchanged. Mouse reporting and
click actions are disabled while in this mode so selection cannot send input
to a running TUI or move the shell's input cursor.
Word motions also extend an active selection. They treat displayed row breaks
(including soft wraps) as word boundaries and skip blank rows.

Resizing cancels the selection because text may reflow. This prototype tracks
row indices: if ongoing output evicts old scrollback, its cursor and selection
anchor may drift. Stable anchors require additional support from the core.
