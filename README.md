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

## Scroll Mode (Experimental)

Press **Shift-Command-S** to navigate and select within Ghostty's current viewport
and retained scrollback. Ghostty keeps rendering the terminal and selection,
preserving ANSI colors, fonts and grid layout. A transparent overlay adds a
keyboard cursor. Output remains live; entry and exit keep the current viewport.

| Key | Action |
| --- | --- |
| `h/j/k/l` or arrow keys | Move the cursor |
| `0` / `$` | Beginning / end of the displayed line |
| `^` | First nonblank cell of the displayed line |
| `w` / `b` / `e` | Next word start / previous word start / word end (punctuation is separate) |
| `W` / `B` / `E` | Same motions for whitespace-delimited words |
| `Ctrl-U/D` | Move half a page |
| `Ctrl-B/F`, Page Up/Down | Move a page |
| `gg` / `G`, Home/End | Beginning / end of the retained buffer |
| `v` / `V` | Toggle character / whole displayed row selection |
| `y` or Command-C | Copy, preserving mode, selection, cursor and scroll position |
| Escape | Cancel selection, then exit on the next press |
| `q`, `i` or Return | Exit scroll mode |

Mouse selection and scrolling are supported. Switching panes or tabs exits the
mode; an empty selection leaves the clipboard unchanged. Mouse reporting and
click actions are disabled while in this mode so selection cannot send input
to a running TUI or move the shell's input cursor.
Word motions also extend an active selection. They treat displayed row breaks
(including soft wraps) as word boundaries and skip blank rows.

Resizing cancels the selection because text may reflow. This prototype tracks
row indices: if ongoing output evicts old scrollback, its cursor and selection
anchor may drift. Stable anchors require additional support from the core.

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

`list` includes every tab, including inactive tabs, with pane UUIDs, titles,
types, working directories and foreground process-group members. Process
arguments are a snapshot, not shell command history. Browser panes are listed
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
