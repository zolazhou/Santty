# Native image compatibility ledger

## Status: raw/static PNG images plus VT-owned Kitty animation

The pinned precompiled **Ghostty VT 1.0.0** supplies owned pixels and resolved placements through `GhosttyVTImages` / `NativeTerminalFrame.imageSnapshot`. `SwiftTermFrameSource` now submits supported raw RGB/RGBA and static `f=100` PNG images to SwiftTerm's existing CG/Metal passes, including VT-decoded zlib data. Independent image readback verifies pixels, not just protocol acceptance. **Kitty animation deadlines are now scheduled, not GIF/APNG decoding. Complete protocol parity and animation GUI/device acceptance remain open.** User confirmation covers PNG display in the current environment; it is not inferred acceptance of animation or both rendering paths/devices.

No image protocol parser, placement resolver, animation state machine, second history store or rebuilt C core was added. The GUI remains experimental and the main application still uses its old backend.

## Fixed references

- The prepared VT artifact and checksums are unchanged; see [README](README.md#依赖与隔离).
- Frozen headers: `ghostty/vt/{kitty_graphics,render,sys,terminal}.h` in the artifact.
- SwiftTerm `28c6d1d95de156a36a2eaa278177ee7f8a15d322`: `KittyGraphicsSnapshot.swift`, `Apple/AppleTerminalView.swift` and `Apple/Metal/MetalTerminalRenderer.swift`.
- herdr-app `a547b16ccb5e8811b2dd8b3b901d31df8f05e55a`, `src/vt.rs`: owned-image boundary, fixed PNG and placeholder fixtures. Its older ABI and handwritten virtual-placement resolver are **not** copied into the current VT adapter. Attribution: `Licenses/Image-Adaptation-NOTICE.txt`, `Herdr-app.txt` and `Ghostty.txt`.

## ABI audit

| Concern | Pinned API / result | Adapter decision |
| --- | --- | --- |
| Active screen storage | `GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS` | Borrow only under the driver lock; never retain the handle |
| Pixels | `ghostty_kitty_graphics_image_get`, `FORMAT`, `PIXELS`, `WIDTH`, `HEIGHT` | Copy once per image generation to immutable, top-row-first straight-alpha RGBA8 |
| Ownership | `PIXELS` borrows terminal memory until its next mutation | Returned snapshots survive replacement, reset, screen changes and driver destruction |
| Content identity | `IMAGE_GENERATION`; values are not reused across images/screens/terminals | Key reuse by image ID plus generation, never just size/ID |
| Placement identity/change | Render-state image iterator and `IMAGE_PLACEMENTS_GENERATION` | Read the render list, not both render and storage placement lists; keep an owned revision for presentation |
| Geometry | Viewport row/column, grid extent, cell offsets, destination pixel dimensions and source rectangle | Preserve all fields separately; convert row to absolute coordinates, do not recompute aspect ratio or geometry |
| Virtual/relative placements | Render list provides resolved locations and `KITTY_KIND` | No second Unicode-placeholder or parent-chain resolver |
| Layers | Below-background / below-text / above-text, plus signed z | Sort by layer and z; preserve iterator order for ties |
| Anonymous placement order | No public unique token/insertion-order field | Do not invent a protocol chronology guarantee for equal-z anonymous placements |
| Compression | VT returns fully inflated/decompressed pixels | Fixed zlib wire fixture; no host inflater |
| PNG | Process-global `ghostty_sys_set(DECODE_PNG)` | Startup-only ImageIO/vImage callback; exact supplied-allocator ownership, top-first straight RGBA8, bounded static PNG |
| Animation | `ghostty_kitty_graphics_animation_tick`, current-frame generation, next deadline | One tick under the driver lock per actual presentation; one weak, cancelable host wake for VT's next deadline |
| Other protocols | Public render image protocol enum currently exposes Kitty only | No Sixel/iTerm2 fallback parser or parity claim |

A missing/incomplete image is not negative-cached: chunk completion may make pixels available without changing that image generation. Images outside the captured viewport/overscan leave the adapter cache; their authoritative storage remains in VT.

## Boundaries and security

- VT storage retains its **10,000,000-byte default** per screen; adapter RGBA copies are capped at **16 MiB**, image dimensions at **8192×8192**, and capture visits at **1024 placements**. Tests may lower only the owned-snapshot budget, not the production default. `limited` records dropped/unsupported/degenerate data; it does not turn a missing image into successful presentation.
- APC input buffers are capped at **16 MiB**. VT owns transmission chunking, validation, decompression, storage eviction and protocol replies.
- File, temporary-file and shared-memory transports are explicitly disabled and their effective settings are checked. Tests use only an owned private sentinel; file/temp commands cannot read or unlink it. No local filesystem interpretation of a remote image path is allowed.
- `GhosttyVTSystem.prepare()` installs the PNG callback once before NSApplication/tests/transport work, with the same once-only guard in the driver factory. Concurrent factories wait for that initialization, never replace a callback during parsing. The callback is stateless, uses ImageIO/vImage without AppKit or main-actor dispatch, and retains no borrowed C pointer.
- PNG encoded input and expanded output are each capped at **16 MiB**, each dimension at **8192**; output allocation uses `ghostty_alloc` with the allocator supplied by VT before pixel decode. Failure frees the exact allocation; success transfers that exact buffer to VT. ImageIO/vImage's internal buffers are **not** charged to this allocator: these are input/extent/output limits, not a whole-process peak-RSS guarantee. VT's own transport/storage limits may reject data earlier; this is not a protocol-capacity promise.
- The callback accepts only static PNG, requires its signature/canonical final IEND and a real complete pixel provider, normalizes into sRGB straight RGBA8 using vImage without a premultiply/unpremultiply round trip, and rejects recognized multi-frame PNG/APNG rather than pretending to animate it. ImageIO remains the pixel decoder; no host Kitty chunk parser, storage or placement resolver is added. This is not exhaustive PNG-validation or color-profile certification.
- Capturing occurs under the existing VT lock, before render-state dirty data is consumed. Parsing/replies/credit still do not wait for user consent or drawing. Synchronized-output hold retains the old owned image frame while parsing and acknowledgements continue.
- The default scrollback byte budget remains **8 MiB**. Image work did not reduce it or change Herdr identity, reconnect, detach or input replay behavior.

## Known virtual-slice limitation

The original fixed wire vector sends a **1×1** red image with a **4×4-cell virtual placement**, then prints its first placeholder (`U+10EEEE`, row=0/col=0 marks). The frozen VT returns a placement with a **0×0 source rectangle**, despite the image being stored and the placement having a destination. The adapter rejects that degenerate source extent and sets `limited`; it does not reconstruct crop bounds from placeholder text.

An independent C client, without `GhosttyVTDriver`, SwiftTerm or any GUI, reproduces the zero source extent. A **4×4 source image** control yields a valid **1×1 source crop** for the first cell. Cursor movement, overscan, an earlier capture, scrolling and dirty consumption controls do not resolve the 1×1 case. This is a pinned-ABI limitation/ambiguity, **not a fixed compatibility case**. A later renderer step must resolve this deliberately with a documented compatibility policy or a verified precompiled upstream fix; it must not silently clamp rectangles and claim parity.

Run the diagnostic (compiles only a tiny C client; never the core):

```sh
sh Experiments/NativeTerminalLab/Tools/probe-vt-image-api.sh
```

Exit success means its positive API controls passed. The printed `KNOWN LIMITATION` remains a limitation, not a passing image-compatibility result.

## PNG boundary findings and pinned replacement behavior

`NativePNGDecoderTests.swift` adds 11 cases using 10 independent Python-stdlib vectors: RGB/RGBA, 1-bit and 8/16-bit grayscale, gray-alpha, indexed palette/tRNS, RGB tRNS, 16-bit RGBA and Adam7. Expected samples are not generated by ImageIO. Low alpha=1 and hidden RGB at alpha=0 remain exact for the tested ordinary 8-bit inputs. Tests cover the supplied allocator/refusal/free-on-failure, malformed/truncated data, nil/negative arguments, encoded/expanded/dimension limits, explicit APNG refusal, chunk completion/generations, background parsing and concurrent idempotent setup.

Two independently reproduced boundary issues were fixed without changing wire fixtures or adding waits:

- ImageIO can report complete source/image status, while its pixel provider is nil and vImage returns success with black pixels. It also accepts a PNG missing IEND. `Tools/probe-png-host.swift` demonstrates the framework behavior without VT/the adapter. The host now requires real provider bytes, safe stride length and final IEND before publishing success; malformed pixels free the already reserved VT allocation.
- A newly created VT has zero physical cell dimensions despite the driver's size callback reporting 8×16. PNG was accepted but the image iterator had no placement until resize, without any retransmission. Driver initialization now supplies those same 8×16 default metrics before pre-layout input; tests verify resulting pixel geometry rather than only OK replies.

The standalone C probe also confirms that pinned VT **retires an existing same-ID image when a replacement transmission starts**, even if the new image is incomplete or later rejected. This occurs with raw RGB/RGBA too, without the PNG callback. Tests initially assumed atomic retention; the independent C evidence disproved that premise. The same original inputs now explicitly record the retirement policy; this is not a production atomic-replacement fix or compatibility claim. The adapter does not retain a stale displayed texture to contradict VT. Old owned snapshots remain valid.

A private Herdr-shell test sends literal `f=100` data, observes actual owned pixels, drains output beyond initial credit, verifies binding identity and deletes the image. It never operates the user's existing Yazi session. The earlier user screenshot confirms Yazi PNG-file preview through its own RGB/RGBA conversion; it does **not** certify this new direct-PNG transport path.

```sh
python3 Experiments/NativeTerminalLab/Tools/generate-png-vectors.py
xcrun swift Experiments/NativeTerminalLab/Tools/probe-png-host.swift
```

## VT-owned animation scheduling

`GhosttyVTDriver.presentation` ticks the active screen once before render-state update/capture, under the same lock as parsing and content-anchor resolution. VT alone selects/assembles frames, loops and deadlines. A per-terminal UInt64 monotonic millisecond epoch is retained across reset; regressing host/test clocks are clamped. `snapshot`, link-hover decoration and transport parsing do **not** tick. A late call advances at most one VT frame, not a host catch-up loop. `NO_VALUE` removes the deadline; a nonfuture success deadline is an explicit error, not an invented polling/FPS delay.

`NativeTerminalScrollView` arms at most one weak MainActor task for that deadline. Cancellation plus a fresh token invalidates already queued old wakes. The task unwraps the view only after sleep; looped playback does not retain the view/driver. Hide/occlusion/minimize/detach/app-hide/display-sleep and close cancel scheduling. A visible return prepares one new frame and uses VT's new deadline; it does not replay frames/input or steal focus. Synchronized-output hold cancels animation scheduling and publishes/ticks nothing until release/its existing bounded timeout. Canceling a hidden hold preserves a pending refresh, including fixtures without images. Parsing, replies and Herdr credit remain independent.

The scheduler requires an image intersection with the **actual native clip**, not just overscan. The small additive `SwiftTerm+ImageGeometryVisibility.patch` exports the existing resolved rectangle helper, with its cell-bottom origin contract; hosts do not re-resolve placements. Fraction-only clip travel can suspend/resume a wake without capturing rows. The new 1-physical-pixel regression caught a one-cell origin error in the visibility caller; the caller was fixed without changing VT geometry or rendering fixtures. VT's deadline is storage-wide: if a static image is visible and only another offscreen image is animated, the public API does not identify which image owns the deadline. Per-image energy optimization/full power acceptance is not claimed.

Animation test vectors/lifetime policies adapt SwiftTerm `KittyGraphicsParityTests`, `KittyGraphicsHardeningTests` and `KittyRendererTests` at the pinned revision; no SwiftTerm emulator/animation state machine/timer is instantiated. The independent C probe asserts the same finite red/green/blue deadlines and pixels before any adapter/renderer. Eight driver cases cover timing/generations, late/clock-regression behavior, diagnostic non-ticking, hold, stop/delete/screens/reset, PNG animation frames and zero-gap/no-poll behavior. Ten view cases cover visibility, sleep, hidden fixtures, hold/reset/pending refresh, history, true fractional clipping, lifetime after an autorelease-pool boundary, background parse/credit and a real deadline without new output. Two actual CG/Metal pixel tests retain old owned frames and verify unchanged text-row conversions and bounded caches. A private Herdr shell observes an animated green frame, then proves hidden output exceeds initial credit without changing its binding or leaving a timer armed.

XCTest's application is actually hidden. These synthetic view tests inject only the host application's visibility and use owned test windows with modeled occlusion; they do not activate windows, change production visibility policy or certify device behavior. The initial absence of ticks in that environment was correct gating, not repaired by unhiding the application. Menu **Animation fixture** supplies a visible 500-ms red/green/blue loop only in fixture mode. Current user PNG confirmation is recorded separately; animation still needs fresh manual acceptance.

## Automated evidence

`NativeImageSnapshotTests.swift` has 15 cases: runtime RGB/RGBA and straight alpha, crop/offset metadata, geometry-only resize without pixel recopy, same-size replacement generations and retained old frames, chunk completion, VT zlib decoding, delete/reset/alternate-screen isolation, history capture, all three layers, valid virtual and relative placements, explicit budget limits, disabled file/temp/shared transports, startup PNG acceptance and the degenerate virtual-slice policy. All expected pixel values/wire vectors are independent of the tested getters.

Latest FlowDeck run: **234 lab tests passed / 0 skipped** (including 15 snapshot, 23 presentation, 11 PNG-decoder, 8 animation-driver, 10 animation-view cases and private PNG/animation stream tests), **362 production tests passed / 1 system-capability skip**. The skip is the unavailable private effective-corner-radius getter; saved My Mac / Santty defaults are unchanged.

`NativeImageRenderingTests.swift` adds **23 presentation tests**: actual CG/Metal pixels, non-grid-aligned destination size/offset, orientation, horizontal/vertical source crops and bleed prevention, basic alpha, all three layers, image-only generation replacement, deletion/reset/screen/history cache eviction, negative-origin clipping, valid virtual slices, explicit degenerate rejection, full-bitmap cache sharing, 1×/2× geometry vectors, native fractional-scroll bounds/focus and clearing old pictures before a held reconnect restore, actual PNG quadrant/orientation/low-zero-alpha pixels, and VT animation generation changes in both renderers.

The presentation round found crop-edge interpolation leaking adjacent pixels. CG now crops the provider-backed image before interpolation; a dedicated Metal image fragment clamps sampling to the original crop's pixel centers (not the viewport-clipped UV range). No nearest-neighbor timing/quality workaround or extra cropped GPU texture was introduced. Both shader forms stay synchronized. Tests explicitly set ANSI palette colors rather than assuming the engine theme uses saturated primaries. The valid virtual control uses a source matched to the physical grid; the original degenerate case remains separately rejected, not silently replaced.

These tests do not certify peak VRAM/energy, all interpolation/downsampling cases, exact cross-backend colorimetry, iOS certification, exhaustive PNG validation/color profiles, full animation/protocol parity, GUI/device/real-network acceptance or full protocol coverage.

## Renderer boundary and remaining gates

- `Patches/SwiftTerm+ResolvedImagePresentation.patch` adds optional `resolvedSize`; nil preserves the original SwiftTerm grid-size behavior. A shared CG/Metal rectangle function converts protocol pixels to points, applies offsets right/down from the cell top and handles signed/offscreen origins. Actual pixel intersection, not just grid-row membership, controls clipping.
- Every submitted placement is already resolved by VT, including virtual/relative ones; it is not sent to SwiftTerm's virtual resolver again. The VT row's placeholder flag plus the reserved scalar suppress placeholder text/ID colors/decorations while preserving cell backgrounds. No image ID, diacritic or parent-chain decoder was added.
- CG retains one full bitmap per live image generation and crops CGImage views for drawing, rather than retaining a near-full bitmap per placement. Metal retains one full image texture and clamps its source UV in the image-only shader. Source changes/delete/history/screen changes prune stale entries; tests check cache counts, not peak-memory certification.
- Reset clears the source and hides the old renderer presentation before a held reconnect restore can tick, without asking an occluded drawable to render. A later frame sees empty data, not the old images.
- The experimental app menu's **Image fixture** provides a raw RGBA quadrant image, right-column crop and direct `f=100` PNG quadrant image; the action is disabled/guarded during a private live session. It never injects fixture bytes into Herdr. Restart the old running lab to use the rebuilt menu; no GUI validation is claimed automatically.
- Still required: GIF/APNG handling if desired, animation GUI/device/power acceptance, deliberate resolution of the zero-source-crop ambiguity, real consumers/network/device acceptance, and remaining protocol/visual audit. File/temp/shared-memory transports remain disabled.
