# Agent Liveness Investigation

This note records the current investigation into how Santty should detect
whether an agent process is still alive. It is intentionally separate from the
agent event transport. As of this writing, Santty receives agent hook events over
a Unix domain socket, but liveness is still unresolved.

## Current Santty Model

Santty tracks agent sessions from hook events:

- `SessionStart` -> session started
- `UserPromptSubmit` -> turn started
- `Stop` -> turn completed
- `PermissionRequest` -> user notification
- `Notification` / `PermissionDenied` -> Claude-specific notifications
- `SessionEnd` -> session ended for Claude Code only

The hook payload is parsed by `AgentEventParser`, delivered by
`AgentEventMonitor`, and stored in `AgentSessionStore`.

This is a semantic event model, not a process model. It works well for turn
state, unread badges, and the Agent Manager UI, but it does not reliably answer:

- Is there still a `codex` or `claude` process running in this pane?
- Did a session end when no `SessionEnd` hook was emitted?
- Is a terminal busy because an agent is running, or because another command is
  running?

Codex does not emit `SessionEnd`, so liveness still needs a separate
mechanism.

## Codux Approach

Reference repo: `~/tmp/codux`.

Relevant files:

- `Sources/DmuxWorkspace/App/AISessionStore.swift`
- `Sources/DmuxWorkspace/Services/TerminalProcessInspector.swift`
- `Sources/DmuxWorkspace/Terminal/GhosttyBridge/GhosttyPTYProcessBridge.swift`

Codux has two layers:

1. Event-driven AI session state.
2. Process inspection as a supplemental liveness and active-tool signal.

`AISessionStore` owns the AI session state. It tracks terminal sessions with
states such as:

- `idle`
- `responding`
- `needsInput`

It handles runtime/hook events such as:

- session started
- prompt submitted
- needs input
- turn completed
- session ended

Codux retains some completed sessions after end. Its `clearCompleted` behavior
does not delete completed sessions; it clears the completed marker. This matches
the direction Santty already moved toward: a completed turn is not necessarily a
dead session.

`TerminalProcessInspector` uses:

```sh
/bin/ps -ewwaxo pid=,ppid=,pgid=,command=
```

It builds a process snapshot and supports:

- `activeTool(forShellPID:)`
- `hasActiveCommand(forShellPID:)`
- `managedSessionObservation()`
- `orphanedManagedAIProcessGroups(activeSessionInstanceIDs:)`

Tool detection is command-string based and covers names such as:

- `claude-code`
- `claude`
- `codex`
- `opencode`
- `gemini`

Codux also injects stable environment markers into managed processes:

- `DMUX_SESSION_INSTANCE_ID`
- `DMUX_SESSION_ID`
- `DMUX_PROJECT_PATH`
- `DMUX_RUNTIME_SOCKET`
- `DMUX_ACTIVE_AI_TOOL`
- `TERM_PROGRAM=dmux`

The important architectural difference is that Codux owns the PTY process. Its
`GhosttyPTYProcessBridge` uses `forkpty`, stores the shell PID, and can walk the
process tree under that shell PID. That makes active-tool detection much more
precise than a global process scan.

Implication for Santty:

- Codux's shell-PID-rooted process tree scan is the best model.
- Santty cannot directly copy it unless Santty can obtain each Ghostty surface's
  shell PID or foreground process group.
- Without shell PID, Santty can only do weaker global scanning based on
  environment markers.

## Muxy Approach

Reference repo: `~/tmp/muxy`.

Relevant files:

- `scripts/setup.sh`
- `Muxy/Views/Terminal/GhosttyTerminalNSView.swift`
- `Muxy/Services/TerminalCommandTracker.swift`
- `Muxy/Services/TerminalCommandTrackingInputGate.swift`
- `Muxy/Services/NotificationSocketServer.swift`
- `Muxy/Views/Terminal/TerminalEnvVarBuilder.swift`
- `Muxy/Services/Providers/CodexProvider.swift`
- `Muxy/Services/Providers/ClaudeCodeProvider.swift`

