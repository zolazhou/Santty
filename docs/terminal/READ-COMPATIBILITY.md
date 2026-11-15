# Full retained-history read boundary (isolated 5B)

> **Current integration:** the shared implementation now lives in `Santty/Sources/Terminal/Native/` and is exercised by the formal `SanttyTerminalTests` suite against the production application module. See the [atomic cutover record](../../docs/plans/terminal-native-cutover.md) for current evidence and open manual gates. Scope/backend statements and counts below retain the original **pre-cutover milestone record**, not current production status.

## Authority and ownership

`GhosttyVTDriver.readScreenText()` owns one temporary plaintext snapshot of the
**currently active screen and all its retained VT history**. It does not sample
SwiftTerm cells, the AX page or render overscan. There is no second parser,
scrollback store, history cache, image resolver or persistent text mirror.

The driver's lock covers formatter creation, configuration, synchronous writes
and destruction. A formatter-local **nil selection** means the entire screen;
it neither borrows nor changes the user's selection. A private internal writer
copies each borrowed C slice immediately. No pointer escapes the callback or
formatter lifetime. No user callback or AppKit work runs inside that lock.

`NativeTerminalReadService` binds one pane UUID to one concrete driver. It
accepts only validated `read`/`search` requests for that UUID, and executes
formatting plus the existing production `CLITextSnapshot` on a detached utility
task. Cancellation is forwarded to that task and checked before capture, at
writer boundaries, and around response processing. It does not require the
MainActor to make progress. Parsing and reads serialize on the same driver;
large reads can therefore delay parsing while they hold its lock. This is not a
latency/throughput certification or a lock-free reader.

## Existing CLI text contract

- VT plain output, `unwrap=true`, `trim=true`: soft wraps join into logical lines;
  internal blank lines remain, trailing spaces and trailing blank grid rows do
  not create extra CLI lines. Empty text has **zero** CLI lines.
- Existing `CLITextSnapshot.swift` is compiled into the lab, not forked. Tail,
  1-based inclusive ranges, literal/case-insensitive search, result limits,
  Unicode clipping and the **256 KiB response-text budget** use that same code.
- Line numbers describe that single current snapshot. They are not stable grid
  references, physical rows or identities across later output/reflow/pruning.
- Alternate-screen reads do not expose primary-screen history. Leaving alternate
  screen restores the core's current primary contents; reset discards old data.
- Reads during synchronized-output hold or hidden/disconnected presentation see
  **parsed current text**, not the older published visual/AX page. Reading never
  ends the hold, reveals the live screen, publishes a frame or advances animation.
- Concealed SGR text remains in formatter plaintext, just as in old CLI read_text.
  **This is not AX's conceal/image-placeholder redaction policy.** CLI text is not
  a visual screenshot or a safe-redacted diagnostic export. Images are not OCRed.
- Only retained current cells can be read. Pruned/erased/overwritten output and
  original program bytes cannot be recovered from this API.

## Separate limits and failures

The native formatter writer accepts at most **32 MiB of UTF-8 per snapshot**.
An over-budget result is an explicit `snapshot_too_large` failure: the partial
prefix is discarded, never returned as a successful truncated history. Bad UTF-8
is refused, not repaired. No retry, parser reset or history-budget reduction is
used to make a read succeed. The production default remains **8 MiB VT history**.

This snapshot budget is separate from CLI response clipping and the bounded AX
page. Currently even tail/range requests first capture the complete screen;
narrowing a request cannot bypass a failed full-snapshot budget. It is a bound
on accepted snapshot bytes, **not** total RSS, C/Foundation temporaries or a
promise that every valid retained terminal fits. Tests can supply a smaller
internal cap; it is not a user CLI option or a second history limit.

A successful response may still have the existing CLI `truncated` flag for
requested tail/result/response limits. That never authorizes silently dropping
retained history before searching or assigning line numbers.

## Independent evidence

```sh
sh Scripts/Terminal/probe-vt-read.sh
flowdeck test -s SanttyTerminalLab -d /tmp/santty-security-validation.Dwb7Pg \
  --only SanttyTerminalLabTests/NativeReadSnapshotTests \
         SanttyTerminalLabTests/NativeCLIReadServiceTests --json
```

The tiny C client uses the **original precompiled archive** and `format_buf`,
independently of Swift's bounded streaming writer. It fixes full-history,
logical/physical wrap, conceal, alternate/primary and pruning/viewport vectors.
The original failed assumption is retained: a 10-line configuration with 100
records keeps the first record (`actual_rows=101`). Feeding the remaining
100…9999 records forces core page pruning (`actual_rows=865` on this frozen
archive), with no stale first record or viewport change. The host must not
invent a strict 10-row cut or alter the production byte budget.

The existing old-backend `CLITests` snapshot test additionally verifies the same
logical-wrap and concealed-text policy in its **separate executable**. Old and
new core archives are never linked together for comparison.

**17 new tests** cover limits/refusal, 6000 retained Unicode lines, wraps/blank
rows, exact composed/decomposed bytes, selection, pruning/screens/reset,
hold/metadata, animation deadlines/generations, concurrent parsing, shared CLI
ranges/search/tail/limits, hidden published AX/viewport/focus/private clipboard,
cancellation and a deliberately blocked MainActor. Existing owned Local PTY
6000-row and private Herdr >initial-credit consumers now also call the read
service. Full lab: **327 passed / 0 skipped**; main: **362 passed / 1 system skip**.

## Still pending

This is **not production CLI/backend cutover**: no lab socket server, new grants,
journal or mutation route was added. The main app still uses its old reader.
Its future pane adapter must retain pane/endpoint identity across awaits, never
retarget or retry against a replacement terminal, and preserve the router's
read-only/mutation separation. Reusable Local launch/close ownership is now isolated
in [OWNERSHIP-COMPATIBILITY.md](OWNERSHIP-COMPATIBILITY.md), not wired into production.
Keyboard Scroll Mode's physical-cell port, host/input-source integration and
whole-app dependency removal remain separate 5B/5C work. No new GUI/TCC, AX-server,
VoiceOver, IME, cross-device, sleep or power certification is claimed.
