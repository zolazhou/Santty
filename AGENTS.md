# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Project Overview

Santty is a macOS terminal emulator written in Swift. It is a thin native AppKit wrapper around the Ghostty terminal core, which is provided as a precompiled C library (`GhosttyKit.xcframework`).

- **Language**: Swift 6.0 with strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete`)
- **Platform**: macOS 14.0+
- **Build system**: Tuist 4.156.0 (managed via mise)
- **IDE integration**: `buildServer.json` is configured for `xcode-build-server`

## Common Commands

### Tuist / Xcode Workflow

```bash
# Install Tuist dependencies
tuist install

# Generate the Xcode workspace (no-open)
tuist generate --no-open

# Regenerate after manifest changes
tuist install && tuist generate --no-open

# Clean generated artifacts
tuist clean
```

### Building and Testing

Use FlowDeck for agent build, run and test tasks on the saved Mac target:

```bash
flowdeck config get --json
flowdeck build
flowdeck test
```

### Formatting

The project does not currently include a `.swift-format` configuration file, although `mise.toml` references one.

## High-Level Architecture

The codebase is organized into three layers that bridge AppKit to the Ghostty C library:

### 1. App Layer (`Santty/Sources/App/`)

- **`main.swift`**: Manual `NSApplication` bootstrap with `AppDelegate`.
- **`AppDelegate`**: `@MainActor` delegate that creates `MainWindowController`, kicks off async `GhosttyRuntime` initialization, and installs a minimal main menu.
- **`MainWindowController`**: `NSWindowController` that owns a `TerminalViewController`. Bridges window lifecycle events (focus, occlusion, screen changes) to the terminal surface.
- **`TerminalViewController`**: `NSViewController` that swaps between a loading/error SwiftUI view and the live `GhosttyTerminalView`. It receives the `GhosttyRuntime` asynchronously after initialization completes.

### 2. Terminal Layer (`Santty/Sources/Terminal/`)

- **`GhosttyTerminalView`**: `NSView` subclass conforming to `NSTextInputClient`. This is the primary rendering surface. It handles:
  - Keyboard input (including IME/preedit, key equivalents, and modifier translation)
  - Mouse input (position, buttons, scroll)
  - Clipboard (copy/paste)
  - Cursor shape/visibility updates from Ghostty
  - Calls into `GhosttySurfaceHost` to forward events to the C library
- **`GhosttyInput`**: Pure helper that translates `NSEvent` modifier flags and key events into Ghostty C structs (`ghostty_input_key_s`, `ghostty_input_mods_e`, etc.).

### 3. Ghostty C Interop Layer (`Santty/Sources/Ghostty/`)

- **`GhosttyRuntime`**: `@MainActor` singleton that wraps the Ghostty app lifecycle (`ghostty_app_t`).
  - Bootstraps the C runtime on a detached task (`Task.detached`) and caches the result.
  - Stores raw C pointers (`ghostty_app_t`, `ghostty_config_t`) as `nonisolated(unsafe)`.
  - Exposes `requestTick()`, `setAppFocused()`, `applyColorScheme()`, and app-level action handling.
- **`GhosttySurfaceHost`**: Per-surface bridge (`ghostty_surface_t`) created for each `GhosttyTerminalView`.
  - Owns the C surface pointer and translates view geometry, focus, and color scheme to the C API.
  - Handles clipboard read/write confirmation dialogs and close confirmation dialogs.
  - Most methods assert `Thread.isMainThread`.
- **`GhosttyCallbacks`**: Free-function C callbacks registered with Ghostty. They trampoline back to Swift via raw pointer unwrapping (`unwrapRuntime`, `unwrapSurfaceHost`) and always dispatch to the main thread with `runOnMainThread`.

## Important Patterns

- **Appearance**: `main.swift` sets the application's dark appearance before creating UI. Windows, panes and popovers inherit it; do not add local appearance overrides. Resolve semantic `CGColor` values inside the view's `effectiveAppearance` drawing context and refresh them when that appearance changes.
- **Concurrency**: Almost all terminal-facing code is `@MainActor`. The runtime bootstrap runs on `Task.detached` but results are delivered to the main actor. `runOnMainThread` uses `MainActor.assumeIsolated` when already on the main thread.
- **C Pointer Safety**: Ghostty objects are stored as `nonisolated(unsafe)` raw pointers. `deinit` schedules C cleanup on the main actor via `Task { @MainActor ... }`.
- **Vendor Dependency**: `Scripts/prepare-ghostty.sh` downloads and verifies upstream [`libghostty-spm`](https://github.com/Lakr233/libghostty-spm) 2.2.2026102101 at a pinned revision into ignored `Vendor/libghostty-spm` (requires Swift 6.2 / Xcode 26+). `Project.swift` uses this local package. The precompiled core is Ghostty `1e9e14af5df1`, including 1.4 memory optimizations but predating final 1.4.0. Keep using the original precompiled `GhosttyKit.xcframework`: do not build the C core from source. `Patches/` adds read-only snapshots and scroll selection, and keeps detached live panes draining callbacks. `TerminalPaneHostView` reports attachment through `setSurfaceVisible`; the package separately handles window occlusion. Run `mise run ghostty:prepare` before direct Tuist generation or after editing patches; mise generation tasks do this automatically. Move the old vendor directory aside when changing the pin. Preserve `TerminalView.foregroundPid` / `ttyName` for local process inspection and cwd inheritance.
- **Window Corner Radius**: In hidden-window mode the corner radius is customized through private AppKit setters (`_setCornerRadius:` / `_setEffectiveCornerRadius:`) in `AppAppearanceDefaults.applyWindowPresentation`. A titled window's corners are always clipped by the WindowServer mask (~16pt on macOS 26), which no `CALayer` change can override. `_setCornerRadius:` treats 0 as "reset to system default", so a true zero also calls `_setEffectiveCornerRadius:`. All calls are guarded by `responds(to:)`; acceptable because the app ships via Developer ID, not the App Store.
- **Project Generation**: `.gitignore` excludes `*.xcodeproj`, `*.xcworkspace`, and `Derived/`. These are generated by Tuist and should never be committed.
- **Signing & Bundle Identity**: No private values in the repo. `Project.swift` reads `TUIST_SANTTY_DEVELOPMENT_TEAM` and `TUIST_SANTTY_BUNDLE_IDENTIFIER` from the environment (Tuist only forwards `TUIST_*` variables to manifests). The maintainer sets them in `mise.local.toml` (gitignored, auto-loaded by mise). Without them, builds fall back to adhoc signing and the placeholder bundle ID `dev.santty.local`. Release packaging (`mise run release:package`) exports with Developer ID via a generated `build/ExportOptions.plist`, notarizes with `asc notarization submit --wait`, and staples the ticket before zipping.

## Workspace Persistence

- Workspace identity is a local UUID. The picker and sidebar derive their
  entries from the current Local and Herdr workspaces; connection availability metadata
  and duplicate directory snapshots are not stored.
- `SavedWorkspace` reads and writes v10 only; development snapshots are not migrated.
  Preserve atomic saves, private file permissions,
  the writer lock and refusal to overwrite unreadable or unsupported files.
- Herdr integration lives in `Santty/Sources/Herdr/`: one `hc connect`
  transport multiplexes terminal streams and events; stream credit follows Ghostty
  parsing, not output enqueue. The GUI owns layout. Bindings include the permanent
  core ID and local terminal address; never substitute a new terminal after an
  identity change or blindly replay an ambiguous run. `santty-pane` labels reconcile
  creations. Window close detaches viewers; explicit pane/tab/workspace close kills
  terminals before removing their saved bindings. Remote workspaces select an
  existing `hc machine` profile and route through the local core proxy using the
  permanent remote core ID. Machine setup/login/update remains in hc. Persist a
  pending run before sending it; retries reconcile its label without blindly
  creating a shell. Remote reconnects reset the screen and Scroll Mode; input is
  never replayed. Remote cwd, paths and PIDs must not use local filesystem or
  process inspection, and remote shells must not receive the local control socket.
  Closing a workspace never removes the shared machine profile. External agent
  viewers persist `herdrViewer`; their explicit close only detaches and never
  kills the shared terminal. Such viewers must always have a binding and cannot
  create or reconcile a new program.
  `Settings → Herdr` owns executable and attach-history preferences. Validate and
  subscribe a replacement connection before swapping it; reconnect only Santty's
  viewers, never the core daemon. Keep observer bindings scoped to their core ID,
  and exclude connection commands, raw errors and environment values from copied diagnostics.
- v10 includes optional workspace kinds and Herdr bindings; absent kinds mean
  Local Workspace. Keep the terminal backend consistent with its owning workspace.
- The window sidebar starts with a local terminal and supports Terminal,
  Workspaces, Browser and Agents panes. Keep
  its state and focus independent of the selected main workspace.

## Agents

- `Santty/Sources/Agents/` receives root and child OSC 7501 records through the
  existing herdr-core event subscription. Keep metadata monitoring active across
  workspace switches without attaching a terminal or sending focus/resize/input.
- Snapshot/reconnect/missed data establishes baselines. Only explicit `done`
  reports produce completion messages; `turn` also changes on interruption,
  blocked, clear and exit. Preserve unknown apps/states, unavailable entries,
  identity isolation, deduplication, and revision-checked read acknowledgements.
- Agents/Messages and notification clicks share safe core-bound navigation.
  Agents panes work in the sidebar and main layout, share the same store, and
  persist as `agents` panes. Metadata refreshes must never change first responder.
  Each row opens its messages in a popover, filtered by the exact record ID;
  keep root/child histories separate and preserve the trigger view across updates.
  Existing panes retain layout; externally created terminals use viewer-only
  panes. All Herdr agent types notify without per-agent preferences; request macOS
  authorization before the first delivery. System permission does not affect tracking or local messages.
  Do not install hooks or infer agent status from PID, process names or screen text.

## Automatic Updates (Sparkle)

- **`Santty/Sources/Updates/AppUpdater.swift`**: `@MainActor` singleton wrapping Sparkle's `SPUStandardUpdaterController`. The Santty menu ("Check for Updates...") and the General settings pane both go through `AppUpdater.shared`.
- The appcast URL and EdDSA public key are injected at generate time via `TUIST_SANTTY_SPARKLE_FEED_URL` / `TUIST_SANTTY_SPARKLE_PUBLIC_KEY` (typically from `mise.local.toml`). When unset, the Info.plist carries no Sparkle keys and `AppUpdater.isAvailable` is false: the updater never starts and the update UI (menu item, General settings section) is hidden. Official builds point at `https://github.com/zolazhou/Santty/releases/latest/download/appcast.xml`, so every release must attach `appcast.xml` and the zipped app.
- The EdDSA private key lives in the developer's login keychain. Sparkle's `generate_keys` / `generate_appcast` tools are wrapped as the `sparkle:generate-keys` / `sparkle:generate-appcast` mise tasks; their binaries live under `~/Library/Developer/Xcode/DerivedData/Santty-*/SourcePackages/artifacts/sparkle/Sparkle/bin` after a build (exposed as `SPARKLE_BIN` via `mise.toml`).
- Release procedure (version bump, archive, appcast generation, GitHub release) is documented in `README.md` under "Publish an Update (Sparkle)".
