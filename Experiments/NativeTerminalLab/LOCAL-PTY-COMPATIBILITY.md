# Independent local PTY milestone

## Scope

`NativeLocalPTYLab` connects standalone **SwiftTerm.LocalProcess** to the same
`NativeTerminalOutput → GhosttyVTDriver → SwiftTermFrameSource → NSScrollView`
used by Herdr. It does not instantiate `LocalProcessTerminalView`,
`HeadlessTerminal` or a second emulator. Explicit environment avoids the
runner's Terminal-based default environment helper. The main app still uses
its old backend; this is not a workspace/CLI/Scroll Mode migration.

Pinned reuse: SwiftTerm `28c6d1d95de156a36a2eaa278177ee7f8a15d322`,
`LocalProcess.swift`, `Pty.swift`, `TerminalIOPipeline.swift` and lifecycle test
patterns. License: `Licenses/PTY-Adaptation-NOTICE.txt` / `SwiftTerm.txt`.
The precompiled Ghostty artifact is unchanged; no C core is rebuilt.

## Lifecycle and I/O boundary

- One launch per wrapper: idle → starting → running → closing/exited or failed.
  No reconnect, blind relaunch, old input replay or replacement PID binding.
  Checked launch failures are separate from a child that exits 127 after
  exec/chdir failure. Invalid relative executable/NUL arguments are refused
  before fork. Exit 127 is a convention, not a detailed exec-errno handshake.
- Private serial delegate delivery, **not main and not direct delivery**.
  The callback copies its temporary slice, parses synchronously through VT,
  and returns before the next FIFO event. UI invalidations coalesce separately;
  output, automatic replies and parsing do not wait for drawing or AX. A late
  callback after the wrapper has exited is rejected. Exit waits for the
  runner's existing drain and delegate ordering, not UI publication.
- Input has one checked FIFO: at most **1 MiB including in-flight bytes**, at
  most **1024 queued chunks plus one in-flight block**, one DispatchIO write at
  a time. Oversized/full requests are refused atomically; partial write errors
  are surfaced and never retried. This is a queue-data bound, not a total heap
  guarantee (Data/DispatchIO/kernel copies also exist). A successful send means
  **accepted to this launch's queue**, not child consumption or execution.
- `NativeTerminalOutput.bindChecked` adds queue acceptance without changing
  existing Herdr's Void-writer semantics. User writes require running state;
  only automatic protocol replies remain eligible during graceful close.
  Closing disables new input and drops unsent queued bytes. Already in-flight
  writes cannot be undone. Exit clears the FIFO, invalidates clipboard grants
  and never routes input to another process.
- Cells/pixels enter `winsize` via the delegate before launch and locked
  `updateWindowSize` after resize. VT resize is not repeated when its current
  metrics already match. No `stty` command is injected as a resize workaround.
  PTY pixel sizes saturate to the ABI's UInt16 fields.

## Ownership, shutdown and process metadata

The sixth reproducible patch, `SwiftTerm+LocalPTYHost.patch`, adds:

1. A **proven chdir correction**: upstream ignored `chdir` failure, and the
   independent `/bin/pwd` test exited 0 in its parent's directory. The child
   now `_exit(127)` instead, using only async-signal-safe calls before exec.
   The original invalid-cwd vector/expected status was retained.
2. `terminalInfo()` queries the slave device with Darwin `TIOCPTYGNAME` and
   foreground group with `tcgetpgrp` while the runner's lifecycle lock prevents
   FD closure/reuse. It returns owned strings/IDs, never a raw fd or the name
   of the master mistaken for the slave. A foreground **group is not a PID**.
3. `terminateTerminal(force:)` targets the kernel's current foreground group
   using **TIOCSIG on that locked owned PTY**, plus the existing reuse-protected
   root child reaper. It does not look up/kill a cached group ID or signal PID
   zero. Existing `terminate()` child-only behavior is unchanged. The native
   wrapper serializes launch and stop before using this new close operation.

