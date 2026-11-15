# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Project Overview

Santty is a macOS terminal emulator written in Swift: original precompiled Ghostty VT owns terminal semantics; SwiftTerm supplies external-frame rendering and LocalProcess; AppKit NSScrollView owns a virtualized history viewport. There is no old surface backend or runtime fallback.

- **Language**: Swift 6.0 with strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete`)
- **Platform**: macOS 14.0+
- **Build system**: Tuist 4.156.0 (managed via mise)
- **IDE integration**: `buildServer.json` is configured for `xcode-build-server`

## Common Commands

### Tuist / Xcode Workflow

```bash
# Prepare pinned renderer and original VT archive before direct Tuist use
mise run terminal:prepare

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

### Terminal Regression Tests

`mise run tuist:generate` always includes `SanttyTerminalTests`; no experimental app, scheme or generation flag remains. Run `flowdeck test -s Santty --test-targets SanttyTests,SanttyTerminalTests --json` (override private DerivedData as needed, never change saved FlowDeck defaults). The terminal suite imports the production `Santty` module; private PTY/Herdr test sessions live only in `Santty/TerminalTests/Support/`. Probes/generators are in `Scripts/Terminal/`, bundled themes/licenses in `Santty/Resources/`, and contracts/history in `docs/terminal/`.

### Formatting

The project does not currently include a `.swift-format` configuration file, although `mise.toml` references one.

## High-Level Architecture

- **App/workspaces**: `AppDelegate` bootstraps AppKit and the VT system. `WorkspaceViewController` owns tiled, floating, sidebar and background workspace/tab controllers, persistence, CLI targeting and close scope checks.
- **Production adapter**: `TerminalPaneController` permanently binds a pane UUID to `NativeTerminalPaneSession` and a checked `NativeTerminalFrontend`. `TerminalPaneHostView` supplies padding, vibrancy and loading/error UI; the actual responder is the native renderer.
- **Native terminal** (`Santty/Sources/Terminal/Native/`): `GhosttyVTDriver` serializes all C calls. Parsing, replies and Herdr credit are independent of MainActor painting. `SwiftTermFrameSource` presents bounded owned cells/images, never SwiftTerm's emulator. `NativeTerminalScrollView` virtualizes history; tracked VT refs retain reading and Scroll Mode positions.
- **Ownership**: `NativeLocalPTYSession` owns a lazy SwiftTerm.LocalProcess, checked FIFO and finite stop/drain. `HerdrTerminalSession` retains permanent core identity and parse-completion credit. Temporary view detach only unbinds a frontend, never stops a session.
- **Text contracts**: CLI uses full retained logical history (32 MiB capture, separate response cap); AX reads only its immutable published physical page; Scroll Mode uses physical VT cells and tracked refs. None may substitute for another.

## Important Patterns

