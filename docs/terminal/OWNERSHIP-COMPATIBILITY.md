# Reusable local ownership and launch/close policy (isolated 5B)

> **Current integration:** the shared implementation now lives in `Santty/Sources/Terminal/Native/` and is exercised by the formal `SanttyTerminalTests` suite against the production application module. See the [atomic cutover record](../../docs/plans/terminal-native-cutover.md) for current evidence and open manual gates. Scope/backend statements and counts below retain the original **pre-cutover milestone record**, not current production status.

## One concrete session, not a second backend

`NativeLocalPTYSession` owns one pane UUID and one guarded standalone
`SwiftTerm.LocalProcess` launch. It retains the existing private lifecycle queue,
direct serial parse-worker delivery, finite output fence, slave keeper, bounded
checked FIFO, automatic replies, VT driver and revision-checked state observer.
The runner bridge is moved from `NativeLocalPTYLab`, not duplicated. The original
precompiled Ghostty VT archive and all eight SwiftTerm patches are unchanged.

The session creates/removes **no HOME, XDG, cwd or user files**. View attachment,
painting, focus and workspace selection do not own its lifetime. The private
`NativeLocalPTYLab` is now only a directory/environment fixture around this same
session: its menu still launches `/bin/sh -i` in private 0700 HOME/XDG/tmp, with
the existing PATH/locale allowlist. Only that wrapper deletes its own root,
off-main, after verified session close. Production never borrows the private
lab's shell/environment or directory cleanup policy.

Explicit close must be awaited. Unexpected session release starts best-effort
asynchronous close of its bridge; it never joins a child from deinit. That is a
safety net, not permission for future workspace removal to rely on destruction.
There is no reconnect, relaunch, replacement PID or old-input replay path.

## Explicit LOCAL production launch policy

`NativeLocalPTYLaunch` validates immutable argv, environment and cwd before
reset/fork. Paths must be absolute; NUL, empty argv0 and empty/`=` environment
keys are refused. Launch pane UUID must match its session **before reset**.
Missing executables/bad existing paths are not silently replaced: the existing
checked runner/start and child exec/chdir 127 semantics still apply.

`productionLocal(paneID:controlSocket:context:workingDirectory:appVersion:)`:

- Reads an explicitly supplied account context. `NativeLocalPTYUserContext.current()`
  can capture current account shell/home with bounded `getpwuid_r`, owned strings,
  ProcessInfo environment and Foundation locale. It does not spawn, read shell
  profiles, setenv or substitute `/bin/sh`/inherited `$SHELL` on lookup failure.
- Executes the account shell as a login, interactive shell: `argv[0] = -basename`,
  arguments `[-i]`. No shell command string, `login` helper or user profile is
  interpreted by the host. The selected shell itself owns its normal startup.
- Uses account HOME and requested cwd (otherwise account home), explicit SHELL/PWD,
  and preserves the user's remaining environment: PATH, XDG/ZDOTDIR, authentication
  agents, credentials and startup hooks are **not** subjected to the lab allowlist.
  This deliberate production policy must never be used to run a private test.
- Replaces pane ID/control socket with explicit current local values, terminal
  program/version, `TERM=xterm-256color` and truecolor. Parent COLUMNS/LINES and
  obsolete GHOSTTY_RESOURCES_DIR/GHOSTTY_BIN_DIR are removed. Empty PATH receives
  `/usr/bin:/bin:/usr/sbin:/sbin`; winsize carries actual cells/pixels before exec.
- Preserves nonempty LANG (and other locale values); otherwise returns child-only
  Cocoa/POSIX locale exports using the pinned wrapper's pure conversion tables.
  Missing language/region falls back to `en_US.UTF-8`. No process-global locale
  mutation or libintl dependency is added. Attribution and full MIT permission:
  `Licenses/Launch-Adaptation-NOTICE.txt`.

This policy is **local-only**. Future Herdr/remote factories must not call it or
export the local control socket. Environment values, raw argv and authentication
values must not be copied into diagnostics. Tests use only synthetic credentials
and owned paths; the account lookup test never logs its environment or launches
the user's shell.

`xterm-256color` uses the system/user terminfo lookup policy, not the old Ghostty
resource bundle. User TERMINFO/TERMINFO_DIRS remain user overrides. No new
terminfo database or automatic Ghostty bash/zsh/fish integration is shipped.
Complete login-shell/startup/terminfo/integration parity is **not certified**;
production settings/host/bootstrap wiring is still pending.

## Close barrier and identity after awaits

`NativeLocalPTYCloseBarrier.Target` contains an actual session plus a host
identity check. It is a **finite close snapshot, not another pane registry**.
The future host must check both controller and session identity, not UUID alone.

1. Reject pre-cancelled operations, duplicate pane IDs and already-stale targets
   before signals, input changes or any layout mutation.
2. Call `beginClosing()` on every target before the first suspension: reject new
   user input and discard unsent queue bytes. Already in-flight input cannot be
   undone. Automatic terminal replies retain the existing graceful-close route.
3. Start all session `stop()` tasks and await **all** of them, even when one fails.
   Per-session stops coalesce. Cleanup uses the unchanged 0.5-s graceful/force
   escalation and 5-s failure deadline, never a longer parser/acceptance timeout.
4. After cleanup, refuse cancelled/stale operations. Only then execute the host's
   synchronous `then` removal, with no await between identity checks and removal.
   A replacement with the **same UUID** is not stopped or removed by the old close.

Cancellation after close starts cannot undo ending a program. It does not
abandon the independently owned cleanup; the barrier retains layout instead of
claiming removal succeeded. Cleanup failure likewise retains the owner/layout
and propagates the error; another explicit stop may retry cleanup, never input.
The owner does not delete cwd or the user's HOME, on success or failure.

Kernel-current foreground signaling, reuse-protected root reaping, executing
callback ownership and finite output boundaries remain exactly the existing
runner policies. No cached process-group kill, process-table scan, shared-core
restart or promise of killing escaped/disowned daemon trees is introduced.

## Evidence and remaining work

**15 new cases** cover explicit production user context versus private defaults,
login argv/locale/validation, account snapshot ownership, an actual owned exec
probe, preserved caller directories, single launch, wrong-pane refusal before
reset, synchronous input closure, coalesced stops/reaping, multiple owners,
replacement with the same UUID, cancellation before/after close, and duplicate/
stale targets. The exec probe compiles only a tiny owned C client; it receives
exactly the production policy's `-basename`/`-i` and synthetic owned environment.
It is **not** a real-user shell/profile acceptance test or a C-core rebuild.
The existing private PTY/drain/launch suite also passes through the extracted
session unchanged. Full lab: **342 passed / 0 skipped**; main app:
**362 passed / 1 system-capability skip**.

Main application backend, factories and all actual pane/tab/workspace/window/
quit/CLI close routes are **not switched**. Herdr explicit close versus viewer
only detach still belongs to `HerdrTerminalSession`; the local barrier never
stops a core. Production close/save ordering, final-window CLI reply and router
retry/grant rules must be wired together in 5C, without routing mutations around
the router. Scroll Mode now has isolated [core ports](SCROLL-MODE-COMPATIBILITY.md),
not its input ownership/overlay. Host/input-source integration, full shell and
manual/device/power acceptance remain open. This is reusable isolated ownership
infrastructure, not whole-app lifecycle certification.
