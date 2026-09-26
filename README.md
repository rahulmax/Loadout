# Loadout (menu bar app)

A macOS menu bar app for surgical control over what Claude Code injects into context.

## Why this exists

Claude Code has its own switches, but they work per project and write to three different places:

- `/skills` sets a skill to on, name-only, slash-only or off, with a token estimate. It saves to that project's `.claude/settings.local.json`, so every other project keeps the old state.
- `/mcp` disables a server for the current project only (`projects[<path>].disabledMcpServers` in `~/.claude.json`). A new folder starts with everything back on.
- `/plugin disable` is global and complete: the plugin's skills, agents and MCP servers all go. It's also the only way to drop a plugin's skills. `skillOverrides` ignores them.
- `deniedMcpServers` is the one global MCP block. It has no UI; you type names or URLs into `settings.json`.

Loadout sets the user-level fields once, for every session, and shows where a project's own settings differ.

## What it does

Menu bar panel with four tabs (Ports is first and default):

- **Ports** — lists locally listening dev servers (detection ported from [port-whisperer](https://github.com/LarsenCundric/port-whisperer)): port as a clickable `localhost:PORT` link, process/project/framework/PID/uptime, and a health dot from a live HTTP/TCP probe (green = responding, red = not responding, grey = checking/unknown). Per-row **Restart** (kill, then relaunch the same command in the same working directory, detached so it survives Loadout quitting) and **Kill** (SIGTERM, then SIGKILL if it's still alive after a short grace period), plus a **Kill all** button with a two-step confirm. System/desktop processes are filtered out the same way port-whisperer's default (non-`--all`) view does. Auto-refreshes every few seconds while the tab is visible; stops when it isn't.
- **Plugins** — toggle on/off (writes `enabledPlugins`)
- **Skills** — 4-state inline segmented control per user skill in `~/.claude/skills/`: `on` / `name-only` / `user-invocable-only` / `off` (writes `skillOverrides`), all four states visible and one tap away. Skills that set `disable-model-invocation` only offer Slash or Off. A folder marker shows how many projects set their own state for that skill; the tooltip lists them. **Turn all off** (two-step confirm, no undo) sets every user skill to `off` in one write.
  - Plugin skills are listed per plugin without controls. Claude Code ignores `skillOverrides` for them, so they are on exactly when the plugin is. If `skillOverrides` holds `plugin:skill` keys from older Loadout versions, a row offers to remove them.
- **MCP Servers**
  - *User* subsection: local MCPs from `~/.claude.json` `mcpServers`. The switch adds or removes a `{"serverName": …}` entry in `deniedMcpServers`; the server's config stays where it is.
  - *claude.ai* subsection: hosted integrations (Gmail, Calendar, Drive, Slack, Miro, Figma). The switch adds or removes a `{"serverUrl": …}` entry in `deniedMcpServers`. Hardcoded catalog so denied entries stay visible (they disappear from `claude mcp list` once denied).
  - Both show "Off in N" when `/mcp` has disabled the server in some projects.

After every Plugins/Skills/MCP toggle, `/reload-plugins` is copied to the clipboard so you can paste it into an active session for in-session reload. New sessions pick up changes automatically. Ports actions (kill/restart) act on the process directly and don't touch Claude's config, so no reload prompt applies to them.

## Architecture

Single SwiftUI executable wrapped into a `.app` bundle with `LSUIElement=true` (menu-bar-only, no Dock icon). UI is a `MenuBarExtra` with `.window` style.

**Files:**
- `Package.swift` — SwiftPM executable target, `macOS 14+`
- `Info.plist` — bundle metadata, `LSUIElement=true`, `LSMinimumSystemVersion=14.0`
- `Sources/Loadout/App.swift` — Plugins/Skills/MCP tabs, the settings store, and shared view chrome
- `Sources/Loadout/Ports.swift` — Ports tab: scanner, health probing, kill/restart, and its views
- `build.sh` — `swift build -c release` then assembles `Loadout.app`

**Data sources read on open:**
- `~/.claude/plugins/installed_plugins.json` — installed plugin list
- `~/.claude/settings.json` — `enabledPlugins`, `skillOverrides`, `deniedMcpServers`, `allowedMcpServers`
- `~/.claude.json` — `mcpServers`, and `projects` for the per-project `disabledMcpServers`
- `<project>/.claude/settings.json` and `settings.local.json` for up to 200 known projects — per-project `skillOverrides`, read only
- `~/.claude/skills/` directory walk — user skills
- Each enabled plugin's install path — plugin-bundled skills
- `/bin/zsh -lc "claude mcp list"` async — live status for claude.ai integrations
- `lsof -iTCP -sTCP:LISTEN -P -n`, batched `ps`/`lsof -d cwd` per PID, and a per-port HTTP/TCP probe — Ports tab, re-scanned on refresh and every few seconds while that tab is visible

**Write path:** every toggle writes `~/.claude/settings.json` only. It calls `mutateJSON(at:mutate:)`, which reads → parses → mutates → writes to a temp file with `[.prettyPrinted, .sortedKeys]` → atomically swaps via `FileManager.replaceItemAt`. After write: reload inventory and copy `/reload-plugins` to clipboard.

**Concurrency:** inventory loads off-main via `Task.detached`. `runClaudeCLI` and `copyReloadCommand` are free functions (not `@MainActor`-isolated) so detached tasks can call them without isolation errors.

**No IPC into running Claude.** Verified — Claude Code has no local listening socket, only outbound TCP. The clipboard handoff is the workaround.

## Settings field reference

| Field | File | Purpose |
|---|---|---|
| `enabledPlugins` | `~/.claude/settings.json` | `{"marketplace:name": true/false}` — plugin on/off. The only switch for a plugin's skills and MCP servers |
| `skillOverrides` | `~/.claude/settings.json` | `{"skill-folder-name": "on" \| "name-only" \| "user-invocable-only" \| "off"}`. Keyed by folder name, not the frontmatter `name`. Ignored for plugin skills |
| `deniedMcpServers` | `~/.claude/settings.json` | `[{"serverName": …} \| {"serverUrl": …}]` — blocked in every project. Names match verbatim, case and spaces included |
| `mcpServers` | `~/.claude.json` | Local MCP configs. Read only |
| `projects[<path>].disabledMcpServers` | `~/.claude.json` | What `/mcp` turned off in one project. Read only |
| `skillOverrides` | `<project>/.claude/settings.local.json`, `settings.json` | What `/skills` set in one project. Wins over the user value. Read only |

**What each skill state costs.** The skill listing carries a name and description per skill; the body loads only when the skill is used. `on` costs the description (Claude Code caps it at 1,536 characters, typically 50–1,400), `name-only` just the name, `user-invocable-only` and `off` nothing. On a large set, Claude Code may also trim the least-used descriptions to fit its own listing budget.

## Build & run

```bash
./build.sh                              # produces Loadout.app
open Loadout.app                        # run from current dir
cp -R Loadout.app /Applications/        # install
```

To review the panel without clicking through the menu bar, render every tab in light and dark (debug builds only):

```bash
swift build && LOADOUT_SNAPSHOT=/tmp/loadout-shots .build/debug/Loadout
```

Snapshot runs never write. Add `LOADOUT_HOME=/path/to/fixture` to read a fake home folder (`.claude/settings.json`, `.claude.json`, `.claude/plugins/installed_plugins.json`, `.claude/skills/`) instead of your own.

Requires macOS 14+ (SwiftUI `MenuBarExtra` with `.window` style + `foregroundStyle`).

## Known limitations

- **Hardcoded claude.ai catalog** (6 services). New integrations connected via `/mcp` won't appear unless added to `claudeAiCatalog` in `App.swift`.
- **Startup cost** — each open spawns `claude mcp list`, which can take a second or two.
- **`deniedMcpServers` precedence** — denies override `allowedMcpServers`; toggling re-enable means removing from the deny list, not adding to allow.
- **Upgrading from `_disabledMcpServers`** — older versions parked disabled local servers in a custom `_disabledMcpServers` key. On launch, Loadout backs up `~/.claude.json` once to `~/.claude.json.loadout-backup`, denies each parked server by name, then moves its config back into `mcpServers`.
- **Project overrides are shown, not changed** — Loadout reads per-project skill and MCP settings to flag them, but only writes user-level fields. Clear a project's override with `/skills` or `/mcp` in that project.
- **No undo** — toggles write immediately. The atomic swap means you don't get a corrupt file, but you do need to re-toggle to revert. Kill all / Turn off all skills require a two-step confirm for the same reason.
- **Restart needs a known cwd** — restart re-invokes the exact command line `ps` reports in the exact directory `lsof` reports as its cwd. If a process can't report a cwd (already dead, sandboxed, permissions), restart is disabled for that row with an explanation in its tooltip. It does not restore env vars the original shell had beyond what login-shell (`zsh -l`) sourcing provides.
- **Ports health probe is best-effort** — an HTTP GET to `http://127.0.0.1:<port>/`, falling back to a raw TCP connect for non-HTTP services (databases, etc). A service that accepts TCP but hangs on the health path can read as healthy even if the app logic is stuck.
