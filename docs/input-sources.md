# Automatic Input Sources

In **Settings → Terminal**, enable **Pane Input → Switch Input Source by Foreground
Program** to choose an input source by executable name. The initial rules cover
`claude`, `codex` and `nvim`; choose the Chinese input source for your agents and
the shared **English Input Source** for neovim. Rules apply when entering a pane
and when its foreground program changes. Unknown programs keep the current
source. A manual selection lasts until the next context change; Chinese
composition delays switching until it ends.

**Command Palette Input → Automatically Switch to English** is independent of
pane rules. The palette uses the shared English input source; closing it applies
the destination pane's rule, or restores the source used before opening it.
Both features start disabled. Sources must be enabled in macOS System Settings.
Selecting an input source does not reset a third-party IME's internal Chinese /
English mode. SSH and tmux sessions expose only the local foreground program.
