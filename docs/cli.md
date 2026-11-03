# Read Pane Logs from an Agent

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



See [Agent Skill](agent-skill.md) to teach an agent how to use the CLI.