- **Appearance**: `main.swift` sets the application's dark appearance before creating UI. Windows, panes and popovers inherit it; do not add local appearance overrides. Resolve semantic `CGColor` values inside the view's `effectiveAppearance` drawing context and refresh them when that appearance changes.
- **Concurrency**: AppKit/session lifecycle is MainActor-bound. VT parsing/encoding/formatting and C pointer ownership are serialized under the driver lock; replies/parse credit must never wait on painting, AX or metadata delivery.
- **C Pointer Safety**: Borrowed C cells, strings and images never escape a locked capture. Only bounded owned data crosses into rendering/AX/read services; dispose tracked refs before their terminal.
- **Vendor Dependency**: `Scripts/prepare-native-terminal.sh` pins SwiftTerm `28c6d1d95de156a36a2eaa278177ee7f8a15d322` and original precompiled Ghostty VT 1.0.0 under ignored `Vendor/native-terminal`. Never rebuild the C core, link GhosttyKit/the old wrapper, instantiate SwiftTerm.Terminal or add a backend toggle. Preserve all eight reproducible SwiftTerm presentation/PTY patches. Run `mise run terminal:prepare` before direct generation or after patch edits; mise generation tasks do so automatically. Production history is **8 MiB**, never reduce below 6 MB or weaken the 6000-row wide-output copy regression. Preserve owned Local PID/TTY/cwd inspection; remote identities never enter local process/filesystem inspection.
- **Teardown**: `PaneCloseTransaction` preflights/fences all concrete owners, independently awaits all cleanup, then rechecks exact controller/container identity before synchronous removal. Native Local normalizes to terminate, external Herdr viewers to detach. Keep failures/cancellation visible and retain layout/owners; cleanup is not rollback. No main-thread process join or deinit-based layout removal.
- **Presentation/Wake**: Hidden/occluded/detached/sleeping views suppress painting and animation wakes, not parsing/replies/credit. Metrics synchronize before exec/attach independently of pixels. Old surface-free/display-link/mailbox/wake patches were retired with the old C backend; that is not a certification of new sleep/cross-screen/device energy behavior.
- **Window Corner Radius**: In hidden-window mode the corner radius is customized through private AppKit setters (`_setCornerRadius:` / `_setEffectiveCornerRadius:`) in `AppAppearanceDefaults.applyWindowPresentation`. A titled window's corners are always clipped by the WindowServer mask (~16pt on macOS 26), which no `CALayer` change can override. `_setCornerRadius:` treats 0 as "reset to system default", so a true zero also calls `_setEffectiveCornerRadius:`. All calls are guarded by `responds(to:)`; acceptable because the app ships via Developer ID, not the App Store.
- **Project Generation**: `.gitignore` excludes `*.xcodeproj`, `*.xcworkspace`, and `Derived/`. These are generated by Tuist and should never be committed.
- **Signing & Bundle Identity**: No private values in the repo. `Project.swift` reads `TUIST_SANTTY_DEVELOPMENT_TEAM` and `TUIST_SANTTY_BUNDLE_IDENTIFIER` from the environment (Tuist only forwards `TUIST_*` variables to manifests). The maintainer sets them in `mise.local.toml` (gitignored, auto-loaded by mise). Without them, builds fall back to adhoc signing and the placeholder bundle ID `dev.santty.local`. Release packaging (`mise run release:package`) exports with Developer ID via a generated `build/ExportOptions.plist`, notarizes with `asc notarization submit --wait`, and staples the ticket before zipping.

## CLI Control

- `list/read/search` remain read-only. `CLICommandRouter` owns separate default-off
  pane-control and terminal-input grants; never route mutations around it.
- Mutation retry IDs are launch-scoped and expire after ten minutes. Coalesce
  pending tasks and completed results; reject expired/conflicting IDs rather than
  replaying operations. Never evict a still-valid ID to make room in the journal.
- Resolve panes across workspaces and the sidebar by UUID. Non-focus operations
  must not select another workspace/tab or change first responder. Layout changes
  reject unsupported overlays/folded states instead of silently resetting them.
- Herdr close must complete before removing bindings. External viewers only detach.
  Input is never replayed on reconnect; `accepted` is not proof of remote delivery
  or command execution. Reply before closing the final main window.

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
  `Settings → Herdr` owns executable, attach-history and shared-workspace
  preferences. Shared workspaces (off by default) keep Herdr workspaces' tabs and
  splits in the core `herdr-app` document for the desktop app and phone: sync is an
  idempotent base/local/remote tab merge that publishes only differences with the
  document revision, adopts remote edits, reports conflicts instead of silently
  overriding, and never ends a program for a layout deletion. Publishing also owns
  `herdr.space`/`herdr.tab` (leave other labels alone), skips workspaces Santty
  cannot express exactly, and never re-creates a space deleted in the document.
  Validate and
  subscribe a replacement connection before swapping it; reconnect only Santty's
  viewers, never the core daemon. Keep observer bindings scoped to their core ID,
  and exclude connection commands, raw errors and environment values from copied diagnostics.
- v10 includes optional workspace kinds and Herdr bindings; absent kinds mean
  Local Workspace. Keep the terminal backend consistent with its owning workspace.
- The window sidebar starts with a local Herdr terminal and supports Terminal,
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
- Release procedure (version bump, archive, appcast generation, GitHub release) is documented in [README.md](README.md#publish-an-update-sparkle).
