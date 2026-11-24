# Native 5A: theme data, typed settings and metadata

> **Current integration:** the shared implementation now lives in `Santty/Sources/Terminal/Native/` and is exercised by the formal `SanttyTerminalTests` suite against the production application module. See the [atomic cutover record](../../docs/plans/terminal-native-cutover.md) for current evidence and open manual gates. Scope/backend statements and counts below retain the original **pre-cutover milestone record**, not current production status.

Scope: isolated native frontend only. Main Santty still uses its old backend.
This adds **22 regression cases** (310 lab passed / 0 skipped); the separate
main run passed 362 with one system-capability skip. No new manual GUI, IME,
VoiceOver, device or power acceptance is inferred.

## Theme compatibility: same data, not the entire Ghostty config language

`Resources/TerminalThemes.json` freezes **485** exact-name records from
libghostty-spm `1d84cf66fe29abd1f24f10b88dcfc25882cf68ee`,
`Sources/GhosttyTheme/{GhosttyThemeDefinition.swift,Themes/*.swift}`. All colors
remain RGB8: foreground/background, cursor/cursor-text, selection foreground/
background and sparse palette entries. Names, defaults and missing-theme fallback
remain Catppuccin Mocha / existing names. 3024 Day and parenthesized theme names
are retained. The native runtime imports neither GhosttyTheme nor GhosttyTerminal.

This JSON is an **internal generated artifact**, not a new user theme format.
It does **not** add Ghostty theme-file/config-file import, named-color parsing,
includes, arbitrary Ghostty options, or automatic theme selection by appearance.
A light theme does not add an NSAppearance override: views inherit the app's
appearance, as before. Full configuration-language compatibility is not claimed.

The strict **offline** generator reads only a prepared source tree at the pinned
revision, requires every catalog symbol exactly once, rejects unknown/duplicate
initializer fields and invalid RGB/index data, and records source SHA-256 values.
No old package needs to be loaded/downloaded at runtime or at native build time
for this artifact. Existing combined workspace generation still prepares the old
package for the unchanged main app; that is not a native theme dependency.

```sh
python3 -B Scripts/Terminal/generate-theme-catalog.py --check
# Intentional regeneration, review the entire data diff:
python3 -B Scripts/Terminal/generate-theme-catalog.py
# After the old package is removed, provide the original prepared source explicitly:
# ... --source /owned/prepared/libghostty-spm
```

`Licenses/Theme-Adaptation-NOTICE.txt` includes full MIT permissions for @Lakr233
and Mark Badolato / iTerm2-Color-Schemes. The JSON and notice are app resources;
there is no converter that links the old TerminalConfiguration/C core back in.

## Typed preferences and VT authority

`NativeTerminalSettings` is an owned Sendable snapshot. Its explicit UserDefaults
reader uses the existing keys but never writes them: `terminal.themeName`,
`terminal.fontFamily`, `terminal.fontSize`, `terminal.padding`. Defaults are
Menlo / 13 / 8, size range 8...32, padding 0...24; invalid/nonfinite values normalize
without persisting changes. Missing font resolves to actual Menlo at the requested
point size (last-resort system monospace). Production notification/settings UI
integration is deliberately still a 5B/cutover task. The lab preview uses explicit
values, not standard defaults.

The driver sets VT **default** fg/bg/cursor/palette and default cursor shape/blink
under its existing lock. It never injects OSC/RIS to apply settings. Each sparse
palette starts from that terminal's frozen **VT builtin 256-color palette**, not
SwiftTerm defaults or the last theme's partial palette. Row palette identity and
program OSC overrides remain VT-owned.

Independent C + Swift vectors verify that program OSC green remains green when
the host default changes red → blue; OSC reset uses the new blue default; RIS
retains the new defaults. Program DECSCUSR still wins until CSI 0 q. A theme change
does not reset history, modes, process, selection or metadata. A geometry change
can legitimately cancel a selection / end a render hold via the existing VT resize
contract; reading anchors preserve content and fractional position.

**Current padding behavior:** The NSScrollView fills `NativeTerminalAppearanceHost`
and the production `TerminalPaneHostView`. `NativeTerminalScrollView.tile()` lets
AppKit place the scrollers at the pane edges, then insets only the clip view by
the configured padding (in AppKit points). Padding does not inset the scrollers.
Zero means zero layout inset, though incomplete cell columns/rows can still leave
grid remainder. Document coordinates, native history/elasticity and bounded renderer
geometry are unchanged. Font/padding layout is batched to avoid an intermediate wire
resize.
Colors, selected-cell attributes, cursor text and default-background opacity
commit alongside a presented frame. Color-only changes respect render hold;
hidden connected views retain old pixels while default color/display facts update.
Callbacks fire outside the VT lock and do not request focus or fabricate input.

Explicit SGR cell backgrounds retain the renderer's normal opaque-cell policy;
only the default background gets the snapshot opacity. Missing selection colors
use semantic AppKit fallback resolved under effectiveAppearance. The native lab
preview chooses opacity 1 because it has no production vibrancy host; the typed
production-compatible default remains 0.

Actual CG/Metal readbacks cover themed palette glyphs, selected-cell background,
block-caret text and default-background alpha 0.25. CG default pixels are deliberately
transparent content over a CALayer background. Sampling `cacheDisplay` alone omitted
that contributor, and an uncommitted hidden layer was stale; the final test composes
the actual AppKit content bitmap over the actual layer background through Core
Animation, keeping the original alpha assertion. No renderer workaround, color
rewrite or weaker expected alpha was added. This is owned offscreen composition,
not WindowServer/display-profile/manual certification.

