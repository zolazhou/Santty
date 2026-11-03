# Agents

**Show Agents** (⌘⇧M by default) is available from the Pane menu, command palette and the
toolbar’s Agents button (with an unread badge when reports exist). It follows
program status from herdr-core across local and remote machines, including while
a Local workspace is selected. Programs must report OSC 7501 status; Santty does
not guess activity from process names or screen text, or install agent hooks.
Root and child records show working, blocked, error, idle and unknown states.
Ended agents leave the list; their message history remains in memory.
Only an explicit `done` report creates a completion message; a turn increment or
`idle` can also mean interruption. Initial, reconnect and missed-event snapshots
establish a baseline and do not replay old notifications.

Each agent row has a message button on the right showing its message count and
highlighting unread messages. Click it to open that agent's message history in a
popover. Root and child agents keep separate histories. Click an agent, message
or notification to open its terminal, or use Up/Down, Control-P/Control-N, Enter
and Escape in the panel.
Existing Santty panes retain their workspace, tab and floating presentation.
External terminals get a saved viewer: closing that viewer, its tab or workspace
only detaches and never kills a program started by another client. Ordinary
Santty-owned Herdr panes keep their existing close-to-end behavior. Messages and
unread state are local to this app, kept in memory with a 256-message limit.

Use **Pane → New Agents Pane** for an Agents list beside your terminals, or
**Pane → Sidebar → Add Agents** for a persistent sidebar list. Both show Agents
with per-agent message popovers, share live updates and navigation, and restore
with the saved layout. Codex, Claude Code, pi, OpenCode and GitHub Copilot use
local brand icons; status dots remain separate from agent identity. Unknown
agent types retain their reported names and a generic icon. Herdr workspaces
also use their brand icon in the Workspaces list, picker and command palette.
Original SVGs, source references and license notices are bundled in
`Santty/Resources/BrandIcons/`.

Herdr agent notifications are enabled for all agent types. Santty requests macOS
notification permission when the first banner is needed; notification delivery
can be controlled in macOS System Settings. Watching the target tab suppresses
its system banner. The directory and Messages continue updating independently.



Agent tracking requires [Herdr](herdr.md). To let an agent read pane logs, see the [CLI](cli.md) and [Agent Skill](agent-skill.md).
