# Input compatibility audit

This is an implementation/coverage ledger, not a declaration of complete terminal compatibility.

## Fixed references and licenses

- herdr-app `a547b16ccb5e8811b2dd8b3b901d31df8f05e55a`:
  [key_bytes / control_alias_bytes / map_key](https://github.com/herdrdev/herdr-app/blob/a547b16ccb5e8811b2dd8b3b901d31df8f05e55a/src/terminal.rs#L1404-L1491),
  [keyboard vectors](https://github.com/herdrdev/herdr-app/blob/a547b16ccb5e8811b2dd8b3b901d31df8f05e55a/src/terminal.rs#L3884-L3996),
  [encode_key](https://github.com/herdrdev/herdr-app/blob/a547b16ccb5e8811b2dd8b3b901d31df8f05e55a/src/vt.rs#L1690-L1730).
  Adapted policy/vectors: Apache-2.0, preserved in `Licenses/Herdr-app.txt` and `Licenses/Keyboard-Adaptation-NOTICE.txt`.
- SwiftTerm `28c6d1d95de156a36a2eaa278177ee7f8a15d322`:
  `MacKeyboardRouter.swift` (composition, Option text, reported presses, releases, flagsChanged),
  `MacTerminalView.swift` (NSTextInputClient and pointer/scroll platform policy);
  `KeyboardRouterTests.swift`, `KittyKeyboardAppKitReproductionTests.swift`, `KittyOptionComposeTests.swift`.
  `UntrustedTerminalLink.swift` supplies the unsafe-scalar reference (itself adapted from Ghostty 77537c8);
  `Terminal.swift` supplies linear scheme-URL tokens and cell-range mapping, `MacTerminalView.swift` modifier/hover lifecycle; platform clipboard delegates demonstrate copying borrowed data and avoiding main.sync.
  MIT licenses retained in `Licenses/SwiftTerm.txt` and `Licenses/Link-Adaptation-NOTICE.txt`.
  Rendering also adapts Attribute/CellArena, CG/Metal decoration passes and inactive caret outlines; see `Licenses/Rendering-Adaptation-NOTICE.txt`.
- Actual engine: official precompiled libghostty-vt **1.0.0**. Do not substitute Herdr's older C ABI or SwiftTerm's Kitty flag layout. No new parser/encoder is linked.

## Boundaries

```text
NSEvent → NativeAppKitKeySnapshot (capture only; no encoding)
        → NativeKeyNormalizer (pure snapshot → semantic event)
        → NativeKeySequence (delivered press identity / repeat / release)
        → NativeTerminalInput (key | committedText | paste | focus | mouse | wheel)
        → NativeTerminalOutput.send (one user writer)
        → GhosttyVTDriver.encode (live VT modes and C key/paste encoders)
        → current Herdr channel (no offline queue)
```

Physical Ghostty/W3C identity, logical Control identity, layout text and unshifted codepoint are distinct. The OS's translated C0 character wins over a conflicting physical/ISO/non-Latin position: the adapter describes the corresponding logical key to the C encoder without feeding C0 as text; physical identity remains available for lifecycle matching. Original modifiers and consumed modifiers are separate. C0/C1/DEL and platform function-key characters are never encoder text. A modifier-only NSEvent has no character accessors: reading them raises an AppKit exception.

IME/dictation commits are UTF-8 text, not a fabricated unidentified key and not bracketed paste. Physical keys during preedit stay with the input method. A delete which only ends preedit must not also delete terminal input. Empty marked text removes its overlay. Focus loss, disconnect, reset and Option-policy changes clear composition and delivered-key state. Orphan repeats/releases are dropped; release identity survives layout changes, and repeat cannot silently become a different layout key.

## Behavior and evidence

| Area | Reference / decision | Current automated evidence |
| --- | --- | --- |
| C0 and consumed modifiers | Herdr key/VT adapter plus SwiftTerm OS-translation precedence; not raw Ctrl text | Golden Ctrl, Shift punctuation, uppercase, C0/C1/PUA filtering; non-Latin, ISO and physical-C/layout-J fixtures |
| Legacy aliases | Herdr caller-side I/M/[/minus aliases | Literal legacy and modifyOtherKeys transition bytes; Kitty keeps chords |
| Mode parity | Herdr vectors translated to snapshots | 26 independent vectors × legacy / Kitty 1 / Kitty 9 = 78 byte checks; no self-generated expected bytes |
| Kitty lifecycle | Kitty protocol + SwiftTerm reported-press policy | All flags 1–31: press/repeat/release, plus modifier press and release before text-key release |
| Option | Herdr side policy; SwiftTerm macOS text-input policy | left/right/both Meta versus text, across legacy/Kitty; composed text under report-all has no orphan release |
| AppKit vs GPUI difference | SwiftTerm deliberately sends Option/AltGr composition as text even under report-all | Native view uses text intent; low-level C encoder vectors separately retain Herdr's physical-key expectations |
| Application modes | Modes read from VT, never duplicated | Cursor keys, keypad and DEC 1035 Num Lock override; default numeric keypad is intentional, not an encoder regression |
| IME | SwiftTerm preedit/commit/edit distinction | Unicode/emoji commits under report-all, cancel/delete, empty preedit, focus cleanup and actual candidate coordinates |
| Paste | Ghostty C sanitization/framing; Herdr legacy CRLF normalization | bracket on/off, delimiter injection/control bytes, CRLF as one CR when unbracketed |
| Real consumer | Private core/session/home only, clean nvim | SIGINT + subsequent shell input; nvim command entry/execution; literal multiline paste in normal and insert modes; command-line bracketed paste |
| Authorization/lifetime | Existing Santty Herdr state machine | Identity refusal, viewer detach, reconnect, no replay, credit after parsing and private cleanup remain covered |
| Mouse protocol | Ghostty C modes/encoder, independent herdr-app-derived literals | X10/normal/button/any tracking; legacy/UTF-8/SGR/urxvt/pixels; modifiers, extra buttons, motion dedup, fractional/Retina coordinates, stale modes/geometry and release during hold |
| Wheel ownership | AppKit native history or Ghostty mouse/application arrows, never both | Fraction banks, Shift override, mode/route changes during momentum, resize cancellation, phaseless precision devices; native dispatch boundary checked in hidden windows |
| Selection/copy | Ghostty tracked gesture + formatter; SwiftTerm only paints owned ranges | Character/word/line/all, Unicode/soft wraps/history, reset/resize/screen invalidation, explicit clipboard limit, drag autoscroll and actual CG/Metal selection pixels |
| History anchors / selection hits | Ghostty owned tracked grid reference; atomic resolution/capture under driver lock | Prune/reflow/font/height changes, original nonzero column, fallback to oldest, reset/RIS/screen invalidation; pending-output hit rebasing, stale-hit refusal, copy and drag autoscroll |
| AppKit multi-click | Release ends the active drag, not VT's click sequence | Real native-view press/release pairs select words and lines; an unapplied release still cancels safely |
| Real pointer consumers | Owned private core and tmux socket only | Clean nvim cursor position/topline and tmux selected pane/copy mode, not only terminal appearance |
| Explicit links | Santty shared parser, SwiftTerm unsafe scalars, Herdr host-gesture precedence | OSC 8 owned URI snapshots; safe http/https/mailto only, no local FS; raw-byte target changes, wide tails, bounded payloads, Cmd release/drag/reset and exclusive program routing |
| Plain URL / hover | SwiftTerm scheme-only URL tokens and cell ranges, applied to owned VT frames; no second emulator/path lookup | Fixed URLs/punctuation/IPv6, UTF-16/wide/combining/wrap-spacer mapping, OSC 8 precedence and clipped-prefix refusal; stationary Cmd, exit/release, tiny cross-cell clicks, scroll/font/width rehit; actual CG/Metal underline pixels; unpresented target changes refused under VT lock |
| Overline / hollow | SwiftTerm interned attributes and existing CG/Metal decoration/outline geometry; Ghostty owns shape/blink and DECSCUSR | 12 style tests: actual pixels, blank/shaped/wide/combining cells, foreground/palette/selection/hover/conceal, independent hollow/focus/blink, default versus program override, unchanged packed-cell width; backend color contracts checked separately, not exact cross-backend color certification |
| Image API / owned snapshots | Frozen VT image iterator resolves geometry; no second image parser, file transport or history store | 15 snapshot + 21 presentation + 11 PNG decoder tests and private Herdr PNG stream: actual CG/Metal RGBA pixels, precise size/offset/crop/layers, crop-edge bleed fix, image-only changes, cache eviction/sharing, history/screens/reset/hold and both Metal buffer modes; zero-source virtual slice remains explicitly limited. Static direct f=100 PNG works through startup ImageIO/vImage; strict output/extent limits, allocator ownership, low/zero alpha, negative inputs and pinned same-ID retirement are tested. Animation/APNG and full device/protocol certification remain open. See IMAGE-COMPATIBILITY.md |
| Program clipboard | Herdr bounded last-value/UTF-8/location policy, Santty explicit confirmation intent | No read callback or remembered grants; synchronous write denial; separate explicitly reviewed host copy, at most 1 MiB/120 s, replacement/expiry/offline/rebind/reset refusal and unique test pasteboards |
| Clipboard/transport | Existing Santty lifecycle, no parser-to-main synchronous dispatch | Main blocked while parsing/replies finish; real private core output beyond initial credit drains with offer pending; reconnect rejects old confirmation |
| Native remote | Two private cores through hc machine via, no existing profiles | Remote PTY reads fixed mouse bytes; permanent identity/PID across viewer reconnect; offline input drop, selection reset, viewer-only detach |

The former command-line paste observation is retained as an executable test, **not** bypassed with text commits. Its readiness acknowledgement now runs from Neovim's command-line event loop (`timer_start(0)`), rather than treating the start of CmdlineEnter as completion. All three mode-specific paste tests currently pass, including an assertion that bracketed paste is enabled. No single production root cause is claimed for the earlier observation; repeat these cases instead of assuming it was impossible.

A later security-suite repeat reproduced a distinct fast paste+CR ordering problem in nvim 0.12.5: wire bytes were correct, CmdlineLeave was empty, and pasted text landed in the normal buffer. A direct private PTY with no Santty/Herdr/VT adapter reproduced burst failure 3/3 and applied-text-gated success 3/3. This matches that version's command-mode `vim.paste` queueing `nvim_feedkeys` behind already-buffered input. The native consumer test now waits for CmdlineChanged to contain the actual command before sending AppKit Enter, still uses real bracketed paste, and asserts literal wire framing; its 10-iteration rerun passed without longer timeouts. No production timing workaround was added. `Tools/check-nvim-paste-order.py` retains the burst/control comparison as diagnostic evidence, not a claim that fast-burst compatibility is fixed or that every older observation had this cause.

The actual paste normalization bug found by the new matrix was legacy CRLF becoming CR+CR in the C helper. The adapter now collapses CRLF before asking the helper to encode unbracketed text; bracketed text preserves its original newlines and the C helper still sanitizes unsafe control bytes.

## Clipboard ABI and deliberate differences

VT 1.0's frozen clipboard callback/reply pointers expire when that synchronous callback returns. Blocking it on a main-actor consent prompt can deadlock the VT lock and stalls parse-credit progress. Herdr's older adapter queues a bounded string but immediately reports success; SwiftTerm's async read path emits its own later protocol reply. Neither can be copied as-is here.

The adapter denies the original protocol write and copies bounded owned plain text into one review offer. Only an explicit user action writes it to the OS pasteboard, and it never reports the protocol write as committed or records a grant. Kitty callers see EPERM; a manual Copy Once does not retroactively acknowledge that operation. Reads stay disabled, so OSC 52 reads are ignored and Kitty reads refused. This is **not** complete clipboard protocol/permission parity. Standard user copy/paste is separate.

## What is not certified

- Every physical keyboard layout, IME, dead-key/press-and-hold menu, dictation, Fn/system shortcut and Command-menu customization. Snapshot fixtures do not replace OS-level device verification.
- Option policy has a tested adapter setting; main-app preference integration is not done.
- Full AppKit editing-command behavior, rectangular selection, advanced Command routing, bare-domain/path detection and long links clipped outside the bounded captured frame, local-file/custom-handler approval, accessibility and main-app input-source integration.
- Program clipboard reads, complete Kitty/multi-MIME clipboard support or an async VT request-completion API. Current manual offers and synchronous denial are intentional, not silent permission expansion.
- Physical mouse/trackpad inertia, elastic scrolling and cross-display scale behavior. Synthetic windowless wheel events in hidden test windows verify dispatch, not native device feel.
- Exhaustive stress of mode changes midway through every composition/shortcut, real SSH/cross-machine faults, local PTY and all consumers. The private proxy regression is not real-network acceptance.
- Current conformance is pinned-engine/macOS behavior, not cross-platform GPUI compatibility or performance acceptance.

The user should test natural experience/device-specific behavior, not enumerate basic protocol combinations. Extend independent vectors and consumer assertions for any new failure. Never test against existing user terminals or restart a shared core.
