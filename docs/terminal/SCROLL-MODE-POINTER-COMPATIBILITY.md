# Scroll Mode: local pointer, wheel and drag autoscroll

> **Current integration:** the shared implementation now lives in `Santty/Sources/Terminal/Native/` and is exercised by the formal `SanttyTerminalTests` suite against the production application module. See the [atomic cutover record](../../docs/plans/terminal-native-cutover.md) for current evidence and open manual gates. Scope/backend statements and counts below retain the original **pre-cutover milestone record**, not current production status.

This extends the isolated [keyboard UI](SCROLL-MODE-UI-COMPATIBILITY.md). The main
application/backend and its production shortcuts/factories are **not switched**.
No user windows, TCC permissions, shared cores or user PTYs are manipulated.

## VT is still the selection authority

The mode reuses the driver's **existing Ghostty VT tracked selection gesture**
engine. It does not introduce a second drag/word/line interpreter, selection text
store, emulator or synthetic program mouse events. The engine decides half-cell
thresholds, direction, wide/combining cells and double/triple-click word/line
selection. Copy uses its actual terminal selection through the same VT formatter
and existing 32 MiB cap; nothing is copied just because a selection changes.

`NativeScrollModePointer` retains an opaque mode-gesture UUID, one window point,
metrics and a fractional wheel bank. Press moves the mode cursor, cancels the old
selection and obtains a new token. VT gesture endpoints are adopted as **fresh VT
tracked refs**, so keyboard continuation and overlay follow that actual selection.
A single click need not select a character; native double/triple clicks can select
without a drag. Release preserves selection and native multi-click history but
ends the drag token. Orphan/repeated/stale drags and releases are refused.

The driver rebases every user hit from the **published viewport's tracked content**
under its VT lock before calling the gesture engine. Neither old absolute rows nor
text searches locate the origin. Unpublished pruning can move retained content;
a discarded origin/selection, reset/screen change, reflow/metrics mismatch, focus
reset or stale token cancels continuation instead of selecting replacement rows.
Coordinates and cell/time conversions are finite/bounded before integer/C casts.
Initial clicks in elastic blank/outside the grid are refused; valid drags clamp
at the actual view/grid edge. Copy/keyboard/wheel handoff cancels a pending drag
without replaying its later release. Pointer/wheel intent clears the old `g` prefix
and copy flash, not another responder or workspace.

Program mouse modes stay untouched, including tracking, alternate-scroll, pixel
and SGR modes. During Scroll Mode, Cmd-click is local selection, not URL opening;
hover, context/extra buttons and program motion reports do not escape the mode.
The existing output ownership token continues to reject program-bound user input.
Automatic replies/credit remain independent. Renderer stays the real responder.

## Wheel navigation

Wheel events are consumed once by the local mode path. They move the cursor through
physical rows and use the existing atomic mode presentation/virtual NSScrollView;
there are no program mouse packets, alternate-screen arrow keys or calls to the
normal program wheel encoder. Existing visual selection can extend with this motion.
Wheel intent cancels a held drag; it never leaves an autoscroll timer behind.

Precise devices accumulate fractional **row** travel; whole rows are committed in
one bounded operation (at most 40 rows/event). This is line-stepped keyboard-mode
navigation, **not a claim of smooth fractional-pixel mode scrolling**. The ordinary
out-of-mode fractional NSScrollView path is unchanged. Nonprecise events retain
the old Scroll Mode's sign/away-from-zero line policy, not the program-wheel rate.
Phased gestures require a fresh began; inherited momentum is dropped. End/cancel,
focus/mode/gesture ownership changes discard the bank; phase-less devices retain
the established limitation that separate gestures cannot be inferred without phases.

Scrollbar-thumb/track direct seek is still pinned to the mode reveal plan, not a
new supported navigator. Horizontal wheel motion has no separate mode navigation.
Remaining host drop/services/zoom/menu and input-source integration are not completed
by this work. Native text/paste/IME endpoints remain gated as before.

