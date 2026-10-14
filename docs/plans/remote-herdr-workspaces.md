# Unified Workspaces and Remote Herdr

Implemented and verified, 2026-10-14. User scope: one Workspace directory with Local Workspace, Herdr Workspace, and Remote Herdr Workspace; SSH follows the native Herdr client rather than OpenSSH socket forwarding.

## Contract

- Workspace identity is a local UUID or an endpoint identity plus server workspace ID. Machine labels do not define identity. Remote endpoint profiles come from `herdr machine list --json`; one profile selects one explicit session.
- Each endpoint keeps an inactive ClientShell connection for workspace/agent metadata and notifications. The selected workspace borrows that connection and activates surface interest; leaving deactivates it. Input requires a fresh coherent presentation. Retired command clients cannot become writable again when the connection is reused.
- Remote client traffic is `remote-client-bridge` over OpenSSH stdio; management reads use `remote-api-bridge`. Bounded queues and existing binary codecs remain in use. Remote boot IDs identify the server; local helper PIDs do not.
- Native SSH compression, noninteractive background auth, strict host-key verification, scoped shared ControlPath, health checks, and backoff remain part of the remote path. Setup/authentication run through interactive Herdr commands in a local terminal.
- An existing remote installation may start its server through the native bridge. Background connections never install, upgrade, replace, or stop a server. Detach leaves panes and agents running.
- SavedWorkspace v6 stores the unified directory and selection alongside the existing local/auxiliary tab contents. Earlier versions retain their existing local and backend content during migration.

## Implemented

- WorkspaceReference/Entry and endpoint-scoped identity, validated saved-machine catalog.
- Native SSH stdio adapter with output-ready marker, Unix/Windows launch commands, executable capability discovery, process/error limits, and managed authentication reuse.
- API and ClientShell remote connection paths; remote server boot identity; retired command routes.
- Multi-endpoint agent records, notification routing, unified Workspace picker and palette indexing.
- SavedWorkspace v6 and explicit source restoration; setup/authentication menu and palette entries.
- Shared ClientShell surface activation/deactivation and bounded remote reconnect.
- Machine rename preserves its connection; target/session changes, removal and disablement retire that source. Local selection can cancel pending remote selection or reconnection.

## Verification

- Latest application and test builds passed with FlowDeck on saved My Mac target. Fixture Python syntax and `git diff --check` passed.
- Final affected regression suite: **287 tests, 283 passed, 0 failed, 4 skipped**, 88.20 seconds. Covers all Herdr test classes, RemoteHerdrTests, WorkspaceStoreTests, WorkspaceRestorationTests, WorkspaceViewControllerTests and CLITests.
- Native stdio fixture verifies metadata, image surfaces, mutations, API reads, deactivation/reactivation on one connection, and rejection of a retired command waiting for presentation.
- Metadata reconnection after an isolated server restart passed; old source identity becomes unavailable and is replaced by a fresh verified identity. Pending remote selection can be canceled immediately by Local selection.
- Isolated real OpenSSH + installed Herdr 0.9.3 integration passed: two remote sessions have duplicate workspace IDs, switching remains scoped, and Notes/local tabs survive Remote A → Remote B → Local → Remote A. Manual reconnection can be canceled by selecting Local. Closing the SSH master invalidates input while retaining the scene; restoring authentication automatically restores coherent presentation/input without restarting the remote server or losing Notes.
- User-authorized `ssh dellpc` validation passed on the actual Linux host with Herdr 0.9.3: native metadata handshake, semantic command input, command output in the local Ghostty display, API history read, Remote → Local → Remote switching and Notes preservation. `testAuthorizedSSHHostRendersInputAndPreservesLocalWorkspace` ran in 6.090 seconds with 1 passed / 0 failed / 0 skipped. Its temporary named session was stopped and deleted; a subsequent session list contained only the original running `default`. The native local machine list remained empty.
- Previously failing legacy restore, floating presentation and palette-navigation regressions now pass. A deterministic delayed-feedback test exposed a viewport synchronization race: draining Ghostty output does not drain its asynchronous reply callback. The waiter now consumes delayed replies from its current query generation instead of discarding them before every retry; delayed feedback and real resize/repaint tests pass.
- Background FlowDeck UI verification passed for opening the Workspace picker and Add Remote dialog, its three accessible fields and buttons, complete dialog layout and cancellation. Zero saved machine profiles correctly disables Authenticate Remote. No setup was submitted. Temporary visual evidence: `/tmp/santty-remote-herdr-dialog-full.png`; accessibility evidence: `/tmp/santty-remote-herdr-dialog-tree.json`.
- Dev apps and capture sessions were stopped. Final scoped process audit found no leftover SSH servers or fixture processes; the user's original Santty process remains running. No credentials or user machine profiles were changed. All temporary diagnostic logs were removed.

