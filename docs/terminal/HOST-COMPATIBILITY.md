# Native host action / input-source ports (isolated 5B)

> **Current integration:** the shared implementation now lives in `Santty/Sources/Terminal/Native/` and is exercised by the formal `SanttyTerminalTests` suite against the production application module. See the [atomic cutover record](../../docs/plans/terminal-native-cutover.md) for current evidence and open manual gates. Scope/backend statements and counts below retain the original **pre-cutover milestone record**, not current production status.

The main app still uses its old backend. This stage supplies reusable ports and
lab menus, **not** production pane factories, settings notifications, foreground
providers, close/save barriers or a CLI router replacement. No dual-core link,
core rebuild, runtime toggle or saved FlowDeck configuration change.

## Responder, menus and drops

- `NativeTerminalHostActions` belongs to one native view; the input renderer
  remains first responder. Copy / Paste / Select All and font increase/decrease /
  reset are responder-chain actions, with matching lab Edit / View menus.
- Hidden/non-responder views refuse actions. Paste also requires enabled input,
  an exact live output writer and no suppression owner. A rejected Cmd-V does
  not swallow another responder's shortcut. Mode Cmd-V/A remain consumed by the
  existing Scroll Mode key owner; Copy delegates to its VT selection formatter.
- Read-only selection/copy remain available after terminal input closes. Select
  All reuses ordinary interaction gesture cancellation. Zoom changes only typed
  settings, preserves other theme/caret/padding/opacity fields and focus, and
  writes no preferences or terminal input. The production preference adapter
  must supply `zoomResetSize` when settings change.
- Drag enter/update inspect supported types only. Drop reuses the production
  `TerminalPasteboardText`: URL strings/path shell escaping, multiple file URLs,
  then unchanged plain text. Only an explicit, valid drop may focus its **own**
  renderer. No file read, staging/upload, shell command concatenation, handler
  opening or remote cwd interpretation is performed. These are user-supplied
  insertion literals, not claims that local paths exist on a remote machine.
- A deferred drop owns its bounded offered text; AppKit accepting that offer is
  not terminal queue acceptance, remote delivery or command execution. Copy-only
  drag operations never authorize deleting/moving source files.

## VT-owned safe paste

`GhosttyVTDriver.prepareHostPaste` calls the original archive's
`ghostty_terminal_paste`, with a synchronous owned text reader and a temporary,
separate write sink under the existing VT lock. No user writer/UI callback runs
under that lock; automatic reply capture stays separate. AppKit does not
recognize terminators or recreate bracketed framing/sanitization. TEXT source
never installs an OS clipboard reader or grants a program clipboard access.

The original independent C vectors are retained in `Tools/probe-vt-paste.c`:

| Vector | VT result / exact output |
| --- | --- |
| ordinary text | accepted without review |
| legacy LF | `GHOSTTY_REJECTED`, zero bytes |
| confirmed legacy LF | LF becomes one CR |
| original un-normalized CRLF | **two CRs**; preserved original control |
| bracketed CRLF | no review, original CRLF within VT framing |
| embedded bracket terminator | rejected, zero bytes |
| explicitly confirmed terminator | VT strips ESC to a space within framing |

The host keeps the existing native legacy CRLF→LF preprocessing, so confirmed
CRLF becomes **one CR**, not two; bracketed bytes are unchanged. No sleeps,
protocol retries or paste→Enter timing workaround were added.

Unsafe UI paste offers at most **1 MiB UTF-8**, one review, escaped 256-scalar
preview and a **120 s** age checked at approval. The default uses a nonblocking
Cancel / Paste Once sheet, no remembered permission. Consent is single-use,
including writer refusal or partial failure. There is no successful prefix,
automatic retry or re-targeting.

Approval checks the same view/responder/output/driver, writer generation, reset epoch,
input gates and bracketed mode. Rebind, reconnect enable roundtrip, parsed RIS,
new user input, suppression roundtrip, mode entry, replacement, cancellation or
expiry cannot send an old offer into a new input context. Automatic replies and
metadata do not revoke user consent or become paste data. The existing checked
transport writer is still the only submission point. Snapshot checks are not a
promise that a program cannot change modes after submission or execute input.

The cap bounds offered/copied content, not all Foundation/C RSS. Reading an
NSPasteboard representation can allocate before the cap is inspected. Encoded
framing can exceed a transport's remaining queue budget and be refused; budgets
are not enlarged, history stays **8 MiB**, input is never replayed.

## Input-source and named-key ports

`NativeTerminalInputSourcePort` builds the **existing**
`PaneInputSourceCoordinator.Target`; it adds no rule engine, timer, process scan,
source catalog or selection policy. The lab target compiles shared coordinator,
settings and system-source files directly, not copies. The lab does **not** start
the system coordinator or select a user's input source.