The wrapper's graceful attempt uses HUP for the PTY foreground and TERM for
its exact root child, then after **0.5 s** uses KILL through those same protected
paths. Stop callers coalesce. After a **5-s cleanup deadline**, failure keeps the
owned directory rather than pretending cleanup succeeded; explicit quit may
be refused. Unexpected owner release retains only its bridge for best-effort
verified close/reap before removing private files off the main thread. No arbitrary process table
is scanned. This is **not a promise to kill escaped/disowned/background daemon
trees** or tasks that no longer belong to this terminal.

Local foreground PID/cwd inspection is best effort: only the kernel-reported
foreground group leader is considered; session, controlling-tty device,
start-time and repeated group checks must match. A missing leader returns no
PID/cwd, not the shell PID as a substitute. These metadata queries are never
used for signals or remote workspaces. Invalid UTF-8 paths are not fabricated.
Physical kernel cwd can be `/private/var/...` while a caller's path is
`/var/...`; the dynamic-cwd test initially compared those aliases incorrectly.
The probe showed actual successful `cd`, no pending write and no write error.
Only the test's file-identity/path comparison was normalized; production path
strings and protocol bytes were not rewritten and no startup delay was added.

## Isolation and known gates

The experimental menu starts **/bin/sh -i** in a unique 0700 HOME/XDG/tmp root.
Only PATH/locale are inherited; credentials, HC routing, local control sockets,
BASH_ENV/ENV/DYLD hooks and user shell startup directories are not inherited.
`TERM=xterm-256color`, truecolor and a distinct terminal-program name are
explicit; official Ghostty terminfo/login-shell parity is not claimed.
Trusted test/host calls can select an executable/args/initial cwd. Runtime
local cwd inheritance is tested, not guessed from stale launch metadata.

The runner's **existing 0.5-s output-drain bound is unchanged**. It can discard
unread tail data if parsing/delivery remains blocked beyond that deadline.
The 6000-row/wide burst and final marker pass, but this is **not certification
of unbounded lossless EOF drain**. No longer wait, parser delay, skipped test
or altered output bytes was introduced to hide that limit. Full descendant
policy, sustained backpressure/drain behavior, login/shell/terminfo variants,
GUI/IME/device/sleep behavior and performance/energy remain acceptance gates.
AX and animation manual acceptance from earlier milestones is still open.

## Evidence / manual entry

`NativeLocalPTYTests` + `NativeLocalPTYSessionTests`: **16 cases** cover the
original invalid cwd failure, environment isolation, actual tty/pid/group/cwd,
exit 7/127, invalid arguments, real resize and raw query reply bytes,
6000-row history/final tail before exit, real foreground sleep/SIGINT,
UTF-8+Enter+raw ETX, single/aggregate input backpressure, cwd inheritance,
same VT PNG/AX boundary, early/coalesced/forced close, child reap and fallback
owner cleanup. Foreground force is proved by an owned file lease releasing
before any rescue token; an owned FIFO permits cleanup on failure without
cached-PID signaling. Expectations observe program state/data, not just writes.

`Tools/probe-local-pty-api.{c,sh}` independently verifies the Darwin ioctl
arguments, slave name, current foreground identity, HUP and KILL using tiny
owned `forkpty` children. It does not link/build a terminal core or access user
terminals.

```sh
sh Experiments/NativeTerminalLab/Tools/probe-local-pty-api.sh
```

Latest experimental FlowDeck: **270 passed / 0 skipped**; main app **362 passed /
1 system-capability skip** (private effective-corner-radius getter unavailable).
Saved My Mac / Santty defaults are unchanged. Tests are not fresh GUI acceptance.

Restart the rebuilt lab, return to fixture mode, and choose application menu
**Start private local PTY**. End it through **End local PTY session**. This mode
and private Herdr are mutually exclusive; fixture injection and Herdr reconnect
are disabled while local is active. Renderer, input, selection, links, reviewed
clipboard, images/animation, native scrolling and AX still use the common
frontend. Quit waits for verified local cleanup. No local PTY has been silently
substituted into the main application.
