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

There is no Makefile or script-based build. Build and test through Xcode or `xcodebuild`:

```bash
# Build via xcodebuild
xcodebuild -workspace Santty.xcworkspace -scheme Santty -destination 'platform=macOS' build

# Run tests via xcodebuild
xcodebuild -workspace Santty.xcworkspace -scheme Santty -destination 'platform=macOS' test
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

- **Concurrency**: Almost all terminal-facing code is `@MainActor`. The runtime bootstrap runs on `Task.detached` but results are delivered to the main actor. `runOnMainThread` uses `MainActor.assumeIsolated` when already on the main thread.
- **C Pointer Safety**: Ghostty objects are stored as `nonisolated(unsafe)` raw pointers. `deinit` schedules C cleanup on the main actor via `Task { @MainActor ... }`.
- **Vendor Dependency**: The Ghostty core comes from the upstream [`libghostty-spm`](https://github.com/Lakr233/libghostty-spm) Swift package (remote, `upToNextMajor(from: "1.3.1")` in `Project.swift`), which downloads a precompiled `GhosttyKit.xcframework` binary target. Do not attempt to build it from source; it is treated as an opaque dependency. Version 1.3.0+ exposes `TerminalView.foregroundPid` / `ttyName`, which Santty uses for agent liveness detection and split cwd inheritance — do not downgrade below that.
- **Window Corner Radius**: In hidden-window mode the corner radius is customized through private AppKit setters (`_setCornerRadius:` / `_setEffectiveCornerRadius:`) in `AppAppearanceDefaults.applyWindowPresentation`. A titled window's corners are always clipped by the WindowServer mask (~16pt on macOS 26), which no `CALayer` change can override. `_setCornerRadius:` treats 0 as "reset to system default", so a true zero also calls `_setEffectiveCornerRadius:`. All calls are guarded by `responds(to:)`; acceptable because the app ships via Developer ID, not the App Store.
- **Project Generation**: `.gitignore` excludes `*.xcodeproj`, `*.xcworkspace`, and `Derived/`. These are generated by Tuist and should never be committed.
- **Signing & Bundle Identity**: No private values in the repo. `Project.swift` reads `TUIST_SANTTY_DEVELOPMENT_TEAM` and `TUIST_SANTTY_BUNDLE_IDENTIFIER` from the environment (Tuist only forwards `TUIST_*` variables to manifests). The maintainer sets them in `mise.local.toml` (gitignored, auto-loaded by mise). Without them, builds fall back to adhoc signing and the placeholder bundle ID `dev.santty.local`. Release packaging (`mise run release:package`) exports with Developer ID via a generated `build/ExportOptions.plist`, notarizes with `asc notarization submit --wait`, and staples the ticket before zipping.

## Automatic Updates (Sparkle)

- **`Santty/Sources/Updates/AppUpdater.swift`**: `@MainActor` singleton wrapping Sparkle's `SPUStandardUpdaterController`. The Santty menu ("Check for Updates...") and the General settings pane both go through `AppUpdater.shared`.
- The appcast URL and EdDSA public key are injected at generate time via `TUIST_SANTTY_SPARKLE_FEED_URL` / `TUIST_SANTTY_SPARKLE_PUBLIC_KEY` (typically from `mise.local.toml`). When unset, the Info.plist carries no Sparkle keys and `AppUpdater.isAvailable` is false: the updater never starts and the update UI (menu item, General settings section) is hidden. Official builds point at `https://github.com/zolazhou/Santty/releases/latest/download/appcast.xml`, so every release must attach `appcast.xml` and the zipped app.
- The EdDSA private key lives in the developer's login keychain. Sparkle's `generate_keys` / `generate_appcast` tools are wrapped as the `sparkle:generate-keys` / `sparkle:generate-appcast` mise tasks; their binaries live under `~/Library/Developer/Xcode/DerivedData/Santty-*/SourcePackages/artifacts/sparkle/Sparkle/bin` after a build (exposed as `SPARKLE_BIN` via `mise.toml`).
- Release procedure (version bump, archive, appcast generation, GitHub release) is documented in `README.md` under "Publish an Update (Sparkle)".
