# Production native close/save/reply wiring

The main application now uses the same native owner/frontend and transaction
as the lab. Local cleanup is awaited before layout removal; the old surface,
retirement and wake patches were removed with the old backend. No runtime toggle,
dual-core linkage, cached-PID signaling or new CLI grant bypass. See the
[atomic cutover record](../../docs/plans/terminal-native-cutover.md) for current
387 main passes / 1 system skip, 458 lab passes and remaining manual gates.

## Shared finite transaction

`Santty/Sources/Terminal/PaneCloseTransaction.swift` is compiled by both targets.
The native mixed barrier now delegates to it rather than maintaining a parallel
transaction algorithm. Each target retains its concrete owner while cleanup
awaits, with UUID, preflight, admission fence, async finish and exact identity
predicate. The transaction:

1. Refuses precancellation, duplicate UUIDs, stale owner/container membership and
   conflicting intents **before** any admission fence/resource operation.
2. Calls every registered `begin` before the first await, then runs independent
   cleanup tasks and awaits **all**, including when another owner fails.
3. Rechecks cancellation and every owner/container before one synchronous commit;
   no await separates identity validation from layout removal.

Every live native owner uses `awaitedOwner`; Local normalizes to terminate,
external Herdr viewers to detach. Preflight also validates the underlying owner
intent before any target is fenced. An unstarted Local owns no SwiftTerm process,
PTY or IO pipeline. Explicit cleanup suppresses automatic onExit layout removal;
failed cleanup retains owners/layout for explicit same-intent retry. The prior
`legacyLocalRetirement` policy was retired, not relabeled as native cleanup.

`PaneCloseHandle` coalesces one concrete owner's intent and cleanup, not CLI
requests or workspace operations. External viewers normalize to detach.
Conflicting managed intents cannot silently escalate even after completion.
Failures permit an **explicit same-intent cleanup retry**, with a new admission
fence in case a failed backend close recovered its connection. No input is
queued/replayed and completed cleanup is not repeated. Cleanup closures are
explicitly MainActor-bound; no unsafe Sendable isolation workaround.

## Main application routes now connected

- GUI pane close/replacement, tab and workspace close use the shared transaction
  through the existing helper (its private `closeHerdrPanes` name is still legacy).
  It retains/validates **all** affected pane identities, including nonterminals,
  not just the Herdr terminals that need IO. Same-UUID replacement, newly inserted
  siblings/tabs or changed workspace ownership refuse removal instead of dropping
  an unclosed program. Last-tab window confirmation precedes resource cleanup.
- CLI close uses the same barrier and exact container snapshot, then removes the
  target synchronously, saves and returns its existing response. No mutation
  bypasses `CLICommandRouter`: grants, launch-scoped ten-minute retry IDs,
  coalesced journal tasks/results and no valid-ID eviction are unchanged.
- `finishCLIReply` still finalizes only the matching request **after socket write**.
  Window/app preparation refuses while that final reply is pending; sidebar and
  background viewers are prepared only after the reply gate opens.
- NSWindow close and AppDelegate termination now share coalesced
  `prepareForWindowClose`, **even with persistence disabled**. It snapshots all
  workspaces/tabs plus the sidebar, saves before effects, performs final viewer
  detach, and saves again after pending runs have resolved their binding/ambiguity.
  A final scope check precedes completion. Actual destruction, not merely an
  empty main layout, requires this preparation.
- The window busy fence blocks CLI mutation and common new-tab/split/replace /
  workspace/navigation/name/placeholder activation paths. Automatic debounced
  save/sharing does not race the explicit final saves. Atomic/private v10 writer,
  lock, unreadable/unsupported-file refusal and user save-error confirmation
  remain the existing implementation.

This is not rollback of a terminated process. If the post-detach save is cancelled
or fails, retain the layout/owners and report failure; do not silently reconnect,
start a new shell or reinterpret a second close intent. Save-error sheets and
actual application termination still need user-operated acceptance. The existing
save confirmation may be requested at either save phase.