A target requires the current exact owner, focused visible renderer, enabled
writer, no Scroll Mode and no preedit. Foreground results are rechecked after
await against owner, output generation, reset, user input, focus/composition and
cancellation. Synthetic injected-source tests use the real coordinator to
verify editor precedence and preservation of a manual choice; they never query
or change the user's system source.

Production wiring still must provide authoritative foreground data: validated
owned Local PTY group/process facts versus core-bound Herdr records. The
provider must itself validate its foreground identity across await. Never treat
a local PID as its group, inspect remote PIDs/paths locally or use this port to
infer agent completion/state. Command-palette destination/restore integration,
real TIS/IME behavior and live Local/remote foreground acceptance remain open.

`NativeTerminalNamedKey` maps validated shared `CLIKey` values to semantic VT key
events (26 control letters, named keys, Ctrl/Shift). It does not resolve panes,
focus/reveal them, open a socket, grant input or bypass router retry journals.
The production CLI still must validate authorization and exact post-await pane
identity. Scroll Mode output ownership refuses these keys without replay.

A retained negative test first proved that manually attaching a foreign-driver
output could accept a fresh paste and create a foreground target. Both ports
now reject that driver mismatch before encoding/querying/writing; no foreign
writer receives the bytes. Factories must still bind the view/driver/session
consistently through the checked attachment path.

No process-wide Services provider/requestor or new AX setter/action was added.
Production Prompt Editor and other host decorations remain separate work.

## Independent pixel-readback diagnosis

The first complete run was **429 pass / 7 fail / 0 skip**. Five existing image
and two overline CG tests failed, including pure green read as `[162,245,43]`.
Two unchanged isolated cases reproduced. No native host tests had run before
these image failures, ruling out the new zoom/foreground test side effects.

`Tools/probe-appkit-color.swift` draws independent AppKit-only swatches and an
sRGB CGImage in an owned offscreen window, with **no terminal dependency**. On
the current `S273 DP` profile it reproduces the original `colorAt` error. Keeping
the CGImage ICC tag and drawing into an explicitly tagged sRGB bitmap gives:

| Source | Original `colorAt`→sRGB | ICC-managed readback |
| --- | --- | --- |
| sRGB green | `[162,245,43]` | `[9,255,1]` |
| calibrated green control | `[154,240,39]` | `[0,249,0]` |
| sRGB red | `[227,80,23]` | `[255,0,1]` |
| calibrated red control | `[230,92,18]` | `[255,38,0]` |
| sRGB CGImage green | `[162,245,43]` | `[9,255,1]` |

`NativeTestBitmap` corrects only the two faulty test readback paths, retaining
the actual source ICC profile, top-first geometry and straight RGBA contract.
A separate controlled Display-P3 offscreen regression verifies color/orientation.
Original image inputs, assertions and color tolerances remain unchanged.

The remaining two style failures exposed a second false premise: their reference
assumed calibrated RGB. The pinned SwiftTerm `MacExtensions.TTColor.make`
actually constructs an **sRGB CGColor**. The original calibrated swatches remain
in the independent probe; CG tests now use a separate plain AppKit sRGB swatch
through the same tagged readback, not renderer-derived expected pixels. Actual
managed red `[255,0,1]` versus the old reference `[255,38,0]` is retained evidence.
No renderer, core, shader, global display setting or ICC profile was changed.
This corrects the older README's calibrated-reference interpretation, not a
claim of exact cross-device or cross-backend color equivalence.

## Validation and remaining gates

- **23** host/receipt/selection/menu/drop/named-key tests, including a real private
  raw PTY/FIFO consumer: no unsafe bytes before approval; exact DSR response;
  confirmed legacy `610d62`; bracketed `1b5b3230307e610d0a621b5b3230317e`;
  natural exit with finite guarded output drain.
- **10** foreground/responder/epoch/IME/cancellation tests with synthetic system
  source callbacks; **1** independent profile/orientation regression.
- Final full lab **438 pass / 0 skip**; main **361 pass / 2 existing environment /
  system-capability skips**. Dependency inventory remains 8 production / 7 test
  files, 16 old imports; all 8 audit tests pass. The removal gate is intentionally
  still failing until the atomic cutover.

The subsequent reusable session/frontend/mixed-close stage is documented in
[SESSION-COMPATIBILITY.md](SESSION-COMPATIBILITY.md); production callers are still
not switched. The totals above describe this host-action milestone.

Actual drag sessions/menu validation/sheets/IME/TIS/VoiceOver, WindowServer
composition, multi-pane/cross-screen/sleep/device/energy certification remain
unaccepted. No GUI automation, activation of user windows, TCC changes or shared
core operations were performed. Production factories, title/cwd precedence,
settings/foreground/palette adapters, all-level close/save/CLI final-window reply
ordering and atomic old dependency retirement remain the next migration work.
