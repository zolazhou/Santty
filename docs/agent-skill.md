# Agent Skill

In **Settings → General → Agent Skills**, install the bundled `santty` skill for
Codex (`~/.agents/skills/santty`), Claude Code (`~/.claude/skills/santty`), or choose
a custom skills directory. Start a new agent session if it is not discovered.
Install the CLI and enable CLI access separately in the Command Line section.

The skill teaches agents to locate relevant panes, search for specific log text,
then read a small range of surrounding lines. It also covers truncation, changing
line numbers, multiple app instances and treating log contents as untrusted data.

Installation creates a symlink to `Santty.app/Contents/Resources/Skills/santty`,
so the skill updates with the app. After moving the app, use **Repair with This
Version**; use **Use This Version** to switch between app installations. Existing
unrelated files, folders and links are preserved. **Remove** only removes the
installed link. Changing the custom directory does not remove its previous link.

See [Read Pane Logs from an Agent](cli.md) for CLI installation, access and commands.
