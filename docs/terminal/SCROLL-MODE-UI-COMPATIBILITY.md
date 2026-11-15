# Scroll Mode: lab keyboard ownership and AppKit overlay

> **Current integration:** the shared implementation now lives in `Santty/Sources/Terminal/Native/` and is exercised by the formal `SanttyTerminalTests` suite against the production application module. See the [atomic cutover record](../../docs/plans/terminal-native-cutover.md) for current evidence and open manual gates. Scope/backend statements and counts below retain the original **pre-cutover milestone record**, not current production status.

This extends [the VT core ports](SCROLL-MODE-COMPATIBILITY.md) in the isolated lab.
**The main application/backend/factories and production shortcuts are unchanged.**
It is a keyboard-first UI milestone, not complete pointer/Scroll Mode/AX/device
acceptance. No GUI automation, TCC prompt, user terminal or shared core is used.

## User-operated lab entry and bindings

After rebuilding/restarting the lab, use its app menu **Enter Scroll Mode** or
**Cmd-Shift-S**. The shortcut/menu may focus the lab renderer as an explicit user
action; metadata/output refreshes never choose a responder. It works in the
fixture without a PTY writer, as well as with an owned session.

The renderer remains first responder. The decoration view is not an input
surface: hitTest returns nil, it refuses first responder and is not an AX element.
A steady yellow hollow cursor and SCROLL / SELECT / SELECT LINE badge sit above
both CG and Metal content. VT width flags give wide glyphs a two-cell outline.
The program caret is hidden through external-frame presentation, **not** a fake
program focus loss or cursor protocol command. Exit restores the program caret.

Bindings reuse Santty's existing mapping:

- h/j/k/l and arrows; 0 / ^ / $; w/b/e and Shift-W/B/E.
- gg / Home for top; Shift-G / End for bottom.
- Ctrl-U/D half pages; Ctrl-B/F and PageUp/PageDown whole pages.
- v / Shift-V toggle character/physical-line selection; Escape first cancels a
  selection, then exits. q / i / Enter exit; their bytes are not typed afterward.
- y or plain Cmd-C copies the actual VT selection and flashes its cursor for
  **300 ms**. No selection change automatically writes the clipboard. Empty or
  over-limit copy leaves it alone. Modified Cmd-C chords are not silently plain
  Cmd-C. App-global menu shortcuts such as Cmd-Q remain available.
- Cmd-V / Cmd-A are consumed in this keyboard-only mode; they do not paste or
  transfer selection to a different owner.

The `g` prefix has the existing policy (not a new timeout). Focus/input resets
clear the prefix, preedit, press/release bookkeeping and finite copy flash.
They do not automatically leave reading mode or move another responder. Copy
flash completion is weak and token-checked so a cancelled old wake cannot clear
a newer flash.

## Input ownership and cleanup

`NativeTerminalOutput` now has **owner-scoped suppression tokens**, separate from
its enabled state and from CLI authorization. A controller releases only its own
token. This cannot enable an offline/closed output or override another suppressor.
All committed text, paste, key, mouse and program-wheel sends are refused before
encoding/queueing while suppressed. There is no deferred queue or replay on exit.
Automatic protocol replies still use their existing always-draining writer;
**real** host focus changes keep their existing path. No fake focus is generated.

Renderer interception happens before IME interpretation, Control-key encoding,
flagsChanged character access, menu paste or input-activity reveal. Entry discards
local preedit, never commits it. Active-mode keyUp/flagsChanged cannot escape to
Kitty; after exit the existing press sequence rejects orphan repeats/releases.
A reset arriving before its coalesced UI notification consumes that current key
rather than reinterpreting it as input to a new epoch. Output replacement, reset,
controller release and explicit exit clear ownership/ref state. NSView lifetime
tests drain a local autorelease pool before asserting actual destruction.

An already-delivered program mouse press may receive its matched release while
entry cancels the old gesture, **before** acquiring the mode gate. Old wheel banks,
hover/links, native selections and pending gestures are discarded. No synthetic
selection mouse events or program-mode/config changes are introduced.