## Finite drag autoscroll

Only a held, valid drag outside the vertical clip can schedule a **single weak,
token-checked 50-ms wake**. Each step changes at most 10 rows. It derives the new
edge from the **current VT tracked mode viewport**, then asks the same VT gesture
to extend to that edge; it does not replay a stale UI row or another selection
algorithm. The normal bounded atomic mode presentation paints the result.

No wake is scheduled at rest or at a history boundary. Returning inside, release,
keyboard/wheel handoff, reset/rebind/end, hidden/occluded/detached view, sleep or
stale geometry/token cancels it. An old queued wake cannot affect a new drag. View
and controller release are not retained by the task. At a boundary a later actual
pointer/output event can reconsider intent; there is no idle catch-up/poll loop.

A deterministic finite-step API and injected display fact test the owned offscreen
scheduler. This is **not** actual device or WindowServer visibility acceptance.
The injection cannot bypass the connected presentation/input gates: connected
hidden panes remain blocked. Disconnected fixture input follows the existing
fixture rendering convention even when the test app is hidden; neither path
changes the live output's strict visibility, parsing or ownership policy.

## Independent premises and bad vectors retained

The first tests exposed fixture input being rejected because the test application
was hidden, while existing fixture presentation was intentionally allowed. The
fixture-only branch now follows that same convention. A connected hidden test
explicitly verifies that injecting a timer visibility fact cannot admit gestures.
No user's app visibility, TCC state, window or timeout was changed to make it pass.

The original unpublished-pruning vector also had a false premise. Independent C
against the **original precompiled archive** shows that, after the same 400-row
burst at the test-only 2000-line estimate, oldest content advances **2368→2960**:
`history-2954` is really discarded. The unchanged original vector now locks in
refusal/no replacement selection. A separate positive vector uses the independently
verified surviving `history-3985` ref, rebased to row 1025, and copies exactly that
content after pruning. There is no fake strict line cut or host text lookup. The
production **8 MiB history budget remains unchanged**, never reduced below 6 MB.

```sh
sh Scripts/Terminal/probe-vt-scroll-mode.sh
flowdeck test -s SanttyTerminalLab -d /tmp/santty-security-validation.Dwb7Pg \
  --only SanttyTerminalLabTests/NativeScrollModePointerTests --json
```

## Evidence and scope

**21 new cases** cover forward/reverse drag, click/word/line behavior, Unicode,
elastic/outside/orphan input, Cmd links/program modes, focus/resize/hold/reset,
actual lost and retained pruning refs, finite drag steps/exact copied source lines,
boundaries, scheduler facts/sleep/hide, stale epochs/tokens/invalid inputs, wheel
fractions/inherited momentum/caps, keyboard handoff and weak owner release.
Existing CG and Metal composition tests now additionally drive actual pointer
selection and inspect actual blue selection pixels and exact copied text. The
owned raw PTY consumer also performs real VT selection while receiving its exact
DSR reply and verifies no mode input or exit replay. Those fixtures, protocol bytes
and deadlines are not changed; no precompiled core or SwiftTerm patch is rebuilt.

Latest lab: **404 passed / 0 skipped**. Latest main: **361 passed / 2 existing
system/environment skips** (old Ghostty renderer needs a logged-in display; private
effective-corner-radius getter unavailable). The first main run was **360 passed /
1 failed / 2 skipped** at the already-recorded remote agent rename metadata timeout:
`Remote workspace timed out at renamed remote agent metadata: ["/"]`.
An unchanged targeted diagnostic run and subsequent unchanged full run passed.
No native source is in the main target yet, no wait/metadata expectation was changed,
and the recurring old timing issue is **not claimed fixed**.

This remains isolated lab work, not whole-app migration or manual pointer/device/
IME/AX/screen/sleep/performance/power certification. Next complete the remaining
native host/input-source/drop/menu adapters and production close/save/CLI wiring,
then perform the atomic dependency/backend cutover and independent acceptance.
