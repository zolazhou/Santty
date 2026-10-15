# Santty

Santty is a macOS terminal emulator written in Swift. It is a native AppKit
wrapper around the Ghostty terminal core, consumed through the
[`libghostty-spm`](https://github.com/Lakr233/libghostty-spm) Swift package.

## Requirements

- macOS 14.0 or later
- Xcode with the macOS SDK installed
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
1.3.1 revision, verify its SHA-256, and apply the Swift bridges in `Patches/`.
These expose Ghostty's text snapshots, grid metrics, scrollbar callbacks and
native selection gestures; the C core remains the upstream precompiled
XCFramework. Run `mise run ghostty:prepare` before invoking `tuist generate`
directly, and after editing the patches. The generated vendor directory is
ignored by Git.

## Notes

Press **Control-Option-N** from any app to open Notes. The shortcut focuses an
already-visible note, or saves and hides it when Notes has keyboard focus.
You can also use **Santty → Notes** or **Notes** in the command palette.
Customize the global shortcut in **Settings → Keybindings → Application**.
Double-click the shortcut to record a replacement, press Delete while recording
to clear it, or right-click its displayed value and choose **Reset to Default**.

Notes uses a native TextKit 2 editor with live Markdown styling, links, lists,
code blocks, and clickable `- [ ]` / `- [x]` task checkboxes. Markdown markers
appear when editing the corresponding text. Standard copy, paste, undo, redo,
spelling, grammar, and system Writing Tools are supported where available.
Parsing uses `swift-markdown`; Santty owns the text styling and TextKit 2 block
decorations. The editor shares SwiftUI's single scrolling viewport. On macOS 26
and later, the header and footer use `safeAreaBar` with the system's soft scroll
edge effect.
Syntax outside the formatting toolbar's supported set remains editable source.
Press **Command-Shift-P** to open or close the note browser. Use **Control-P** /
**Control-N** or the arrow keys to select a note, then Return to open it.

Use **Pane → Open Notes in Pane** or the command palette to open Notes beside
another pane. Multiple Notes panes can coexist with the standalone Notes window;
each selects its own note and keeps its own cursor and scroll position. Notes
panes remain visible when focus changes and support the usual pane layout controls.

The standalone Notes window hides when it loses focus. Click the pin button to keep it visible above
other apps; use this mode with external correction tools that activate their
own windows. Escape, Command-W, or the close button saves and hides Notes.
Input-method composition and active Writing Tools sessions take precedence.
Hiding preserves the editor's selection, scroll position, and undo history.

Each note is a separate UTF-8 `.md` file, saved after a short typing pause and
before switching, closing, or quitting. Release builds use
`~/Library/Application Support/Santty/Notes/`; Debug builds use
`~/Library/Application Support/Santty-Dev/Notes/`. An existing `note.md` is kept.
Read failures disable
editing to protect the existing file; write failures preserve the in-memory note
and provide a retry action. Unsaved changes prevent a normal quit until saving
succeeds or quitting is cancelled. Window geometry and pin state are local.
The standalone Notes window stays hidden on launch and is available while Santty
is running. Notes watches both the current file and its directory: saved changes
from another pane, the window, or an external editor refresh idle views. External
updates clear the affected editor's undo history. If local changes are unsaved,
or the file is deleted, Notes retains the text and pauses saving until you choose
**Use File Version** or **Overwrite File**. Simultaneous edits are not merged.

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
action, or leaving the window hides them without resizing the content. In Herdr workspaces, pane names follow backend labels, including external renames and name removal.

## Persistent Terminals with Herdr (Experimental)

The command palette also searches workspaces, tabs and panes across local and discovered Herdr workspaces. Use the **All / Workspace / Tab / Pane / Command** filters, or type a name and its workspace (for example, `Santty logs`). Results show their owning workspace/tab and mark the current selection. Empty All searches show workspaces, current-workspace tabs and commands; the Pane filter lists panes, including Notes, Browser, floating and hidden content. Choosing a target switches its workspace and focuses it after the matching ClientShell layout is ready. Searching does not attach terminals or start Herdr. The palette keeps the search and selected result while metadata updates; deleted targets and changed connections are rejected with a non-modal navigation status.

The bottom-left workspace picker presents **Local Workspace**, **Herdr Workspace**, and **Remote Herdr Workspace** together. Santty opens local content immediately and discovers local Herdr workspaces and enabled saved SSH machines in the background. **New Workspace** creates a local workspace with its own tabs and pane layouts, named Workspace 1, Workspace 2, and so on. Switch between all three workspace types in the picker or command palette; local terminal sessions keep running while another workspace is displayed. **Rename Workspace** changes the selected local or Herdr workspace name; **Rename Tab** changes the selected tab title (leave it empty for an automatic title). Both commands are in the command palette and menus, with configurable shortcuts. Local workspace names, layouts and the last selected local workspace are saved and restored. Workspace types use distinct icons; remote entries also show their machine label. Workspace, tab and pane IDs are scoped to their endpoint, so identical server IDs on different machines remain separate.

Configure the executable, session and API socket in **Settings → General → Herdr Workspaces**. **Apply and Refresh Workspaces** validates and saves the settings, then refreshes discovery. Changing the local connection returns local Herdr views to the last selected local workspace. Select an installed compatible Herdr executable and the absolute API socket path of an already running service (protocol 22). The executable suggestion checks `~/.local/bin/herdr`, `/opt/homebrew/bin/herdr` and `/usr/local/bin/herdr`; it does not depend on the launching shell’s PATH. The existing session name is descriptive; the explicit socket routes both management and terminal clients. ClientShell is the only terminal transport. Local terminal and management connections use sockets; its endpoint protocol is negotiated separately, while management queries require API protocol 22. Local connections attach to an existing service. Remote connections use the native `remote-client-bridge` over OpenSSH stdio, with `remote-api-bridge` for management queries. The native remote bridge may start the server from an existing compatible installation; background connections do not install, upgrade, replace or stop it. An unavailable source leaves local workspaces usable.

Use **Pane → Add Remote Herdr Machine...** to run `herdr machine add` in a local terminal. Herdr handles SSH authentication, remote session discovery, and installation/replacement confirmations. Existing profiles from `herdr machine list --json` appear automatically; one profile targets one remote session. **Pane → Authenticate Remote Herdr Machine...** runs `herdr machine reconnect` for a saved profile. SSH config, ssh-agent, host-key checks, and Herdr's scoped shared authentication connection are reused; Santty stores no passwords or private keys. Removing or disabling a profile disconnects its source and leaves its server processes running.

Remote interruptions retain the last displayed scene with input disabled. Connections use native health checks, compression and exponential retry delays up to two minutes. A reconnect cannot take selection away from another workspace, and an operation with an unknown result is never replayed. You can return to a local workspace while a remote switch or reconnect is pending. See [the remote implementation and verification notes](docs/plans/remote-herdr-workspaces.md).

Tabs, panes, binary splits, proportions and backend zoom follow the selected Herdr workspace. Focus and divider drags synchronize with Herdr, with each client keeping its own selection. Notes and Browser panes remain available in a local area beside the backend terminal tree. Local panes support splitting, rearrangement, floating, hiding and automatic focus resizing. Floating a Herdr terminal creates an idle placeholder in its original layout and moves the same running terminal into a separate backend tab. A second native ClientShell connection sizes that tab independently; Santty hides the helper tab from its tab strip and search, while other Herdr clients can see it. Returning the terminal restores its original slot and closes the placeholder. Hidden terminals keep their existing backend grid. Workspace switches preserve local auxiliary panes with their Herdr workspace, including when returning to a local workspace. If a backend tab disappears, its auxiliary panes are recovered into the last selected local workspace. Focusing local content does not send terminal focus commands; returning to a terminal synchronizes focus. **New Herdr Workspace** creates and selects a new backend workspace with an initial terminal. Actions can be assigned shortcuts in Keybindings settings.

Each discovered endpoint keeps a ClientShell connection. Selecting a workspace activates its text/image scenes and semantic input; other endpoints continue updating metadata without streaming pane screens. Its pane presentation uses the public backend pane identity; history and process information use a separately verified runtime mapping. History and process queries resolve a missing mapping on demand; an unconfirmed identity disables only the query. Agent metadata and semantic notifications continue on these connections while local content is selected. Leaving a Herdr workspace deactivates its surface interest and preserves the connection for later activation. Disconnection marks status unavailable and retains messages and unread markers; input resumes after a fresh coherent presentation. Floating transfers animate the existing scene immediately while the native transfer runs; input resumes when the new native surface is ready. Returning a pane keeps it selected and synchronizes that selection with Herdr. They require a verified management runtime mapping; changed identities or rejected operations retain the terminal and report an error. Native popups inside floating tabs are currently unsupported; return the pane to its tab before opening one. **Take Control of Herdr Window** reconnects through ClientShell and claims the current tab geometry through an endpoint focus request; it does not create per-pane controller processes.

The **Agents** panel has **Agents / Messages** views across all Herdr workspaces. Selecting a row or clicking a system notification navigates to its workspace, tab and pane after verifying the service identity. Completion read state belongs to Santty; other clients remain independent. System notification preferences in **Settings → Agents** cover Claude, Codex and other Herdr agents. Initial snapshots establish a baseline and do not replay old alerts. Messages are kept in memory (up to 256); Herdr notifications are live broadcasts without replay history or full assistant transcripts. Startup removes only exact hooks previously installed by this app bundle, preserves custom hooks and backs up changed configuration files. Local agents are no longer monitored.

Use **Pane → Herdr Diagnostics...** or **Herdr Diagnostics** in the command palette to inspect versions, connection states, saved bindings and the last error category. **Copy JSON** includes local executable/socket paths and object IDs, but excludes terminal text, pane titles, cwd, command lines and raw errors. Diagnostics also report discovery failures and the configured endpoint.

In a Herdr workspace, closing a pane/tab is a confirmed backend operation that ends its terminals and processes. Closing the window or selecting a local workspace only disconnects the projected Herdr views. **Close Workspace** always asks for confirmation. For a local workspace it closes its tabs and local terminal processes, then selects another local workspace (or creates a fresh Default if it was the last). For a Herdr workspace it ends all backend terminals, returns to the last selected local workspace, and recovers its local browser and notes panes there. **End Persistent Terminal** explicitly ends a backend terminal. Take Control explicitly claims geometry control from another client.

Santty saves all local workspaces and their selected tabs, Herdr workspace bindings and local additions, mixed layouts, names, floating/hidden panes, Browser URLs and Notes references to `~/Library/Application Support/Santty/Workspace/workspace.json`. The v7 format additionally stores floating Herdr runtime and placeholder identities and reads v1–v6 files; older builds refuse to overwrite v7 files. Saves are atomic, with a previous valid backup and one writer per file. Another instance can discover workspaces but cannot activate ClientShell or save changes while the owner is running. Old full-window saves restore local tabs into Default and retain their Herdr additions for explicit selection from the picker. Old mixed layouts retain saved terminal identities as placeholders; reconnect them by selecting the corresponding workspace.

Startup restores local content first, then restores a saved Herdr selection once its source is reachable and its fresh ClientShell presentation is ready. Previous local shells remain placeholders with an explicit Start New Local Terminal button; their commands are never replayed. Selecting a Herdr workspace activates its endpoint connection; local additions are reattached only when the service identity still matches. Take Control is never restored automatically. Notes cancellation or a declined save error keeps the workspace open.

ClientShell image display has been confirmed against a running Herdr service; complete lifecycle acceptance remains pending. **Open Recent History Snapshot** provides a frozen, selectable text view of at most 1000 rows / 256 KiB; older history, inline images and live cross-history selection are unavailable. Its navigation uses Cocoa text motions, with approximate Vim shortcuts. Prompt Editor requires Control and sends one bracketed multiline paste followed by Return.

CLI read/search use the backend recent snapshot and report its source and truncation; line numbers refer to that snapshot. Process information and inherited cwd come from Herdr. Agent status and completion notifications come exclusively from Herdr; local hook installation, the agent event socket and PID liveness monitoring have been removed. Stale CLI socket hints are rediscovered using the backend pane and socket; ambiguous instances require `--socket`. Reinstall the bundled CLI after upgrading. See [the implementation plan](docs/plans/herdr-native-client.md).

**Pane → Reconnect Herdr Window** appears when the selected Herdr window is disconnected. Disconnect and Take Control remain available in the command palette; use Close Pane to end a backend terminal. Herdr connection actions have no default shortcut; assign them in **Settings → Keybindings → Pane**. Herdr workspace attachment remains experimental. Current-machine Debug/Release builds and connection stress have passed, but macOS 14 runtime, Intel runtime and full input-to-pixel performance coverage are still release gates.

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