This initial keyboard milestone blocked/pinned pointer/wheel and scroller travel.
The subsequent [local pointer milestone](SCROLL-MODE-POINTER-COMPATIBILITY.md) now
implements VT gestures, local row-wheel navigation and bounded drag autoscroll.
Cmd links/program reports still do not escape the mode; scrollbar direct seek
remains pinned. Dedicated host drop/services/zoom/menu
integration remains later work; NSTextInputClient text/preedit and ordinary paste
entry points are already gated. This is not a claim of complete AppKit input parity.

## Publication, hold, hidden output and accessibility

Only `scrollModePresentation` resolves refs and captures the proposed viewport in
one VT transaction. Reads/navigation do not reveal numeric rows or tick animation.
The view uses this atomic path while mode UI is active, keeping the same bounded
row store, image scheduler and source. Reflow/settings retain the VT cursor and
cancel selection under the established core policy.

Hidden-connected output still parses/replies/returns credit but does not paint or
replace the published AX page. Hold keeps the existing frame and ownership;
Escape can always leave. Reset/screens end the UI when their core invalidation is
observed. A same-write screen roundtrip retains only a still-valid primary ref and
cancels core-cleared selection, per the documented frozen-ABI limitation.

The overlay is frame geometry and decorations only: **no second history, selection
formatter, image player, AX text model or terminal emulator**. AX remains read-only
published-page text. Mode cursor-specific AX announcements/VoiceOver behavior are
not implemented or certified by this overlay.

## Independently observed geometry / test boundaries

A real failing entry vector published a 250-pt clip with a 16-pt cell while VT still
had its initial **24 rows**. Mode chose row 100 with viewport top 77; the published
surface ended before that row and the cursor rectangle was empty. Entry now requests
real layout/metrics synchronization first (15 core rows in that vector). Fractional
live bottom explicitly uses the actual input cursor only when the published total
AND resolved tracked viewport still match. A separate failed regression reproduced
page pruning restoring the same total (1633 rows) while the old bottom ref moved:
checking total alone jumped to unseen row 1632. The fix also checks the resolved
ref position; the original equal-total/pruned-content vector is retained. The original no-first-layout vector remains
in the regression test, with its nonempty cursor and row-100 assertions.

The overlay requests its own backing and is ordered above the renderer's Metal
child. Hidden/offscreen windows were independently observed to expose an empty CA
sublayer array before commit; that is not evidence of incorrect or correct live
WindowServer stacking. Tests assert actual NSView ordering/backing plus real pixel
contributors instead of pretending to inspect an uncommitted CA tree.

Pixel tests use actual CG or offscreen Metal terminal pixels **plus the actual
NSView-drawn overlay bitmap** and check a cropped wide-cursor stroke, actual blue
VT selection, program-caret suppression/restoration and 1x/2x overlay raster geometry.
This is offscreen host composition, not a screenshot of a visible window, physical
backing-scale certification or WindowServer/display-device acceptance.

## Evidence

**23 new tests:** 19 UI/ownership/consumer cases, 3 actual-pixel cases and the
equal-total/pruned tracked-viewport regression. They
cover fixture entry, bindings/gg, selection/copy/Escape, exact command modifiers,
preedit, Kitty lifecycle, menu paste, pointer/wheel blocking, owner tokens, stale
reset/rebind, focus stability, hidden publication, hold, motion budget, actual owner
release, finite flash, and CG/Metal/overlay pixels. A real private raw PTY uses an
owned FIFO to issue a DSR while mode UI owns input: the child receives exactly
`ESC [ 0 n` (`1b5b306e`), no attempted mode text/IME/Control bytes, and no delayed
input after exit. It then exits with a completed guarded drain. No consumer bytes,
startup delays, response deadlines or old input are changed/replayed to make it pass.

Latest lab full run: **383 passed / 0 skipped**. Main: **362 passed / 1 system skip**.
Prior core-milestone nvim startup-ready timing failure remains recorded in the core
compatibility document; it is not claimed fixed and was not changed in this work.

## Next gates

Local pointer/drag/wheel/autoscroll navigation is now isolated in
[SCROLL-MODE-POINTER-COMPATIBILITY.md](SCROLL-MODE-POINTER-COMPATIBILITY.md).
Next add the remaining host/input-source/drop/menu ports and production adapters. Preserve the mutation
router/grants/journal, Herdr identity/credit/detach policy, Local async cleanup and
atomic whole-app dependency removal. Manual lab keyboard/IME/overlay, actual AX,
multiple panes/screens, sleep/device behavior and power/performance remain open.