## Remote switch performance follow-up

- Measured the actual `dellpc` through a temporary named session, an isolated machine-list wrapper, and the normal catalog-borrowed ClientShell connection. The host's `default` session and saved profile were left unchanged.
- Three Local → Remote roundtrips with two single-pane tabs took **820.64 / 795.50 / 847.61 ms** before the change and **137.79 / 156.20 / 93.54 ms** in the build without diagnostic probes afterward: mean **821.25 → 129.17 ms**, an 84.3% reduction. These are measured samples, not a latency guarantee.
- Each serial `layout.export` previously incurred a separate SSH API preflight and request. Single-pane topology now comes directly from the validated ClientShell snapshot; native API export remains necessary for split tabs. The existing endpoint/boot/revision checks and presentation fence remain in place.
- Faster switching exposed repeated query invalidation by API subscription snapshots whose remote boot was unverified. Those snapshots no longer clear a bound remote pane's query identity; ClientShell removal/reconnection and explicit query invalidation still fence late results. The actual remote command/history read and the late-query invalidation regression pass.
- `testSinglePaneRoundtripAvoidsAPILayoutQueriesButSplitFetchesTopology` failed before the fix and passes afterward: a Local roundtrip makes no layout export, while a subsequent external split still retrieves and presents native topology.
- Removing the query delay also exposed cached palette navigation comparing its optimistic local tab selection instead of server focus. Navigation now compares the ClientShell snapshot's `focused_tab_id`; the existing companion/tab navigation regression failed before this correction and passed afterward.
- Final ClientShell + Remote suite passed without diagnostic probes: **70 tests, 69 passed, 0 failed, 1 skipped** (the opt-in typing benchmark), including actual DellPC command/history and all 14 Remote tests. Renderer, capabilities, workspace projection and WorkspaceViewController tests passed in the broader run; its one cached-navigation failure was corrected and rerun in the final suite. Build artifacts were isolated under `/tmp/santty-remote-switch-20261014` after shared intermediates disappeared twice. The user's running application was not replaced or restarted.

## Requirement evidence

| Requirement | Evidence |
| --- | --- |
| Unified Local / Herdr / Remote Herdr directory | Mixed-type picker model, palette/navigation tests, local picker UI and endpoint-scoped reference tests |
| Native remote transport and authentication reuse | Actual OpenSSH + Herdr integration and native stdio/API fixture |
| Shared metadata connection and selected surface interest | One-connection trace with activate → deactivate → reactivate; multi-endpoint agents/notifications tests |
| Boot identity, input fencing and no stale mutation replay | Endpoint/boot identity tests, retired delayed-command rejection and real SSH interruption recovery |
| Local selection remains available during remote waits | Pending selection and real manual-reconnect cancellation tests |
| Local content, per-source companions and saved selection | Real duplicate-ID switches, Workspace restoration tests, v6 directory roundtrip and legacy schema tests |
| Native setup/authentication entry points | CLI boundary validation, menu/dialog accessibility, complete screenshot and cancellation checks |

## Validation limits

The four existing opt-in tests skipped because external pane/service authorization, a configured codec capture, and the performance benchmark environment were not supplied. The isolated real SSH test ran successfully and was not skipped. Windows bridge command generation and path validation are tested; an actual Windows SSH server has not been exercised. Interactive setup submission to a user machine was intentionally not performed.

To repeat the authorized host check, explicitly supply its target and installed Linux binary. The test creates and deletes its own temporary named session; it does not register a saved machine or use the host's default session.

```sh
rtk proxy env \
  TEST_RUNNER_SANTTY_HERDR_SSH_TARGET=dellpc \
  TEST_RUNNER_SANTTY_HERDR_REMOTE_BINARY=/home/zola/.local/bin/herdr \
  flowdeck test --only SanttyTests/RemoteHerdrTests/testAuthorizedSSHHostRendersInputAndPreservesLocalWorkspace --progress
```

Earlier graphical validation was blocked by `No displays found`. After the user restored the displays, all pending rendering tests and UI verification ran. One aggregate test run stalled during old fixture cleanup and was explicitly stopped; the isolated case and two subsequent aggregate runs completed that case. No cleanup fix was inferred from the transient stall. The final aggregate run had no diagnostic instrumentation and passed.

Source reference: Herdr 0.9.3 at `2563803dca97c040beaf3dc3acdcb5a3221b4238`, local read-only checkout `/tmp/santty-herdr-research`, especially `remote/{host,saved,attach}.rs`, `client/shell/endpoints.rs`, and `server/client_commands.rs`.
