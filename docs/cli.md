# Santty CLI

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

`list` includes every workspace and tab, including inactive workspaces/tabs and the
sidebar. Each tab includes `workspaceID`, `workspaceName` and `region` (`main` or
`sidebar`; sidebar workspace fields are absent). Hidden sidebar panes remain
discoverable. `isSelected` identifies the current main tab; each pane's `isFocused`
is its owning tab's remembered focus, not proof that it is visible or first responder.
Entries include pane UUIDs, names, titles,
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
enabling read access lets other processes running as that user read pane contents.
Pane control and terminal input require separate, default-off permissions below.

The CLI is built as `SanttyCLI` and embedded at `Santty.app/Contents/Helpers/santty`.
It is signed with the app's build identity and updates with the app, including
Sparkle updates. Reinstall the link after moving the app. Installation preserves
unrelated files and symlinks already named `~/.local/bin/santty`.


## Pane control

Restart Santty after updating. In **Settings → General → Command Line**, enable
**Allow CLI to Manage Panes and Layout** for lifecycle/layout/focus commands and/or
**Allow CLI to Send Terminal Input** for input. They are independent permissions;
installing the CLI or previously enabling read access does not grant either one.
Disabling read access stops the socket and disables all CLI access. These grants
apply to other local processes running as your user, including access to remote
terminals: terminal input can execute arbitrary commands.

```sh
santty capabilities --json
santty list --json
santty pane new --workspace <workspace-id> --type terminal
santty pane split <pane-id> --direction right --type terminal
santty pane rename <pane-id> "API"
santty pane focus <pane-id>
santty pane focus <pane-id> --activate
santty pane move <pane-id> --direction left
santty pane resize <pane-id> --direction right --amount 40
santty pane equalize <pane-id>
santty pane close <pane-id> --force
```

- Commands target full UUIDs, never names or whichever pane happens to be focused.
  `new` creates a new tab's first pane in the specified workspace; `split` creates
  a sibling. Types are `terminal` (default), `browser`, `agents`, `workspaces`.
  Terminal backends and remote identities follow the owning workspace, not the
  selected workspace; sidebar terminals always use the local Herdr core.
- Creation returns `status: "created"`, `paneID`, `tabID`, and `workspaceID`
  (absent for sidebar panes). It records a layout, not a promise that the shell
  is ready. Panes in inactive tabs/workspaces start when presented. Use `--focus`
  on creation if immediate presentation/startup is needed, then wait for readiness.
- Creation, rename, move, resize and equalize do not select another pane, tab or
  workspace, change first responder, or bring the app forward. `focus` deliberately
  selects the owning workspace/tab and reveals a hidden sidebar or detached pane.
  Only `focus --activate` brings Santty to the foreground.
- Rename accepts an empty string to clear the custom name. Names are single-line,
  at most 1024 UTF-8 bytes, trimmed, and independent of dynamic terminal titles.
- Split directions are physical left/right/up/down. Move swaps with a directional
  neighbor in the same tab. Resize **expands** the target toward that side by
  AppKit points (default 40), taking space from its adjacent sibling and clamping
  at the sibling's minimum size. No available neighbor/space is `layout_boundary`.
  Equalize affects the target's entire tab.
- Layout changes require tiled panes without floating/detached overlays or folded
  layouts. Unsupported combinations return `unsupported_layout` without changing
  the layout; restore it first. Focus, rename and close can address detached panes.
- Closing a live terminal requires `--force`; otherwise `confirmation_required`
  is returned, without a dialog. Local sessions end; Herdr sessions are killed
  before saved bindings/layout are removed. External viewer-only panes only detach
  and never kill their shared terminal. Herdr failures retain the pane and binding.
  Closing the last pane removes its tab/workspace; closing the final main pane
  closes the window after replying (remaining sidebar Herdr viewers detach).
  Closing a focused pane necessarily transfers focus; closing another pane does
  not select an unrelated pane.

## Terminal input

```sh
santty pane send-text <pane-id> --text "printf 'hello'"
santty pane send-key <pane-id> Enter
printf '%s' 'some text' | santty pane send-text <pane-id> --stdin
santty pane send-key <pane-id> Ctrl+C
santty pane send-key <pane-id> Shift+Tab
```

Text is UTF-8, nonempty, NUL-free, at most 64 KiB. `--text` and `--stdin` are
mutually exclusive. It uses Ghostty's paste path, honors bracketed paste, does
not append Enter, and does not touch the clipboard or focus. **Embedded newlines
can still execute commands in programs without bracketed-paste protection.**
There is no shell inference, shell quoting, command execution API or exit-status
tracking. You are interacting with the current program, which may not be a shell.

Keys use Ghostty's key encoder (including the terminal's current keyboard mode),
not pasted control characters or system keyboard simulation. Supported names:
`Enter`, `Tab`, `Escape`, `Backspace`, `Delete`, `Home`, `End`, `PageUp`, `PageDown`,
`Left`, `Right`, `Up`, `Down`, and `Ctrl+A` through `Ctrl+Z`. Optional `Ctrl` and
`Shift` modifiers are accepted; names are case-insensitive. Command chords,
arbitrary Ghostty binding actions and unrestricted key sequences are not exposed.

Only live, ready terminal surfaces accept input. Offline, exited, unstarted,
Scroll Mode and IME-composing terminals return `input_unavailable`. Input is not
queued for reconnect. Herdr bytes are bound to the stream at callback time and
never replayed onto a replacement stream. `status: "accepted"` means handed to
the terminal input path, **not** remote delivery, command completion or success.
Inspect output to establish what actually happened.

## Results, retries and compatibility

All commands accept `--json` and `--socket PATH`. Errors exit 1. JSON errors include
`error`, `errorCode` and, when available, `requestID`. Common codes include
`permission_denied`, `pane_not_found`, `workspace_not_found`, `input_unavailable`,
`unsupported_layout`, `confirmation_required`, `busy` and `persistence_failed`.
A persistence failure after closing explicitly says the pane was already closed;
it is not an invitation to repeat a destructive operation.

Pane mutations return an opaque `requestID`. To recover a result after a connection
failure, repeat the **same command/options** using `--request-id TOKEN`. Requests
with the same token share the pending operation or cached result, including input;
changing the operation yields `request_conflict`. Tokens expire after ten minutes
and belong to one app launch. Expired or previous-launch tokens are rejected,
not treated as fresh operations. The bounded journal rejects excess operations
with `busy`; it does not evict valid IDs and risk duplicate execution.

The CLI never automatically resends mutations. On a transport timeout (30 seconds
for a mutation), `result_unknown` means the operation may still be running or
complete. The error includes its retry token. Inspect state or recover using that
same token; **never blindly retry with a fresh ID**, including after restarting
Santty. An expired token cannot establish whether the original operation happened.

The wire protocol stays at version 2 with additive fields and a `capabilities`
command. Old `list/read/search` clients remain usable; new mutation clients probe
capabilities first and refuse old servers instead of silently losing options.

See [Agent Skill](agent-skill.md) to teach an agent how to use the CLI.
