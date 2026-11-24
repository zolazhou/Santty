# Production pane session / frontend ownership adapters

These adapters now live in `Santty/Sources/Terminal/Native/` and are compiled by
production; the formal `SanttyTerminalTests` suite imports that application module. Main factories/controllers, settings,
foreground/input-source ports, CLI reads/input and Local/Herdr close/save routes
use them. No second emulator, registry, runtime toggle, old-input replay or core
rebuild. See the [cutover evidence and remaining manual gates](../../docs/plans/terminal-native-cutover.md).
The sections below retain the original adapter contracts and milestone evidence.

## One owner, one checked frontend

`NativeTerminalPaneSession` owns a permanent pane UUID, concrete VT driver,
output and one existing backend owner:

- **Local:** an immutable `NativeLocalPTYLaunch` plus `NativeLocalPTYSession`.
  Construction does not fork. Start is once-only; invalid initial geometry
  does not consume the launch, but an attempted exec cannot silently relaunch.
  Real account/environment policy remains in the prior production launch builder;
  this adapter neither creates nor removes HOME, cwd or user directories.
- **Herdr:** the existing `HerdrTerminalSession`, explicit client, binding, remote
  profile, run-pending/viewer role and display facts. The factory installs the
  exact endpoint and checked synchronous `writeInput` before restoration. A
  required `beforeRun` callback supplies the caller's persistence barrier; the
  adapter does not replace the workspace writer or pretend a no-op is a save.
  Viewer-without-binding fails before connecting. A remote factory never exports
  the local control socket; the real two-private-core proxy consumer checks it.

The owner does not fork the Herdr state machine, own a core daemon or set up a
machine profile. Retry is only for its Herdr connection; Local never reconnects.
Callbacks use a weak owner relay. Parsing/replies/credit stay on the existing
transport boundary, independent of UI publication and metadata delivery.

`NativeTerminalFrontend` binds one exact view/driver/output and an opaque token,
with a caller-provided **controller and session identity** predicate. It owns
viewport/focus/automatic-reply/settings callback slots for that binding; callers
must not replace those slots or the backend's delegate closures behind it.
Another driver or a second live frontend is refused. Stale detach cannot clear
a replacement output. Deinit unbinds only its own view; it never joins/stops a
process or kills/detaches a Herdr program. The final Local owner's existing
nonjoining cleanup remains a safety net, not permission to remove layout.

Transient NSView removal, hiding or switching workspaces does **not** call
`surfaceDetached`: endpoint readiness is established once, so hidden output and
credit continue draining. State/metadata refreshes reflect actual key-window /
responder focus, never call `makeFirstResponder`. Only explicit user host actions
may focus a renderer. On registry replacement the caller must detach the old
frontend; the predicate is not a second registry or an observer of every edit.

Typed settings/zoom baseline ports are supplied, not preference-notification or
Settings UI wiring. Prompt Editor, input-source foreground/palette providers and
host decorations still need main-controller integration.

## Metadata and reads

- VT title/raw OSC pwd stay owned bounded metadata. Herdr's nonempty record title
  takes precedence over VT display text; neither title is a binding identifier.
- Directory inheritance is typed: `.local(path)` versus `.herdr(path, remote:)`.
  Local uses the validated owned PTY cwd, falling back to its explicit launch
  directory. Herdr uses its record/foreground/requested directory and profile,
  never local PID/filesystem inspection or raw OSC URI interpretation. The raw
  URI remains available separately, not a new local-path authority or a promise
  of complete OSC7 policy compatibility.
- `read` uses the private pane-bound background read service and checks the
  caller's exact owner **before and after await, including failure paths**.
  Same UUID alone does not authorize returning another controller's snapshot.
  No retarget, retry, focus, clipboard, tick or mutation route is added.
- A closed process can retain readable final VT history while its layout remains
  registered (e.g. cancelled/failed multi-owner removal). Existing 32 MiB capture,
  256 KiB CLI response and **8 MiB history** budgets remain unchanged.

## Close intent and mixed-owner barrier

`NativeTerminalCloseBarrier` accepts a finite snapshot, not a registry. It
rejects precancellation, duplicate UUIDs, stale identities and conflicting
intents before starting cleanup. All admissions close before the first await;
independent tasks await **every** owner even when one fails. Only after success,
cancellation and exact identity rechecks does its synchronous removal callback
run, with no intervening await. Same-UUID replacements are untouched.

| Intent / role | Backend operation |
| --- | --- |
| Local, either intent | existing coalesced PTY stop/drain/reap |
| managed Herdr, explicit pane/tab/workspace close | `closeTerminal`, then permit binding/layout removal |
| managed Herdr, window/app close | final viewer detach only; retain saved binding |
| external viewer, either intent | detach only; never kill the shared program |