Muxy does not have a full Agent Session Store like Santty or Codux. Its hooks are
mainly notification-oriented:

- Claude and Codex install `Stop` and `Notification` hooks.
- Hooks send `type|paneID|title|body` over a Unix domain socket.
- Pane ownership comes from `MUXY_PANE_ID`.

Muxy injects per-pane environment:

- `MUXY_PANE_ID`
- `MUXY_PROJECT_ID`
- `MUXY_WORKTREE_ID`
- `MUXY_SOCKET_PATH`
- `MUXY_HOOK_SCRIPT`

For process state, Muxy calls a Ghostty API:

```swift
ghostty_surface_foreground_pid(surface)
```

It then uses `proc_name(pid)` to get the foreground process name. This is used
for input tracking, not as a full AI session model. The input tracker records
typed shell commands only when the foreground process is a shell-like process and
the terminal is not in the alternate screen.

Important detail: Muxy does not download GhosttyKit from `Lakr233/libghostty-spm`.
`scripts/setup.sh` uses:

```sh
FORK_REPO="muxy-app/ghostty"
```

It downloads the latest release assets:

- `GhosttyKit.xcframework.tar.gz`
- `GhosttyKit-resources.tar.gz`

from the `muxy-app/ghostty` fork. The fork carries additional libghostty exports
used by Muxy. The docs mention:

- `ghostty_surface_set_data_callback`
- `ghostty_surface_send_input_raw`

The source also calls `ghostty_surface_foreground_pid`, so that export appears
to come from the fork as well, even though the local docs do not list it.

Implication for Santty:

- Muxy's foreground PID path is better than global `ps` scanning.
- Santty cannot use this path with the current dependency.
- To use this path, Santty needs a GhosttyKit build that exports
  `ghostty_surface_foreground_pid`, likely by adopting a fork or adding the
  export to Santty's dependency chain.

## libghostty-spm Investigation

Santty currently depends on `Lakr233/libghostty-spm`, pinned in
`.package.resolved`.

The current checked dependency does not expose:

```c
ghostty_surface_foreground_pid
```

This was verified in the local SwiftPM artifact:

- `ghostty.h` has no declaration.
- `libghostty.a` has no `_ghostty_surface_foreground_pid` symbol.

The latest online `libghostty-spm` releases were also checked:

- `storage.1.1.4/GhosttyKit.xcframework.zip`
- `storage.1.1.5/GhosttyKit.xcframework.zip`

Both were downloaded and inspected. Neither header nor binary exports
`ghostty_surface_foreground_pid`.

`1.1.5` changed packaging from a plain static library slice to a framework slice:

- old style: `macos-arm64_x86_64/libghostty.a`
- new style: `macos-arm64_x86_64/libghostty.framework/libghostty`

but the foreground PID symbol is still absent.

Conclusion:

- Upgrading to current `Lakr233/libghostty-spm` does not solve liveness.
- Hand-declaring the function in Swift/C will not work because the binary does
  not contain the symbol.
- Santty needs a different GhosttyKit build if we want this API.

## Available Strategies

### Strategy A: Hook Events Only

Use only `UserPromptSubmit`, `Stop`, `Notification`, and `SessionEnd`.

Pros:

- Already implemented.
- Best semantic signal for turn state.
- No process scanning.

Cons:

- Cannot reliably know process liveness.
- Codex `SessionEnd` is not dependable.
- A session can remain visible as completed even after the process exits.

Use this as the base model, not as the final liveness solution.

### Strategy B: Global Process Scan With Santty Env Markers

Inject stable environment markers into each terminal and scan the process table.
Santty already injects:

- `SANTTY_PANE_ID`
- `SANTTY_RUNTIME_OWNER`
- `SANTTY_AGENT_SOCKET`

A future inspector could run:

```sh
/bin/ps -ewwaxo pid=,ppid=,pgid=,command=
```

Then parse command strings for:

- `SANTTY_PANE_ID=<pane-id>`
- `codex`
- `claude`
- maybe `SANTTY_RUNTIME_OWNER=<bundle-id>`

This can answer a weaker question:

