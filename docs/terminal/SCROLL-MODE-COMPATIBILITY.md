# Keyboard Scroll Mode: isolated VT core ports

> **Current integration:** the shared implementation now lives in `Santty/Sources/Terminal/Native/` and is exercised by the formal `SanttyTerminalTests` suite against the production application module. See the [atomic cutover record](../../docs/plans/terminal-native-cutover.md) for current evidence and open manual gates. Scope/backend statements and counts below retain the original **pre-cutover milestone record**, not current production status.

## Scope: not an activated UI mode

This milestone provides **physical-cell/navigation/selection/presentation ports**.
The subsequent [keyboard UI milestone](SCROLL-MODE-UI-COMPATIBILITY.md) now connects
a lab shortcut, keyboard/IME/paste ownership, mode badge/cursor/copy flash and
offscreen CG/Metal composition. Its follow-up [pointer milestone](SCROLL-MODE-POINTER-COMPATIBILITY.md) now
implements local VT gestures, row-wheel navigation and bounded drag autoscroll. The main app still uses its old
`TerminalScrollModeView`; neither backend nor its old synthetic-mouse bridge is
switched. Core-port tests alone are not full UI/manual acceptance.

`NativeScrollNavigation` reuses Santty's existing physical-grid movement policy,
with the original independent punctuation/whitespace/buffer-boundary vectors.
It is not a SwiftTerm emulator, AX model or CLI text navigator.

## VT owns cells and persistent identity

`GhosttyVTScrollMode` belongs to one driver and is accessed/disposed under that
driver's lock. It retains only three **VT tracked references**: cursor, selection
anchor and proposed viewport top. No borrowed GridRef survives a transaction.
Numeric row/column values in a returned state are observations, not identities
that a future host may replay after parsing/pruning/reflow.

- Cell reads use fresh VT grid refs, packed width flags and VT grapheme scalars.
  Wide heads/tails, combining sequences and wrap spacers are not remeasured in
  Swift. Negative/out-of-grid coordinates return nil; a cell over **4096 scalars**
  is refused. No text history, row store or persistent classification cache is made.
- Kitty virtual placeholder cells are identified using VT's row flag plus its
  placeholder codepoint. Their navigation text is empty and explicitly flagged;
  genuine literal Unicode is not blanket-filtered. There is no image resolver.
- A movement has at most **16 Ki unique classification cells / 128 KiB of copied
  classification text**. Endpoint/geometry validation adds constant cell reads.
  Exceeding the budget throws `readBudget` without committing a partial motion;
  it is not treated as a word boundary or a successful shortened search. These
  are content bounds, not total RSS/latency promises.
- Persistent content follows VT through append/pruning/reflow. A discarded cursor
  falls to column zero of the oldest remaining row and cancels selection, never
  reuses its old numeric row/column. A lost anchor cancels selection. Geometry
  changes preserve a valid cursor reference but cancel selection, matching the
  existing independent resize-selection policy.
- Host reset/RIS and **observed active-screen changes** end the mode. The frozen
  ABI has no screen-transition callback: a primary→alternate→primary roundtrip
  inside one `vt_write` cannot be inferred by another parser. Independent C shows
  the original primary reference stays valid while core selection disappears.
  In that case the valid primary cursor survives, but selection is cancelled;
  it is never resurrected or retargeted to alternate content. This is not a
  promise to detect every transient screen transition.

## Navigation, selection and copy

Left/right/up/down, physical line start/end, top/bottom, half/page movements,
first nonblank and small/big word motions are supported. Physical rows separate
word scans with whitespace **including soft wraps**, just like the existing main
policy. A cursor does not stop on a wide tail; horizontal travel skips it and
vertical/line-end/word destinations normalize to the VT-owned head column.
Default legacy/2027 grapheme layout remains the core's decision.

