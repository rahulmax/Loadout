# Per-project control: plan

Goal: choose plugins, MCP servers, connectors and skills per project, from one place, across Claude Code, Codex, Antigravity and Cursor. Show dev servers under the project they belong to.

## What testing established

Tested on 2026-11-01 with Claude Code, Codex 0.159.3 and agy 1.4.10, in scratch folders, some with fake config homes. "Docs" means read but not tested.

### Claude Code

| Fact | Consequence |
|---|---|
| A user-level deny can't be undone by a project | The global deny list has to go |
| User `allowedMcpServers: []` plus a project allow loads only that server | Default-off works, and a new folder starts empty |
| Project deny beats any allow | A project can turn off what the default leaves on |
| Project `enabledPlugins` works in both directions | Plugins are per project already |
| Project `skillOverrides` works, checked in a real session | Skills are per project already |
| Deny by name works for connectors, allow by name does not | Allow connectors by URL |
| `https://host/*` also matches a URL with no path | One rule covers a server's URL variants |
| One URL rule covers user, plugin and connector copies | One service gets one rule |
| `serverCommand` allow and deny both work for a stdio plugin server | Rule for plugin stdio servers |
| `claude --setting-sources project,local mcp list` ignores user allow and deny | Finds every connector with its URL, Higgsfield included |
| In the home folder, `.claude/settings.json` reads as both user and project | Run discovery from a folder Loadout owns |

### Codex

| Fact | Consequence |
|---|---|
| Project `[mcp_servers.x] enabled` flips the global value both ways | MCP per project |
| Project `[plugins."x"] enabled = false` removes the plugin | Plugins per project |
| An untrusted project's `.codex/` is ignored | Show this, and offer an explicit Trust action |
| Symlinks in `.agents/skills` load | Skills per project by linking |
| Project `[[skills.config]]` had no effect on a symlinked skill | Don't use it |

### Antigravity

| Fact | Consequence |
|---|---|
| Workspace `.agents/mcp_config.json` servers start in a real session | MCP per project |
| A workspace entry with `disabled: true` **still started** | Off means removing the entry. Remember it so On can put it back |
| `agy mcp list` reads only the global file | The CLI can't confirm project state |
| Global `~/.gemini/config/mcp_config.json` is empty on this machine | Nothing to fight with today. A global server stays on and is shown locked in project view |
| Plugin toggle per project: docs don't say | Not offered |

### Cursor (docs)

MCP on/off lives in app state, with no file flag. Skills come from `.agents/skills`. So servers are listed read-only, and skills arrive through the same links.

## Design

### Structure

One project picker sits above the tabs and governs everything. The tabs become **Ports**, **Tools** and **Skills**.

- **All projects** is the default for any project with no choice of its own.
- Picking a project changes what the switches mean: they now write to that project only.
- **Ports** groups servers by project. With a project picked, it shows that project's servers and says so.
- **Tools** merges Plugins and MCP into one row per service. Figma is one row, whatever mix of plugin, server and connector provides it.
- **Skills** keeps a row per skill, with plain labels.

### Service rows

- Merge rule: same name, same URL host, or a server that belongs to a plugin.
- The row switch sets every source in every harness where the service is set up.
- A disclosure shows each source and harness with its own switch, plus **Add to this project** for a harness where it isn't set up.
- Set-up harnesses are the only ones the main switch touches, so a click never writes to a tool you haven't opted into or triggers a surprise sign-in.
- A definition holding secrets (`env`, headers, tokens in arguments) or plugin-relative paths is never copied to another tool.

### Skill states

| Stored value | Label | Meaning shown on screen |
|---|---|---|
| `on` | Auto | The agent can pick it |
| `user-invocable-only` | Manual | Only when you type /name |
| `off` | Off | Gone |
| `name-only` | Moved to a context menu; shown as a fourth state only if already set | Name only |

### Where each choice is written

