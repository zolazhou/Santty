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
- **Direct serial parse-worker delivery**, never main or a sync hop to the
  lifecycle queue. The callback copies its temporary slice and parses through
  VT before releasing its bounded ring slot. This replaces the first milestone's
  queued delivery so a blocked parser cannot also block the process monitor.
  A separate private lifecycle queue publishes termination only after natural
  drain completes. UI invalidations coalesce separately; output, automatic
  replies and parsing never wait for drawing or AX. A late callback after the
  wrapper has exited is rejected. No borrowed bytes outlive their callback.
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

### Natural-exit finite output fence

The seventh patch, `SwiftTerm+PTYOutputDrain.patch`, adds opt-in
`completeAvailableOutputOnExit`, enabled by this wrapper. Legacy clients still
use the unchanged **0.5-s** cutoff. The original reproducer held the first
parser callback past that cutoff after output capture: only **6 / 16,409 bytes**
survived. Increasing a deadline would not fix that ownership bug.

On natural root exit the gather worker takes **one finite readable-byte fence**
at its next checkpoint: ring slots, any in-progress batch, plus the kernel bytes
visible then. It captures that count once, reads no more than that remaining
budget, then delivers all captured batches before termination. No FPS loop,
wall-clock parser cutoff, EOF wait for descendants, unbounded extra history,
or new output allocation queue is added. The original four × 65,536-byte ring
is unchanged. Descendant output racing before the fence is indistinguishable
from root output; later writes are deliberately outside it. This is not an
indefinite descendant-output subscription.

**Darwin ABI difference:** PTY master `FIONREAD` reports slave input, not master
output. Independent C observed `FIONREAD=0`, `TIOCOUTQ=10`, actual read=10.
Character/PTY descriptors therefore use `TIOCOUTQ`; the owned pipe component
control uses `FIONREAD`. Function-like `_IOR` macros are not Swift-importable,
so explicit request values are checked with SDK C `_Static_assert`s. Both the
original bad boundary (3,073 / 4,097 bytes) and its unchanged correct expectation
are retained in the regression. Kernel queries run outside the ring condition;
this is macOS validation, not a Linux/device guarantee.

Explicit terminal close retains discarding semantics. If the root is already
reaped, `terminateTerminal` can cancel the drain **without joining the caller**,
signaling zero, or using an obsolete PID. Guarded mode now also keeps the
callback-ownership barrier after force/termination, not the legacy 0.5-s parser
cutoff. An executing callback still owns its slot and must return before
termination; the native **5-s** cleanup deadline reports failure/keeps private
files rather than pretending a stuck callback has stopped.
`outputDrainComplete` is nil before drain and false for cutoff/cancellation or
an observed fence failure; true means **the captured boundary**, not all bytes
ever written by a program. Unexpected natural failure becomes `outputIncomplete`
in the native wrapper, not a normal successful exit. Deliberate close may discard
output; cleanup deadlines do not pretend a blocked parser has completed.

### Guarded launch and slave lifetime (eighth patch)

The original tiny C child writes ten literal bytes and immediately exits; reading
an unretained `forkpty` only after reap yields **0 / 10 bytes** on this Darwin.
The seventh parser fence alone could not recover bytes already lost in the kernel.
The eighth patch, `SwiftTerm+PTYLaunchCapture.patch`, prevents that lifetime gap
for the native wrapper's existing `completeAvailableOutputOnExit` opt-in:

1. Before fork, construct a private CLOEXEC launch pipe, with FDs moved above
   0/1/2 so `login_tty` cannot overwrite it. Its writer has **fd-local
   F_SETNOSIGPIPE**, never a process-wide SIGPIPE disposition change.
2. The child uses only async-signal-safe calls after fork: restore signals/mask,
   wait for exactly one permission byte, close the gate, chdir, execve; gate EOF
   aborts with 127. The parent opens an **O_NOCTTY / CLOEXEC / nonblocking slave
   keeper** before granting exec. User code cannot outrun that ownership setup.
3. Publish the input channel, bounded reader pipeline and exit monitor before
   permission. Missing input channel / preparation failure / cancellation never
   grants exec. Reader startup EOF also refuses permission. A missing process
   source falls back to the existing dedicated child waiter.
4. Keep the slave until captured output/callbacks finish; close it on the reaper,
   not a view/main release cascade. Deinit discards guarded I/O and closes the
   master write duplicate without waiting for a child blocked on unread output.
   Gate/keeper resources transfer once, and failure paths abort/reap the exact
   child using the existing reuse-safe reaper.

