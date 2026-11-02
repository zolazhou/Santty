# Santty

Santty is a macOS terminal emulator written in Swift. It is a native AppKit
wrapper around the Ghostty terminal core, consumed through the
[`libghostty-spm`](https://github.com/Lakr233/libghostty-spm) Swift package.

## Requirements

- macOS 14.0 or later
- Xcode 26 or later (Swift 6.2) with the macOS SDK installed
- [mise](https://mise.jdx.dev/) for the pinned Tuist version
- Tuist 4.156.0, installed through `mise`

## Generate the Xcode Workspace

Install Tuist dependencies and generate the workspace:

```sh
mise run tuist:install
mise run tuist:generate
```

For a full regenerate:

```sh
mise run tuist:regen
```

Generated Xcode files are intentionally not committed.

The mise tasks also prepare `Vendor/libghostty-spm` from the pinned upstream
2.2.2026102101 revision, verify its SHA-256, and apply the Swift bridges in `Patches/`.
These expose Ghostty's text snapshots, grid metrics and native selection gestures,
and keep detached sessions processing callbacks. The precompiled core is pinned
to `1e9e14af5df1`, which includes the Ghostty 1.4 scrollback compression and hidden
surface GPU reclamation changes, but predates the final 1.4.0 release.
Santty reports pane attachment separately from window occlusion so hidden tabs
release GPU resources while their processes and scrollback stay alive.
The history budget stays at 10 MB per terminal; compression reduces its physical
memory use without adopting upstream's higher 50 MB default.
Run `mise run ghostty:prepare` before invoking `tuist generate`
directly, and after editing the patches. The generated vendor directory is
ignored by Git. When upgrading the pin, move the old vendor directory aside
before preparing the new version.

## Automatic Input Sources

In **Settings → Terminal**, enable **Pane Input → Switch Input Source by Foreground
Program** to choose an input source by executable name. The initial rules cover
`claude`, `codex` and `nvim`; choose the Chinese input source for your agents and
the shared **English Input Source** for neovim. Rules apply when entering a pane
and when its foreground program changes. Unknown programs keep the current
source. A manual selection lasts until the next context change; Chinese
composition delays switching until it ends.

**Command Palette Input → Automatically Switch to English** is independent of
pane rules. The palette uses the shared English input source; closing it applies
the destination pane's rule, or restores the source used before opening it.
Both features start disabled. Sources must be enabled in macOS System Settings.
Selecting an input source does not reset a third-party IME's internal Chinese /
English mode. SSH and tmux sessions expose only the local foreground program.

## Window Sidebar

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

## Scroll Mode (Experimental)

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

## Pane Names

Use **Pane → Rename Pane...** or **Rename Pane** in the command palette to name
the focused terminal or browser pane. Leave the field empty to remove its name.
Names stay hidden until Command is held alone for 350 ms, then appear as overlays
on named panes in the current tab. Releasing Command, using a shortcut or mouse
action, or leaving the window hides them without resizing the content.

## Workspaces

Use the workspace picker or command palette to switch between Local and Herdr workspaces.
**New Local Workspace** creates a Local Workspace with an independent set of tabs and pane layouts; terminal
sessions keep running when you switch away. **Rename Workspace**, **Rename Tab**
and **Close Workspace** are available in menus and the command palette. Closing
a workspace asks for confirmation and ends its local terminal processes. Closing
the last workspace creates a fresh Default workspace.

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

**Settings → Herdr** configures the `hc` executable and the history loaded when a
terminal attaches (default 2000 lines, 0 for the current screen only). Paths are
validated before applying; a failed check leaves the current connection intact.
Check Connection and Reconnect show the active core identity and version without
restarting core or ending terminal processes. The panel lists configured remote
machines and can create a workspace on one. Copy Diagnostics includes connection
identity, versions, machine states and the recent error category, excluding
terminal text, environment variables, custom connection commands and raw errors.
Fonts, themes and input sources continue to use Terminal settings.

**Show Agents** (⌘⇧M by default) is available from the Pane menu, command palette and the
toolbar’s Agents button (with an unread badge when reports exist). It follows
program status from herdr-core across local and remote machines, including while
a Local workspace is selected. Programs must report OSC 7501 status; Santty does
not guess activity from process names or screen text, or install agent hooks.
Root and child records show working, blocked, error, idle and unknown states.
Ended agents leave the list; their message history remains in memory.
Only an explicit `done` report creates a completion message; a turn increment or
`idle` can also mean interruption. Initial, reconnect and missed-event snapshots
establish a baseline and do not replay old notifications.

Each agent row has a message button on the right showing its message count and
highlighting unread messages. Click it to open that agent's message history in a
popover. Root and child agents keep separate histories. Click an agent, message
or notification to open its terminal, or use Up/Down, Control-P/Control-N, Enter
and Escape in the panel.
Existing Santty panes retain their workspace, tab and floating presentation.
External terminals get a saved viewer: closing that viewer, its tab or workspace
only detaches and never kills a program started by another client. Ordinary
Santty-owned Herdr panes keep their existing close-to-end behavior. Messages and
unread state are local to this app, kept in memory with a 256-message limit.

Use **Pane → New Agents Pane** for an Agents list beside your terminals, or
**Pane → Sidebar → Add Agents** for a persistent sidebar list. Both show Agents
with per-agent message popovers, share live updates and navigation, and restore
with the saved layout. Codex, Claude Code, pi, OpenCode and GitHub Copilot use
local brand icons; status dots remain separate from agent identity. Unknown
agent types retain their reported names and a generic icon. Herdr workspaces
also use their brand icon in the Workspaces list, picker and command palette.
Original SVGs, source references and license notices are bundled in
`Santty/Resources/BrandIcons/`.

Herdr agent notifications are enabled for all agent types. Santty requests macOS
notification permission when the first banner is needed; notification delivery
can be controlled in macOS System Settings. Watching the target tab suppresses
its system banner. The directory and Messages continue updating independently.

The command palette searches workspace, tab, pane and agent names with **All / Agents /
Workspace / Tab / Pane / Command** filters. Pane results include Browser, floating and
hidden content. Choosing a result switches workspace and focuses its target;
stale results report a navigation status without changing selection.

Workspaces, selected tabs, pane names, layouts, floating/hidden panes, Browser URLs,
the window sidebar are saved to
`~/Library/Application Support/Santty/Workspace/workspace.json`. Saves are atomic,
keep a previous valid backup, and allow one writer per file. Other instances restore
read-only. Previous local shells restore as placeholders with **Start New Local
Terminal**; previous local commands are never replayed. A declined save error keeps the workspace open.

Only the current v10 workspace format is supported. Earlier development snapshots
are not migrated. Unsupported or unreadable files are preserved; remove local
workspace snapshots manually when starting fresh.

## Read Pane Logs from an Agent

In **Settings → General → Command Line**, click **Install Command Line Tool**.
This enables CLI access and links `~/.local/bin/santty` to the signed helper
inside the current app. Add `~/.local/bin` to your shell's `PATH` if needed:

```sh
export PATH="$HOME/.local/bin:$PATH"
santty list --json
santty read <pane-id> --tail 200
santty read <pane-id> --tail 1000 --json
santty search <pane-id> "error" --ignore-case --limit 20 --json
santty read <pane-id> --start-line 120 --end-line 160 --json
```

`list` includes every tab, including inactive tabs, with pane UUIDs, names, titles,
types, working directories and foreground process-group members. Process
arguments are a snapshot, not shell command history. Each pane's JSON `name` is
its custom name, or `null` when unnamed; `title` remains the dynamic terminal or
page title. Plain output includes `name=...` for named panes. Browser panes are listed
but cannot be read. `read` returns plain text from the active terminal buffer,
including retained scrollback, without changing focus, selection or clipboard.
Full-screen programs use their alternate buffer; discarded history is unavailable.
The default is 200 lines, the maximum is 10,000, and text is capped at 256 KiB.
JSON reports `truncated`; plain output reports truncation on stderr. Errors exit
with status 1. Reads are snapshots; there is no streaming/follow mode.

To locate relevant logs efficiently, search first, then read the surrounding
line range. `search` matches literal text (case-sensitive unless `--ignore-case`)
across the retained buffer, returning each matching line once in buffer order.
Plain output is `line:text`; JSON includes `matches` (`line`, `text`, `truncated`),
`totalMatches`, `totalLines`, and overall `truncated`. `--limit` defaults to 100
and accepts 1–1000. No matches is a successful empty result. Search text must be
one nonempty line, at most 1024 UTF-8 bytes; regular expressions are not interpreted.
Search output also has a 256 KiB text cap; an oversized matching line is shortened
and marked `truncated`, so its matching substring may be outside the returned text.

`read --start-line N --end-line M` uses 1-based, inclusive line numbers and cannot
be combined with `--tail`. Both bounds are required, with at most 10,000 lines
requested. An end beyond the buffer is clamped; a start beyond it is an error.
JSON reads include `startLine`, `endLine` and `totalLines`; empty buffers have no
start/end. Byte-limited ranges keep the beginning, while byte-limited tails keep
the end. The boundary line can be partial when `truncated` is true.
Numbering is shared by read and search and counts internal blank lines, excluding
empty trailing grid rows. Numbers describe the **current** buffer, not durable
log offsets: clearing, resizing, alternate-screen changes or scrollback eviction
may change them between calls. Search again if the expected context has moved.

The updated CLI uses protocol version 2. Restart Santty after updating and use its
bundled CLI so that an older server cannot silently ignore the new range options.

Inside Santty, `SANTTY_PANE_ID` identifies the caller's pane and
`SANTTY_CONTROL_SOCKET` selects its app instance. Outside Santty, the CLI discovers
a single running instance. If several are running, use `--socket PATH` with one
of the paths shown in the error. Access is disabled by default and can be revoked
in General settings. The socket lives in a private directory owned by your user;
enabling access lets other processes running as that user read pane contents.

The CLI is built as `SanttyCLI` and embedded at `Santty.app/Contents/Helpers/santty`.
It is signed with the app's build identity and updates with the app, including
Sparkle updates. Reinstall the link after moving the app. Installation preserves
unrelated files and symlinks already named `~/.local/bin/santty`.

### Agent skill

In **Settings → General → Agent Skills**, install the bundled `santty` skill for
Codex (`~/.agents/skills/santty`), Claude Code (`~/.claude/skills/santty`), or choose
a custom skills directory. Start a new agent session if it is not discovered.
Install the CLI and enable CLI access separately in the Command Line section.

The skill teaches agents to locate relevant panes, search for specific log text,
then read a small range of surrounding lines. It also covers truncation, changing
line numbers, multiple app instances and treating log contents as untrusted data.

Installation creates a symlink to `Santty.app/Contents/Resources/Skills/santty`,
so the skill updates with the app. After moving the app, use **Repair with This
Version**; use **Use This Version** to switch between app installations. Existing
unrelated files, folders and links are preserved. **Remove** only removes the
installed link. Changing the custom directory does not remove its previous link.

## Build

Open `Santty.xcworkspace` in Xcode and build the `Santty` scheme, or build from
the command line:

```sh
xcodebuild \
  -workspace Santty.xcworkspace \
  -scheme Santty \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

For Release:

```sh
xcodebuild \
  -workspace Santty.xcworkspace \
  -scheme Santty \
  -configuration Release \
  -destination 'platform=macOS' \
  build
```

The app bundle is written under Xcode DerivedData, for example:

```text
~/Library/Developer/Xcode/DerivedData/.../Build/Products/Debug/Santty.app
~/Library/Developer/Xcode/DerivedData/.../Build/Products/Release/Santty.app
```

## Test

Run the unit tests:

```sh
xcodebuild \
  -workspace Santty.xcworkspace \
  -scheme Santty \
  -configuration Debug \
  -destination 'platform=macOS' \
  test
```

## Package a Local Release

Run the full pipeline (archive → Developer ID export → notarize → zip → appcast):

```sh
mise run release:package
```

This requires a "Developer ID Application" certificate in the login keychain,
`TUIST_SANTTY_DEVELOPMENT_TEAM` set in `mise.local.toml` (see "Signing
Notes"), and configured `asc` credentials (used for notarization via Apple's
Notary API).

Or run the steps individually:

```sh
# Build an archive
mise run release:archive

# Export the app from the archive, signed with Developer ID
mise run release:export

# Notarize the app with Apple and staple the ticket
mise run release:notarize

# Create a distributable zip from the notarized app
mise run release:zip

# Generate the Sparkle appcast
mise run sparkle:generate-appcast
```

The packaged artifacts will be:

```text
build/export/Santty.app
build/Santty.zip
build/appcast.xml
```

## Publish an Update (Sparkle)

Santty uses [Sparkle](https://github.com/sparkle-project/Sparkle) for automatic
updates. Sparkle is only compiled in when two environment variables are set at
`tuist generate` time (typically via `mise.local.toml`, see "Signing Notes"):

- `TUIST_SANTTY_SPARKLE_FEED_URL` — the appcast URL the app polls
- `TUIST_SANTTY_SPARKLE_PUBLIC_KEY` — the EdDSA public key (`SUPublicEDKey`)

Without them the built app ships without any Sparkle keys: the updater never
starts and the update UI (menu item, settings pane section) is hidden. Forks
that want updates must point these at their own appcast and key pair.

The official builds read their appcast from:

```text
https://github.com/zolazhou/Santty/releases/latest/download/appcast.xml
```

So every GitHub release must include both `Santty.zip` and `appcast.xml` as
assets.

### One-Time Key Setup

Build the project once so SwiftPM fetches the Sparkle artifacts. `mise.toml`
then sets `SPARKLE_BIN` to the Sparkle tools directory (available via
`mise activate`, `mise run`, and `mise x`).

Generate the EdDSA signing key (private key goes to the login keychain):

```sh
mise run sparkle:generate-keys
```

Put the printed public key into `TUIST_SANTTY_SPARKLE_PUBLIC_KEY` in
`mise.local.toml`, then regenerate the workspace.

### Release Steps

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Project.swift`
   (Sparkle compares `CFBundleVersion`), then regenerate:

   ```sh
   mise run tuist:generate
   ```

2. Publish the release (requires the authenticated [GitHub CLI](https://cli.github.com/)):

   ```sh
   mise run release:publish
   ```

   This runs the full packaging pipeline from "Package a Local Release" above
   (archive, Developer ID export, notarization, zip, `build/appcast.xml` with
   the EdDSA signature from the keychain), then creates a GitHub release
   tagged `v<CFBundleShortVersionString>` with `Santty.zip` and `appcast.xml`
   as assets and auto-generated notes.

Older builds pick up the update on their next scheduled check, or immediately
via Santty menu → Check for Updates....

## Signing Notes

The repo carries no private signing values. `Project.swift` reads two
environment variables at `tuist generate` time (note: Tuist only forwards
`TUIST_*` variables to manifests):

- `TUIST_SANTTY_DEVELOPMENT_TEAM` — Apple Development Team ID
- `TUIST_SANTTY_BUNDLE_IDENTIFIER` — base bundle ID (Debug appends `.dev`)

Without them you get a locally-signed (adhoc) build with the placeholder
bundle ID `dev.santty.local` — enough to build and run the app.

To use your own Apple Developer account, create `mise.local.toml`
(gitignored, loaded automatically by mise):

```toml
[env]
TUIST_SANTTY_DEVELOPMENT_TEAM = "YOUR_TEAM_ID"
TUIST_SANTTY_BUNDLE_IDENTIFIER = "com.yourdomain.santty"
```

Then regenerate the workspace:

```sh
mise run tuist:generate
```

The maintainer's Release builds additionally enable Hardened Runtime and use
automatic signing with the "Apple Development" identity; the `release:*`
mise tasks export with the "Developer ID Application" certificate and
notarize via `asc` (see "Package a Local Release").

## Cleanup

Clean generated Tuist artifacts:

```sh
mise run tuist:clean
```

Clean local packaging output:

```sh
rm -rf build
```