| Choice | All projects | One project |
|---|---|---|
| Claude plugin | `enabledPlugins`, user file | same key, `.claude/settings.local.json` |
| Claude server | `allowedMcpServers`, user file | local allow to turn on, local deny to turn off |
| `/mcp` turned it off here | n/a | Removed from `~/.claude.json` when turned on |
| Claude skill | `skillOverrides`, user file | same key, local file |
| Codex server, plugin, connector | `~/.codex/config.toml` | `.codex/config.toml` |
| Antigravity server | global `disabled` flag | add or remove in `.agents/mcp_config.json` |
| Skills for Codex, Antigravity, Cursor | n/a | symlinks in `.agents/skills`, for skills set to Auto |

Each harness's own files stay the source of truth. Loadout keeps only presets, preferences and its remembered connector list, in `~/Library/Application Support/Loadout/`. This differs from the central profile first proposed: a central copy would drift whenever someone used `/skills` or `/mcp`.

Files that aren't private by default go in `.git/info/exclude`, unless the repo already tracks them. Then Loadout merges keys and leaves the rest alone.

### The switch to default-off

Not automatic. It changes global behaviour, so it is a banner with a plain explanation and a button.

1. Back up `settings.json`.
2. Write an allowlist of everything on today, so nothing changes on the day.
3. Allow servers defined only in a project by name. That permits them only where they exist.
4. Remove global deny entries that match a known server. Keep any others.
5. Offer a one-click way back.

Before the switch, the old behaviour still works. A project can turn things off, and a globally blocked row says why it can't turn on.

## Usability rules

Nielsen's heuristics, the Apple HIG and WCAG AA, as applied here:

| Rule | Applied as |
|---|---|
| Visibility of status | The picker always shows the scope. The footer says what was saved and when it takes effect. Rows set for this project say so |
| Match the real world | Auto, Manual, Off. "Plugin + MCP" instead of field names. Tool jargon stays in tooltips |
| User control | Undo in the footer for every change. Reset per row and per project. A way back from the switch |
| Consistency | One switch style, one meaning of "on". The same picker governs all tabs |
| Error prevention | Two-step confirm on bulk changes. Secrets never copied. Tracked files merged, not replaced |
| Recognition over recall | Skill legend on screen, not only in tooltips. Recent projects first |
| Flexibility | Filter field, presets, keyboard use of the picker |
| Minimal design | Sources and harness detail stay behind a disclosure |
| Recover from errors | Errors say what failed and what to do. A locked row names its reason and fix |
| Help | Short explanation where a decision is made, no separate manual |
| Accessibility | Labels on every switch and segment. Meaning never carried by color alone. Information text at `.secondary`, not `.tertiary`. Reduce Motion respected |

## Build order

1. Core: config writer with undo, TOML editor, Claude rule matching.
2. Inventory: services, skills, harness readers, discovery.
3. Writes: per-scope set and reset for each harness, skill links, git exclude.
4. Migration and presets.
5. Port grouping.
6. UI: picker, Tools, Skills, Ports groups, footer, banner.
7. Docs and site copy.

## Tests

- **Unit** (temp home, real files): rules and globs, TOML edits that keep comments, every set and reset per scope, undo, migration, secret handling, symlink safety, git exclude, port grouping.
- **Integration**: run the real `claude mcp list` and `codex mcp list` against what Loadout writes, using fake config homes. Skip if the CLI is absent.
- **UI**: debug binary renamed `LoadoutDbg` with `LOADOUT_HOME` pointing at a fixture. Confirm the fixture state on screen before any press. Never press Kill in a test panel. Light and dark snapshots for each tab, plus a review against the rules above.
- **Real config**: read-only. Tests never write to the real home.

## Release

`v0.2.0`: merge to `main`, push, tag, GitHub release with an ad-hoc signed zip, install to `/Applications`, update the site. There's no Developer ID certificate on this machine, so the build can't be notarized and downloaders will see a Gatekeeper prompt. The release notes say so.

The switch to default-off stays your click. The release doesn't change your settings.

## Known limits

- Antigravity plugins can't be set per project, and global Antigravity servers can't be turned off for one project.
- Cursor MCP is read-only.
- Skill links reach other tools only per project, and only for skills set to Auto, because those tools have no per-skill state.
- Token figures count skill descriptions only. MCP tool names and server instructions aren't measured.
- With an allowlist, a new connector or `.mcp.json` server stays off until turned on.