## Herdr policy and recovered-observer regression

Managed explicit pane/tab/workspace close awaits `closeTerminal` before removing
bindings. Window/app close and external viewer close only detach; saved bindings,
permanent core IDs, pending-run state and machine profiles are preserved. No main
application close sends core-daemon stop.

The shared `HerdrTerminalSession.beginViewerClose` synchronously stops new attach /
input and removes only the terminal subscription/channel. The machine observer
must remain until the operation succeeds, because a failed remote close needs to
observe machine recovery and reconnect its **original** binding.

The first refactor removed that observer early. The unchanged real proxy test
reproduced **twice** at its existing reconnect deadline:

```
Remote workspace timed out at reconnect: ["/ (Disconnected)"]
```

It explicitly attempts an offline close before reopening its owned proxy gate.
The fix keeps machine observation across failed termination; final successful
termination/detach still removes it. The same test, unchanged bytes and timeout,
then passed in targeted and complete runs. This is a diagnosed regression, not
an excuse to retry input or restart a shared daemon.

An additional new unit first proved a retry admission bug (`fences=1`, expected
`2`): a backend may reconnect after failed cleanup. Each explicit cleanup retry
now re-arms admission before awaiting, while pending duplicates still share one
operation and completed results do not repeat cleanup.

## Evidence and honest limits

- **21 new main tests:** 11 transaction/handle cases and 10 production-caller
  lifecycle cases. Coverage includes all-begin ordering, all-owner failure wait,
  cancellation boundaries, duplicate/stale/conflicting identity, cleanup retry,
  same-UUID replacement, sibling/tab insertion during await, GUI/CLI paths,
  background workspace + hidden sidebar, coalesced window preparation and reply
  ordering. Synthetic awaited owners test these contracts; they do not certify
  legacy Local process termination or real GUI sheets.
- A new test reads/writes a real private `WorkspaceStore`: the pre-effect file
  contains `before-detach`, an owned cleanup changes it to `after-detach`, and the
  final private atomic document matches the current workspace.
- The existing real private-core main consumer now calls production window-close
  preparation before its existing restore: inactive main and hidden sidebar
  programs stay **live with identical PIDs/bindings**, then restore normally.
- Native full **458 pass / 0 skip** exercises the **same shared transaction** with
  its real owned PTYs/Herdr/private proxy consumers. Main final **383 pass /
  1 existing system-capability skip** (private corner getter), 384 total.
- The first full main run separately hit the **unchanged** raw transport test's
  ten-second output deadline (`Live stream did not finish`, 127,172,434 bytes
  observed of a two-million-row producer). Its unchanged single observation and
  unchanged complete repeat passed. Transport implementation, producer bytes,
  memory assertion and deadline were not modified; cause is **not diagnosed or
  claimed fixed**. This is distinct from the reproduced observer regression.
- A later full run separately failed the unchanged 6000-row Scroll Mode first-row
  copy assertion (`real-row-0001 中文🙂`, before the new window-detach assertions).
  The same single test and same complete suite then passed unchanged. History
  budget, burst, copy assertion and deadlines were not altered. This observation
  also remains **unlocated**, not a claimed scrollback fix or a hidden skip.

Dependency inventory remains 8 production / 7 test files, 16 old imports; its
8 audit tests pass and removal mode still intentionally fails. Saved FlowDeck
**Santty / My Mac / Debug** is unchanged. No user sessions, profiles, shared cores,
GUI automation/TCC settings or unowned pasteboards were operated.

## Still required at cutover

Main terminal/controller/host/settings/foreground/palette/Prompt Editor adapters,
whole-app native source/dependency replacement, removal of legacy Local retirement
policy with the old core, actual Debug/Release resolved-link checks, and manual
GUI/IME/AX/sleep/device/energy acceptance. Current main reads/rendering/input still
use the old backend. These lifecycle changes are not a declaration that 5C or the
migration is complete.