Visual character selection includes both endpoints. Linewise selection expands
to the first/last columns of the selected **physical** rows. Fresh endpoint refs
form a real `GhosttySelection`, installed directly through the selection API:
**no synthetic mouse press/drag/release or protocol-mode changes** are used.
The existing VT formatter still owns selected-text output (`unwrap=true`,
`trim=true`, existing **32 MiB copy cap**), including logical soft-wrap joining.
The host does not format Unicode, trim lines or keep another selection store.

Core-cleared selection is not reconstructed behind the user's back. An explicit
external pointer selection/select-all ends this mode's ownership; clear cancels
its selection. Mode copy cannot accidentally return the later pointer owner's
selection. The copy port returns text, not a pasteboard side effect.

Synchronized-output hold suspends navigation/selection/presentation/copy ports;
end is always allowed. Standalone raw cell reads remain read-only **parsed current
content**, not a promise of published visual text. They do not release a hold.
Read/navigation never sends terminal input, focus, clipboard operations, protocol
replies, scroll_viewport calls, animation ticks or UI invalidations.

## Explicit atomic presentation

`scrollModePresentation(...)` is the **explicit** presentation operation, distinct
from navigation/read. It resolves current refs and captures the bounded viewport
under one lock, then updates the existing reading anchor/publication. The future
UI must use this transaction, not a stale numeric reveal plan after an await.
Fractional AppKit bounds remain in its returned `NativeTerminalPresentation`;
that actual viewport, not integer navigation rows, drives overlay geometry.
Animation advances once here only when requested, through the existing VT path;
hold returns no new presentation. No second scheduler/player is introduced.

The future host still must coordinate this path with its ordinary presentation
path, hide the normal caret where appropriate, and intercept keyboard/mouse/
IME/paste/menu/drop before program input. A core-port caller is **not** a
production terminal-input authorization grant or a complete input ownership gate.

## Independent evidence

```sh
sh Scripts/Terminal/probe-vt-scroll-mode.sh
flowdeck test -s SanttyTerminalLab -d /tmp/santty-security-validation.Dwb7Pg \
  --only SanttyTerminalLabTests/NativeScrollModeTests --json
```

The C program compiles only a tiny owned client of the **original precompiled**
archive. It fixes wide head/tail and combining-scalar values, `H` following width
10→5 from (7,0) to (2,1), inclusive physical selection/logical unwrap copy and the
same-write screen roundtrip limitation. No C core or SwiftTerm patch is changed.

**18 new cases:** 17 core-port tests plus an actual owned hidden Herdr stream
consumer. They cover pinned word vectors, boundaries/pages, Unicode widths,
6000-row history selection, real render-frame selection, resize/reflow, pruning,
reset/screens/roundtrip, hold, classification refusal, external selection transfer,
parallel parsing and atomic bounded presentation. The Herdr test keeps the seed
selection while >initial-credit output drains without a renderer or binding
change. The existing real Local PTY 6000-row test now also copies its first/final
rows through these ports. No new GUI/TCC automation is used.

Latest full lab: **360 passed / 0 skipped**; main: **362 passed / 1 system skip**.
The first full lab run was **359 passed / 1 failed**: existing
`testMouseClickAndWheelReachPrivateCleanNeovim` timed out at
`private clean nvim ready`. Three unchanged targeted diagnostic runs and a
subsequent unchanged full run passed. No deadline, startup bytes or fixture was
changed; its cause was not reproduced/identified and is **not claimed fixed**.

## Next gate

The lab keyboard owner/controller, overlay/copy feedback, initial input isolation,
actual offscreen pixels and raw PTY consumer are now covered by
[SCROLL-MODE-UI-COMPATIBILITY.md](SCROLL-MODE-UI-COMPATIBILITY.md). Next add local
the remaining host/input-source/menu/drop ports after the now-implemented
[mode pointer/wheel milestone](SCROLL-MODE-POINTER-COMPATIBILITY.md). Preserve the shared published-page AX boundary and full-history CLI
contract; neither becomes this physical-grid navigator. Whole-app factories,
responder/input-source routing and atomic dependency cutover remain separate.
Manual/device/sleep/performance/energy certification is still open.