Close intent is sealed/coalesced per owner (Local intents normalize to stop;
external-viewer intents normalize to detach). A concurrent/later conflicting
Herdr intent is refused, not silently escalated. Failure retains the owner,
layout and closed input admission, with an explicit same-intent cleanup retry;
no data is queued for recovery. Local 0.5 s escalation / 5 s cleanup bounds and
finite output-capture policy are unchanged.

The backend-independent shared `HerdrTerminalSession.detachViewer()` marks the
viewer stopped, removes only its subscriptions/channel and awaits an in-flight
run/save before reporting final disconnected/finished state. This preserves a
new binding or ambiguity for the caller's final save; it never sends terminal
kill/core-stop, changes a machine profile or reconnects this viewer. A detach
racing a pre-send save prevents the unsent creation, without inventing a run.

**Not wired yet:** actual pane/tab/workspace/sidebar/window/app callers; atomic
save ordering, retaining Herdr bindings on window detach, and replying to a CLI
close before closing the final main window. The barrier's callback is not a
substitute for that work. Existing router grants, retry IDs, persistence v10 and
post-await controller identity remain mandatory at cutover.

## Initial hidden geometry regression

The first fixture diagnostic falsely assumed `/usr/bin/stty` existed and that
reset must preserve an initially published empty page. Its captured output was
`/bin/sh: /usr/bin/stty: No such file or directory`; reset clearing that empty
page is intentional. The independent executable lookup established `/bin/stty`.
Those false premises are retained, not treated as a renderer/transport fix.

A separate correctly executable, headless-before-window control then reproduced
the real defect: driver **40×4**, real clip **80×15**, and the child's first
`stty size` returned **`4 40`**. Connecting the output before first layout made
the painting visibility gate skip geometry too.

`NativeTerminalScrollView.synchronizeViewport()` now reuses the same geometry
calculation as visible refresh, but performs no frame capture, AX publication,
animation tick, focus or painting. The frontend calls it **before** exec/attach;
the child now reports **`15 80`** while the hidden page remains unpublished and
another owned responder retains focus. Existing gesture cancellation / automatic
size replies still follow their own current-channel policy. No guessed rows,
startup sleep, injected post-launch `stty`, visibility bypass or longer timeout.

Two expanded fixtures also initially assumed the private lab's asynchronous
`start()` already meant `.live`; they now establish that precondition before
using an unrelated live terminal as a negative-control peer. This is not a
production connection delay or a changed close deadline.

The extra remote socket check initially escaped shell quotes into literal quote
characters, falsely reporting PRESENT for an absent variable. The independent
`Tools/probe-adapter-shell-policy.py` retains the original false result and
properly quoted absent/present controls. The real remote PTY now verifies ABSENT;
all previous mouse/reconnect/identity/no-replay bytes and deadlines are retained.

## Evidence / remaining gates

- **20 new tests:** 16 Local/frontend/read/mixed-barrier cases and 4 private Herdr
  lifecycle/metadata/credit/persistence-gate cases. They cover deinit unbinding,
  exact-driver refusal, once-only exec, no autofocus, stale reads/replacements,
  coalesced close state, mixed success/failure, both cancellation boundaries,
  viewer/window detach, restoration and pre-send save/close races.
- The original real two-owned-core remote consumer now uses the new factories,
  retaining its literal PTY mouse, reconnect/PID/identity/no-replay checks, and
  extends socket-exclusion, typed remote directory and viewer detach coverage.
- Full native **458 pass / 0 skip**. Main **362 pass / 1 existing system-capability
  skip** (private corner getter). Its unchanged old Metal snapshot test could run
  in this session's display environment; no skip or assertion was removed.
- Dependency inventory / 8 audit tests / documentation links checked. Saved
  FlowDeck **Santty / My Mac / Debug** unchanged. Old dependency-removal gate is
  still intentionally failing until the atomic cutover.

The subsequent staged production close/save/reply callers now use the same
shared transaction; see [CLOSE-COMPATIBILITY.md](CLOSE-COMPATIBILITY.md). Main Local
still has explicit legacy retirement, not the native stop/drain guarantee. The
counts above describe this session-adapter milestone.

No GUI automation, user-window activation, TCC changes, shared cores, user
profiles or production PTYs were used. Actual multi-pane/IME/TIS/VoiceOver,
WindowServer, shell/terminfo, sleep/cross-screen/device/energy acceptance and
Debug/Release resolved-link removal certification remain open.