This is **lifetime/backpressure**, not a new timer, sleep, altered program,
protocol ACK or another emulator. Two gate FDs are transient; one extra slave FD
is retained per live guarded launch. The decision is snapshotted per launch;
changing the preference cannot downgrade an active guard. The public legacy
`PseudoTerminalHelpers.fork` signature and default unguarded clients are unchanged.
No new backend switch is exposed in Santty.

The actual LocalProcess regression stalls the parent **1.2 s before reader
startup**: unchanged `/usr/bin/printf FINAL-TAIL` went from 0 bytes to exactly 10.
A second owned helper test first confirms the program has written the ten bytes,
then deliberately withholds capture 1.2 s and still reads all 10. Independent C
retains the **original losing unretained vector** as `RAW CONTROL` and a guarded
case with the **same literal bytes**, delayed reader and exact 10-byte assertion;
it does not silently swap a DSR-gated program for the bad vector. The earlier
main-blocked DSR consumer remains a separate protocol test, and a new native VT
consumer repeatedly runs plain printf with **no program acknowledgement**.

This does not recover a program's deliberate tcflush, promise bytes after a
chosen descendant fence/explicit discard, certify other kernels, or prove all
shell/daemon/device behavior. The raw unretained control can still lose output;
only the guarded path is claimed fixed by these cases.

Full descendant policy, sustained backpressure, login/shell/terminfo variants,
GUI/IME/device/sleep behavior and performance/energy remain acceptance gates.
AX and animation manual acceptance from earlier milestones is still open.

## Evidence / manual entry

`NativeLocalPTYTests` + `NativeLocalPTYSessionTests` originally added **16 cases** covering the
original invalid cwd failure, environment isolation, actual tty/pid/group/cwd,
exit 7/127, invalid arguments, real resize and raw query reply bytes,
6000-row history/final tail before exit, real foreground sleep/SIGINT,
UTF-8+Enter+raw ETX, single/aggregate input backpressure, cwd inheritance,
same VT PNG/AX boundary, early/coalesced/forced close, child reap and fallback
owner cleanup. Foreground force is proved by an owned file lease releasing
before any rescue token; an owned FIFO permits cleanup on failure without
cached-PID signaling. Expectations observe program state/data, not just writes.

The added main-actor-blocked native consumer plus **7 drain tests** bring the
local suite initially to **24 cases**: unchanged captured-tail bytes after a held parser,
explicit nonjoining cancel / incomplete status, the legacy cutoff as an
observation rather than a fix, queued compatibility, an owned slave-holding
descendant that cannot postpone termination to EOF, a continuously writing
owned pipe (actual pipeline, not a fake resolver), and the Darwin master
output-vs-input queue regression. The descendant's file lease is released with
an owned FIFO, never a cached-PID kill. A proposed post-root continuous PTY writer
was found to exit on Darwin write EIO; that premise is not presented as proof of
a live producer. The separate live-pipe control actually remains writing until
the fence closes its reader. Legacy callback completion is explicitly joined in
the test before checking its bytes; legacy termination can overtake that callback.

The next **9 launch tests** plus the plain native printf consumer bring the
local suite to **34 cases**. They include 24 direct/queued rapid unacknowledged
children inside one stress case, actual pre-reader and post-write stalls,
checked channel refusal without execution, cancellation before permission,
CLOEXEC gate/keeper flags, gate-EOF 127, dead-child EPIPE with fd-local SIGPIPE
protection, force-close callback lifetime and immutable active launch policy.
The forced-close test originally reproduced termination overtaking its held
callback; the guard now waits for ownership release even after a forced close,
while the caller itself remains nonjoining.

`Tools/probe-local-pty-api.{c,sh}` independently verifies the Darwin ioctl
arguments/ABI, readable output counts, unretained/guarded short-child controls, slave
name, current foreground identity, HUP and KILL using tiny
owned `forkpty` children. It does not link/build a terminal core or access user
terminals.

```sh
sh Experiments/NativeTerminalLab/Tools/probe-local-pty-api.sh
```

Latest experimental FlowDeck: **288 passed / 0 skipped**; main app **361 passed /
2 environment/system-capability skips** (Ghostty's renderer requires a logged-in
graphical display; private effective-corner-radius getter unavailable).
Saved My Mac / Santty defaults are unchanged. Tests are not fresh GUI acceptance.

Restart the rebuilt lab, return to fixture mode, and choose application menu
**Start private local PTY**. End it through **End local PTY session**. This mode
and private Herdr are mutually exclusive; fixture injection and Herdr reconnect
are disabled while local is active. Renderer, input, selection, links, reviewed
clipboard, images/animation, native scrolling and AX still use the common
frontend. Quit waits for verified local cleanup. No local PTY has been silently
substituted into the main application.