## Padding Fill (current production behavior)

`terminal.paddingFill` is `off`, `automatic` (default, also for unknown values), or
`always`. Automatic uses the published VT alternate-screen flag, not process names,
PIDs or screen-text inference. The Terminal settings picker applies immediately;
font zoom preserves the choice. Reading defaults does not write them.

`NativeTerminalPaddingFillView` extends each visible row's first/last background
horizontally into left/right padding and right-side incomplete-column remainder.
Top/bottom padding, corners above/below the grid, and incomplete-row remainder keep
their original background: status-line color blocks never grow taller.
It resolves palette/RGB/default
colors and inverse attributes from the **owned published frame**; selection, caret,
text glyphs and image pixels are not sampled. Default-background alpha is preserved,
explicit SGR backgrounds remain opaque, and viewport default pixels are not painted
a second time. Elastic overscroll suppresses extension instead of inventing cells.

The outer decoration sits behind the scroll view. A second viewport-bounded
instance sits above the renderer in the virtual document, below AppKit's scroller,
for right-side grid remainder only. Both ignore hit testing and accessibility; inactive fill
views are hidden so ordinary primary-screen output does not repaint empty surfaces.
They add no VT capture, input, resize, focus, parser callback, timer or animation wake; synchronized
output uses the old published edges until the hold releases, and reset clears them.
`NativePaddingFillTests` exercises actual sRGB painter pixels (including both renderer
choices), alpha, palette/inverse/selection, holds/reset/screen transitions, fractional
history scrolling, production layout and injected preference persistence/notifications.
This is offscreen coverage, not a WindowServer/manual visual certification.

## Owned title/cwd metadata, independent of presentation

`NativeTerminalMetadata` is an exact-UTF8, change-revisioned snapshot. Title and
**raw** pwd are copied from VT under the driver lock after parsing; the C title/pwd
callbacks only dirty state. No borrowed pointer survives a call and no UI/user
callback or sync-main hop occurs inside the parser lock. Each field is capped at
**16 KiB**, strict UTF-8: empty means explicit clear, nil means unavailable.
OSC 7 URI hosts/percent encodings remain untouched. No URL, stat, cwd resolution,
process lookup or local interpretation of remote paths occurs here.

`NativeTerminalOutput.onMetadataChange` publishes a coalesced owned snapshot on
MainActor **before** its presentation callback. Parsing/replies/Herdr credit do not
wait for that delivery. Hidden output and synchronized-output holds still update
metadata. Exact NFC→NFD changes are not lost to Swift's canonical String equality.
Reset/reconnect queued delivery reads the newest snapshot, never a captured old one.
The lab observer also checks the current endpoint identity before updating tooltip.

The frozen VT resets title/pwd for both parsed RIS and explicit host reset, but its
RESET callback fires **only for RIS**. The driver explicitly establishes a host
reset epoch if the callback did not advance it, avoiding duplicate increments.
The independent C probe records this difference. A 16,385-byte OSC title is rejected
earlier by this pin and remains empty; the original vector is retained. The host
copy-cap / invalid-UTF8 / owned-storage boundary has separate direct byte tests,
not a false claim that the OSC reached the host cap.

This metadata is **not** a Herdr binding, remote navigation identity, filesystem
cwd or agent-status inference. The future production pane must still prefer core
records where appropriate and apply its explicit local cwd/foreground policy.

## Evidence and manual entry

```sh
sh Scripts/Terminal/probe-vt-settings.sh
flowdeck test -s SanttyTerminalLab -d /tmp/santty-security-validation.Dwb7Pg \
  --only SanttyTerminalLabTests/NativeTerminalSettingsTests \
         SanttyTerminalLabTests/NativeTerminalMetadataTests \
         SanttyTerminalLabTests/NativeMetadataPublicationTests \
         SanttyTerminalLabTests/NativeThemeRenderingTests --json
```

9 settings + 6 metadata + 2 publication + 4 rendering cases, plus one actual
owned Herdr consumer (raw metadata, >initial-credit hidden output, theme defaults
and reconnect binding/reset) = **22**. Existing tests remain; eight SwiftTerm
patches and the precompiled VT archive are unchanged by this milestone.

One full run exposed the existing Neovim test reading an empty result immediately
after `fileExists`: writefile creates/truncates before its body completes. The
independent headless observation had 0 empty / 64 complete samples, so it did not
reproduce that rare stack timing. The real failing trace is retained. The test now
waits for the **same exact result bytes within the same deadline**, keeping its final
assertion and input bytes unchanged. No production delay/retry or consumer byte
rewrite was introduced; the earlier fast paste+CR nvim limitation is unchanged.

Restart the rebuilt lab. Menu **Preview next theme (Mocha / 3024 Day)** changes
only settings, including while an owned private session is connected; it never
injects fixture bytes or changes saved preferences. Live status tooltip shows
bounded title/raw cwd. Private session/fixture safety gates remain in place.

5A is not whole-app migration: production launch policy, full CLI/history reads,
keyboard Scroll Mode, pane/app async close, input-source/metadata precedence,
all layout locations, main dependency removal and outstanding manual acceptance
are still listed in the [migration audit](../../docs/plans/terminal-framework-migration-audit.md).
