# Loadout (menu bar app)

A macOS menu bar app for controlling what Claude Code, Codex, Antigravity and Cursor load into context, as a default and per project.

## Why this exists

Every tool has its own switches, in its own files, with its own rules:

- `/skills` sets a skill to on, name-only, slash-only or off. It saves to that project's `.claude/settings.local.json`.
- `/mcp` disables a server for one project (`projects[<path>].disabledMcpServers` in `~/.claude.json`). A new folder starts with everything back on.
- `/plugin disable` removes the plugin's skills, agents and MCP servers. `skillOverrides` can't touch plugin skills, so it's the only switch for them.
- `deniedMcpServers` blocks a server everywhere, with no UI, and a project can't undo it. Connectors you never listed still load.
- One service, like Figma, can be a plugin, an MCP server and a claude.ai connector at once, plus separate entries in Codex and Cursor.

Loadout shows each service as one row, and each row can be set as the default or for one project.

## What it does

The picker at the top of the panel sets what every switch changes: **All projects** (the default) or one project (search, recent first, or **Choose folder**). A line under it says so in words.

**Ports** stays on screen under the picker. It lists locally listening dev servers (detection ported from [port-whisperer](https://github.com/LarsenCundric/port-whisperer)), up to three to a row: the port, its framework, and a health dot from a live HTTP/TCP probe (green = responding, red = not responding, grey = checking/unknown). Click a server to open it. Hover for **Restart** (kill, then relaunch the same command in the same working directory, detached so it survives Loadout quitting) and **Kill** (SIGTERM, then SIGKILL if it's still alive after a short grace period; asks once first); the tooltip has the process, folder, PID and uptime, and right-click has the same actions. **Kill all** has a two-step confirm. Servers are grouped under their project (deepest known project containing the folder, else the folder itself; servers run from home sit under Other). The project's name opens its Tools, and hovering it offers to kill that project's servers. Choosing a project at the top filters the list to it, with the count of servers elsewhere one click away, and **Kill N** then stops only what's shown. Past a few rows the list scrolls. System/desktop processes are filtered out the same way port-whisperer's default (non-`--all`) view does. Auto-refreshes every few seconds while the panel is open.

Two tabs below it:

- **Tools** — one row per service, grouped by name and URL host across plugins, MCP servers, claude.ai connectors, Codex and Antigravity and Cursor. The main switch changes every tool that has the service; the disclosure shows each tool's own switch, why anything is locked and how to fix it, what's set up where, and the plugin's skills with their token cost. A **This project** tag and reset icon mark what a project overrides. **Add to this project** copies a server to Codex or Antigravity for that project, only if its config holds no secrets. Every connector on the account is found by asking `claude`, so nothing depends on a built-in list.
- **Skills** — **Auto** (the agent can pick it), **Manual** (only when you type `/name`), **Off** (hidden everywhere), with the legend always on screen. **Name only** is on right-click. Each row shows its token cost. Skills that set `disable-model-invocation` offer Manual or Off. Plugin skills follow their plugin, so they're summarised with a link to Tools. Old `plugin:skill` keys from earlier versions are flagged, with a button to remove them.

The row beside the logo picks which tools to show: Claude, Codex, Antigravity, Cursor. Each shows how many plugins, MCP servers, connectors and skills it has; hover for the breakdown. Skills are counted under Claude. It changes what Loadout shows and edits, not the tools themselves. A hidden tool keeps running with its settings as they are, and the main switch on a row leaves it alone.

The project list shows folders with a config file for a tool you're showing: `.claude`, `CLAUDE.md` or `.mcp.json` for Claude, `.codex`, `AGENTS.md` or trust in Codex, `.agents` or `GEMINI.md` for Antigravity, `.cursor` or `.cursorrules` for Cursor. **Choose folder…** adds any other folder for good. Desktop, Documents and Downloads aren't looked inside, since that can bring up a macOS permission prompt, so folders there need Choose folder too.

The footer says what was saved, and has **Undo** for each change this session. Changes also copy `/reload-plugins` for open sessions; new sessions pick them up on their own. The **…** menu holds presets (save the current set, apply it to any scope) and restore.

## Per project, per tool

| | Claude Code | Codex | Antigravity | Cursor |
|---|---|---|---|---|
| MCP servers | Both ways | Both ways, trusted folders | Project can add; global ones stay on | Read only |
| claude.ai / ChatGPT connectors | Both ways | Both ways, trusted folders | None | None |
| Plugins | Both ways | Both ways, trusted folders | Global only, not offered | Not offered |
| Skills | Both ways | Through `.agents/skills` | Through `.agents/skills` | Through `.agents/skills` |

## The one-time switch

Claude Code's user deny list always wins, so a server blocked for all projects can't be turned on in one. Per-project control needs the reverse: an allowlist, so servers are off unless allowed. That also stops new connectors turning on by themselves.

Loadout never makes this change alone. A banner explains it and waits for **Switch**. It backs up `settings.json`, allows everything on today, and removes deny entries that match a known server, so nothing changes on the day. It waits until connector discovery has finished, because a connector it didn't know about would go off. **Undo** works straight after, and **Restore settings from before the switch** in the **…** menu works later. Before the switch, a project can still turn things off.

## Architecture

Single SwiftUI executable wrapped into a `.app` bundle with `LSUIElement=true`. The UI is a `MenuBarExtra` with `.window` style.

**The tools' own files stay the source of truth.** Loadout keeps no profile of on/off choices that could drift, and reads everything back on each open. Its own `~/Library/Application Support/Loadout/state.json` holds only what no tool's config can: which tools to show, presets, connector URLs, Antigravity servers turned off in a project, and where the backup is.

**Files:**
- `Sources/Loadout/App.swift` — entry point, design tokens, panel shell, tab bar, debug snapshots
- `Sources/Loadout/Store.swift` — what the panel shows; runs each action as one undoable step
- `Sources/Loadout/ProjectViews.swift` — picker, Tools, Skills, migration banner
- `Sources/Loadout/Ports.swift` — scanner, health probing, kill/restart, grouping and views
- `Sources/Loadout/Core/Model.swift` — scope, tools, Claude rule matching, services, saved state
- `Sources/Loadout/Core/Inventory.swift` — reads every tool's config and groups it into services
- `Sources/Loadout/Core/Engine.swift` — every write, per scope and per tool; skill links; presets; the switch
- `Sources/Loadout/Core/ConfigIO.swift` — atomic writes, undo, `.git/info/exclude`
- `Sources/Loadout/Core/TOML.swift` — line-based editor that keeps comments and formatting
- `Tests/LoadoutTests` — unit tests on a temp home, plus tests that ask the real `claude` and `codex` CLIs about what the engine wrote (fake `HOME` and `CODEX_HOME`; skipped if a CLI is absent)
- `docs/per-project-plan.md` — how each tool was tested, and the design that came from it

**Where it writes:**

| Scope | Tool | File |
|---|---|---|
| All projects | Claude Code | `~/.claude/settings.json` |
| All projects | Codex | `~/.codex/config.toml` |
| All projects | Antigravity | `~/.gemini/config/mcp_config.json` |
| Project | Claude Code | `<project>/.claude/settings.local.json`; clears a `/mcp` disable in `~/.claude.json` when you turn that server on |
| Project | Codex | `<project>/.codex/config.toml`. **Trust** adds the folder to `~/.codex/config.toml`, only when you press it |
| Project | Antigravity | `<project>/.agents/mcp_config.json` |
| Project | Skills for other tools | Links in `<project>/.agents/skills` |

Generated project files go in `.git/info/exclude`, unless the repo already tracks them. Skill links are only ever removed when they point at a skill folder Loadout knows, so real folders and other links are left alone. Undo restores each file only if nobody has changed it since. `~/.claude.json` changes constantly, so undo there re-applies just the one change instead.

**Reads:** `~/.claude/plugins/installed_plugins.json` and each plugin's `.mcp.json` and skills; `~/.claude/settings.json`; `~/.claude.json`; each project's `.claude/settings.json`, `settings.local.json`, `.mcp.json`, `.claude/skills`; the Codex, Antigravity and Cursor configs above. Connectors come from `claude --setting-sources project,local mcp list`, run from a folder Loadout owns, so the user lists can't hide any. Ports uses `lsof`, `ps` and a per-port probe.

**No IPC into running Claude.** Claude Code has no local listening socket, so the clipboard is the handoff.

## Claude Code rules worth knowing

Tested on Claude Code 2.1.316. Full results in `docs/per-project-plan.md`.

- Allow and deny lists merge across scopes. Deny wins.
- Allow by name doesn't work on connectors or plugin servers. Allow by URL does, and one URL rule covers every copy of a server.
- Stdio plugin servers are matched by `serverCommand`.
- `https://host/*` also matches a URL with no path.
- A project's `enabledPlugins` wins over the user's, both ways.

**What each skill state costs.** The listing carries a name and description per skill; the body loads only when used. Auto costs the description (capped at 1,536 characters), Name only just the name, Manual and Off nothing. On a large set, Claude Code may trim the least-used descriptions itself. Token figures in the panel are estimates, at four characters a token.

## Build & run

```bash
swift test                              # unit tests, plus real-CLI tests where installed
./build.sh                              # Loadout.app, ad-hoc signed
./build.sh --zip                        # also Loadout-<version>.zip for a release
open Loadout.app                        # run from current dir
cp -R Loadout.app /Applications/        # install
```

To review the panel without clicking through the menu bar, render every tab in light and dark (debug builds only):

```bash
swift build && LOADOUT_SNAPSHOT=/tmp/loadout-shots .build/debug/Loadout
```

Snapshot runs never write. Add `LOADOUT_HOME=/path/to/fixture` to read a fake home folder, with `mcp-list.txt` in it standing in for `claude mcp list`, and `LOADOUT_SCOPE=/path/to/project` to render one project.

UI scripting a debug build called `Loadout` drives the installed app and its real settings. Copy the binary to another name and use `LOADOUT_HOME` first.

Requires macOS 14+.

## Known limitations

- **Not notarized.** Releases are ad-hoc signed, so macOS blocks the first launch. Use **Open Anyway** in System Settings → Privacy & Security, or run `xattr -d com.apple.quarantine /Applications/Loadout.app`.
- **Hiding Claude doesn't hide its skills.** The Skills tab still lists them, a change there still writes to Claude's settings, and the footer can still mention `/reload-plugins`.
- **Cursor is read only.** It keeps MCP on/off in its own app state. It still gets skills through `.agents/skills`.
- **Antigravity has no working per-project off.** `disabled: true` in a workspace file didn't stop the server when tested, so off removes the entry and Loadout remembers it. A server in the global file stays on in every project until it's off under All projects.
- **Antigravity plugins are global.** Not offered per project.
- **Codex needs trust.** It ignores a project's `.codex/config.toml` until the folder is trusted. Loadout says so and offers the button.
- **Codex connectors show an ID, not a name.** `config.toml` holds only the ID.
- **Secrets are never copied.** A server with `env`, `headers`, a token in its arguments or plugin-relative paths can't be added to another tool. Connectors aren't copied either, since their sign-in belongs to claude.ai.
- **Plugin stdio servers using `${CLAUDE_PLUGIN_ROOT}`** are matched on the expanded path. None were installed to test this against.
- **A plugin's server can't stay on with the plugin off.** The two are one thing to Claude Code.
- **Skills linked for other tools share their state.** A link exists when a skill is on Auto. Manual has no equivalent there.
- **Repo-level settings are respected, not changed.** A block in a repo's `.claude/settings.json` shows as a lock naming the file.
- **Undo lasts for the session.**
- **Token figures cover skill descriptions only.** MCP tool names and server instructions aren't measured.
- **After the switch, a new connector or `.mcp.json` server stays off** until you turn it on. That's the point of it, but it can surprise you.
- **Upgrading from `_disabledMcpServers`** — very old versions parked servers in a custom key. On launch, Loadout backs up `~/.claude.json` once to `~/.claude.json.loadout-backup`, and moves them back, off.
- **Restart needs a known cwd** — restart re-invokes the exact command line `ps` reports in the exact directory `lsof` reports as its cwd. If a process can't report a cwd (already dead, sandboxed, permissions), restart is disabled for that row with an explanation in its tooltip. It does not restore env vars the original shell had beyond what login-shell (`zsh -l`) sourcing provides.
- **Ports health probe is best-effort** — an HTTP GET to `http://127.0.0.1:<port>/`, falling back to a raw TCP connect for non-HTTP services (databases, etc). A service that accepts TCP but hangs on the health path can read as healthy even if the app logic is stuck.
