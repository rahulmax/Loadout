# Claude Plugins (menu bar app)

A macOS menu bar app for surgical control over what Claude Code injects into context.

## Why this exists

Claude Code's built-in disable affordances are inconsistent about what they actually keep out of context:

- `/plugin disable` removes a plugin's skills/agents from new sessions, but plugin-bundled MCPs sometimes stay in `mcpServers` and keep advertising tools.
- `/mcp disconnect` is not a block — tools can re-advertise on reconnect, and nothing is written that prevents future context inclusion.
- There is no UI for `skillOverrides: name-only` or `user-invocable-only`. These are the biggest context wins (full skill body can be 5–50KB; `name-only` drops it to ~150 chars while keeping the skill discoverable). The only way to set them is hand-editing `settings.json`.
- `~/.claude/skills/` (user skills) aren't reachable from `claude plugin` commands at all.

This app is the bridge between user intent ("keep this out of context") and the `settings.json` / `~/.claude.json` fields that Claude actually reads.

## What it does

Menu bar panel with three sections:

- **Plugins** — toggle on/off (writes `enabledPlugins`)
- **Skills** — 4-state picker per skill: `on` / `name-only` / `user-invocable-only` / `off` (writes `skillOverrides`). Covers both plugin-bundled and user skills in `~/.claude/skills/`.
- **MCP Servers**
  - *User* subsection: local MCPs from `~/.claude.json`, toggle moves entry between `mcpServers` and `_disabledMcpServers`.
  - *claude.ai* subsection: hosted integrations (Gmail, Calendar, Drive, Slack, Miro). Toggle adds/removes the URL in `deniedMcpServers`. Hardcoded catalog so denied entries stay visible (they disappear from `claude mcp list` once denied).

After every toggle, `/reload-plugins` is copied to the clipboard so you can paste it into an active session for in-session reload. New sessions pick up changes automatically.

## Architecture

Single SwiftUI executable wrapped into a `.app` bundle with `LSUIElement=true` (menu-bar-only, no Dock icon). UI is a `MenuBarExtra` with `.window` style.

**Files:**
- `Package.swift` — SwiftPM executable target, `macOS 14+`
- `Info.plist` — bundle metadata, `LSUIElement=true`, `LSMinimumSystemVersion=14.0`
- `Sources/ClaudePluginToggle/App.swift` — entire app (~600 lines)
- `build.sh` — `swift build -c release` then assembles `.app`

**Data sources read on open:**
- `~/.claude/plugins/installed_plugins.json` — installed plugin list
- `~/.claude/settings.json` — `enabledPlugins`, `skillOverrides`, `deniedMcpServers`, `allowedMcpServers`
- `~/.claude.json` — `mcpServers`, `_disabledMcpServers`
- `~/.claude/skills/` directory walk — user skills
- Each enabled plugin's install path — plugin-bundled skills
- `/bin/zsh -lc "claude mcp list"` async — live status for claude.ai integrations

**Write path:** every toggle calls `mutateJSON(at:mutate:)` which reads → parses → mutates → writes to a temp file with `[.prettyPrinted, .sortedKeys]` → atomically swaps via `FileManager.replaceItemAt`. After write: reload inventory and copy `/reload-plugins` to clipboard.

**Concurrency:** inventory loads off-main via `Task.detached`. `runClaudeCLI` and `copyReloadCommand` are free functions (not `@MainActor`-isolated) so detached tasks can call them without isolation errors.

**No IPC into running Claude.** Verified — Claude Code has no local listening socket, only outbound TCP. The clipboard handoff is the workaround.

## Settings field reference

| Field | File | Purpose |
|---|---|---|
| `enabledPlugins` | `~/.claude/settings.json` | `{"marketplace:name": true/false}` — plugin on/off |
| `skillOverrides` | `~/.claude/settings.json` | `{"skill-key": "on" \| "name-only" \| "user-invocable-only" \| "off"}` |
| `deniedMcpServers` | `~/.claude/settings.json` | Array of MCP server URLs to block (the only way to actually keep claude.ai integrations out of context) |
| `mcpServers` | `~/.claude.json` | Active local MCP configs |
| `_disabledMcpServers` | `~/.claude.json` | Parked local MCP configs (custom convention used by this app — swapped in/out of `mcpServers`) |

## Build & run

```bash
./build.sh                              # produces ClaudePluginToggle.app
open ClaudePluginToggle.app             # run from current dir
cp -R ClaudePluginToggle.app /Applications/   # install
```

Requires macOS 14+ (SwiftUI `MenuBarExtra` with `.window` style + `foregroundStyle`).

## Known limitations

- **Hardcoded claude.ai catalog** (5 services). New integrations connected via `/mcp` won't appear unless added to `claudeAiCatalog` in `App.swift`.
- **Startup cost** — each open spawns `claude mcp list`, which can take a second or two.
- **`deniedMcpServers` precedence** — denies override `allowedMcpServers`; toggling re-enable means removing from the deny list, not adding to allow.
- **No undo** — toggles write immediately. The atomic swap means you don't get a corrupt file, but you do need to re-toggle to revert.