> Does any process associated with this pane look like a known agent?

It cannot reliably answer:

> Is this the current foreground process for the pane?

because without the surface shell PID or foreground process group, we cannot
root the scan to the active terminal foreground job.

Pros:

- Does not require rebuilding GhosttyKit.
- Can repair obvious stale sessions.
- Can be implemented as a small `SanttyProcessInspector`.

Cons:

- Less precise than shell-PID-rooted tree walking.
- Depends on environment values being visible in `ps -eww...` command output.
- Could detect background descendants that are not foreground.
- Needs periodic polling.

This is the best short-term liveness improvement.

### Strategy C: Foreground PID From Ghostty

Use a Ghostty API like:

```c
uint64_t ghostty_surface_foreground_pid(ghostty_surface_t);
```

Then use `proc_name(pid)` or `proc_pidpath` to identify the foreground process.

Pros:

- Most accurate for "what is this terminal currently running?"
- Avoids global process-table heuristics for the main detection path.
- Matches Muxy's implementation style.

Cons:

- Not available in Santty's current `libghostty-spm`.
- Not available in current public `libghostty-spm` 1.1.4 or 1.1.5 artifacts.
- Requires a forked or patched GhosttyKit build.

This is the best long-term solution if Santty is willing to own a GhosttyKit
patch or adopt a fork that carries the export.

### Strategy D: Own the PTY

Santty could eventually own the PTY process like Codux does with `forkpty`.

Pros:

- Gives Santty shell PID, PTY fd, process lifecycle, and process group control.
- Enables precise process tree inspection.

Cons:

- Large architectural change.
- Fights the current "thin native wrapper around Ghostty core" model.
- High blast radius.

This is not recommended for the current Agent Manager work.

## Recommended Path

Use a two-stage approach.

Stage 1: Short-term liveness repair with process scanning.

- Add `SanttyProcessInspector`.
- Use `/bin/ps -ewwaxo pid=,ppid=,pgid=,command=`.
- Parse `SANTTY_PANE_ID`.
- Detect known tools: `claude-code`, `claude`, `codex`.
- Return a map from pane ID to observed agent tools.
- Periodically reconcile `AgentSessionStore`:
  - If a session is `running` or `waitingForUser` and no matching process is
    observed for that pane for a grace period, mark it ended or stale.
  - Do not delete `turnCompleted` sessions just because no process is observed.
  - Keep hook events authoritative for turn state.

Stage 2: Replace or augment process scan with foreground PID when available.

- Track whether the active GhosttyKit exposes `ghostty_surface_foreground_pid`.
- If a future dependency exports it, add a thin wrapper on `GhosttySurfaceHost`
  or the terminal view to query foreground PID.
- Use foreground PID for active-tool detection.
- Keep global process scan only as a fallback or stale-session cleanup path.

## Suggested Store Semantics

Do not conflate `turnCompleted` with process ended.

Recommended display states:

- `running`: recent prompt submitted or observed active process.
- `waitingForUser`: notification hook received.
- `turnCompleted`: `Stop` received, agent may still accept more prompts.
- `sessionEnded`: explicit `SessionEnd` or liveness repair concluded process is
  gone after a grace period.

Recommended clear behavior:

- `Clear Ended` should remove read `sessionEnded` sessions.
- It should not remove `turnCompleted` sessions.
- If process liveness later marks a completed session as ended, then it becomes
  clearable after it is read.

## Open Questions

- Should liveness repair mark stale sessions as `sessionEnded`, or introduce a
  distinct `stale` display state?
- What grace period is acceptable before declaring a missing process ended?
  Suggested starting point: 3 consecutive scans over 10-15 seconds.
- Should Santty scan only while the Agent Manager button is visible, or always
  while agent integrations are enabled?
- Should `SANTTY_AGENT_INSTANCE_ID` be added, separate from `SANTTY_PANE_ID`, to
  distinguish restored/reused panes across terminal process lifetimes?
- Should Santty adopt a Ghostty fork to expose foreground PID, or wait for a
  public `libghostty-spm` export?
