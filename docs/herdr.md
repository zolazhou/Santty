# Herdr Workspaces

**New Herdr Workspace** creates terminals in the installed local `hc` (herdr-core).
Santty owns their tabs, splits, floating panes and Scroll Mode; core owns the
programs. Switching workspaces or closing Santty leaves Herdr terminals running.
Reopening Santty reattaches the saved terminal addresses, checking the core identity
first. Explicitly closing a pane, tab or workspace ends its Herdr terminals.
Connection errors show a retry action; an uncertain creation is reconciled using
the pane label; a missing ambiguous result never starts a duplicate shell. Core
loss recovery (`keep`) starts a fresh shell, never reruns a lost command. `hc` is
found on PATH, in `~/.local/bin`, or in the standard Homebrew binary directories;
Santty does not install or update it.

The window sidebar also uses local Herdr terminals, independently of the selected
workspace or its remote machine. Its terminal bindings persist and reattach on
reopen; hiding the sidebar leaves the programs running. Explicit pane close ends
the terminal. Older local sidebar sessions restore as placeholders; starting one
creates a new local Herdr terminal without replaying its previous command.

## Remote Workspaces

**New Remote Herdr Workspace…** selects a machine already configured with
`hc machine add`. Terminals run on that machine through the local core proxy;
Santty keeps the layout locally and continues using Ghostty, floating panes and
Scroll Mode. Saved bindings use the permanent remote core ID, so renaming a
machine alias does not replace its terminals. Remote cwd and process metadata
come from core; remote file paths are not opened on this Mac, and remote shells
do not receive Santty's local control socket.

Disconnected machines show their connection status and stop accepting input.
After reconnecting, Santty attaches a fresh screen and exits the old Scroll Mode;
it never replays input typed during a disconnection. Closing a remote pane, tab or
workspace kills its terminals before removing their bindings. A failed close
retains them for retry. Closing Santty only detaches viewers. None of these actions
remove the shared machine connection. Machine setup, SSH login, hc updates and
core settings remain managed through `hc machine`.

## Settings and Diagnostics

**Settings → Herdr** configures the `hc` executable and the history loaded when a
terminal attaches (default 2000 lines, 0 for the current screen only). Paths are
validated before applying; a failed check leaves the current connection intact.
Check Connection and Reconnect show the active core identity and version without
restarting core or ending terminal processes. The panel lists configured remote
machines and can create a workspace on one. Copy Diagnostics includes connection
identity, versions, machine states and the recent error category, excluding
terminal text, environment variables, custom connection commands and raw errors.
Fonts, themes and input sources continue to use Terminal settings.



See [Workspaces](workspaces.md) for layouts and persistence, and [Agents](agents.md) for status tracking and notifications.
