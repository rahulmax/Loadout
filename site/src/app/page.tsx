import { ArrowDown, ArrowUpRight } from 'lucide-react'
import { FlowFigure, SkillCostFigure } from '@/components/figures'
import { Panel } from '@/components/panel/panel'
import type { Harness, TabId } from '@/components/panel/panel-data'
import { Tabs } from '@/components/tabs'
import { ThemeToggle } from '@/components/theme-toggle'

const REPO = 'https://github.com/rahulmax/Loadout'

const GAPS = [
  {
    command: '/skills',
    body: 'Four states and a token count per skill. It saves to this project’s settings.local.json, so every other project keeps the old state.',
  },
  {
    command: '/mcp',
    body: 'Disable is saved, but for this project only. Open a new folder and the server is back.',
  },
  {
    command: '/plugin disable',
    body: 'Global and complete: skills, agents and MCP servers all go. It’s also the only switch for a plugin’s skills.',
  },
  {
    command: 'deniedMcpServers',
    body: 'The one block that holds in every project, and no project can undo it. No UI: you type server names and URLs into settings.json.',
  },
]

const FEATURES: {
  tab: TabId
  kanji: string
  name: string
  title: string
  body: string
  points: string[]
  shown?: Harness[]
}[] = [
  {
    tab: 'ports',
    kanji: '港',
    name: 'Ports',
    title: 'See what’s running. Stop what isn’t needed.',
    body: 'Every dev server listening on your Mac, grouped by project with the folder, framework, PID and uptime. A live probe marks each one as responding or not.',
    points: [
      'A Tools shortcut on each project opens its switches',
      'Kill N stops a whole project’s servers. Kill all asks twice',
      'Pick a project to show only its servers, with Show all to widen it',
    ],
  },
  {
    tab: 'tools',
    kanji: '具',
    name: 'Tools',
    title: 'One row per service.',
    body: 'Figma as a plugin, an MCP server and a claude.ai connector is one row with one switch. Open it to see each tool’s own control. Every connector on your account is listed, including ones you never added by hand.',
    points: [
      'A This project tag and a reset icon mark what a project overrides',
      'Connectors you haven’t connected show locked, as Not connected',
      'Plugin, MCP and connector token cost on every row',
    ],
  },
  {
    tab: 'skills',
    kanji: '技',
    name: 'Skills',
    title: 'Auto, Manual or Off.',
    body: 'Auto lets the agent pick a skill. Manual is only when you type /name. Off hides it everywhere. Each skill shows what it costs per session. Name only, where the agent sees just the name, is in the right-click menu. Plugin skills are summarised, with Change in Tools.',
    points: [
      'Set for all projects, or for one project',
      'Writes skillOverrides to your user settings or the project’s',
      'Turn all off, with a two-step confirm',
    ],
  },
  {
    tab: 'tools',
    kanji: '絞',
    name: 'Focus',
    title: 'Only the tools you use.',
    body: 'A row at the top of the panel turns Claude, Codex, Antigravity and Cursor on or off in Loadout, and Tools and the project list follow. It changes what Loadout shows and edits, not the tools: a hidden tool keeps running as it is.',
    points: [
      'The main switch on a row leaves hidden tools alone',
      'The project list shows folders with a config file for a tool you’re showing',
      'Choose folder adds any other folder for good',
    ],
    shown: ['Claude Code', 'Codex'],
  },
]

const FIELDS = [
  {
    field: 'enabledPlugins',
    file: '~/.claude/settings.json',
    purpose: 'Plugin on or off by default, with its skills and MCP servers',
  },
  {
    field: 'allowedMcpServers',
    file: '~/.claude/settings.json',
    purpose: 'Servers allowed by default. A project can allow or block its own',
  },
  {
    field: 'skillOverrides',
    file: '~/.claude/settings.json',
    purpose: 'Auto, Manual, Off or Name only, per skill, by default',
  },
  {
    field: 'Project settings',
    file: '.claude/settings.local.json',
    purpose: 'What one project turns on or off, for plugins, servers and skills',
  },
  {
    field: 'Codex',
    file: '~/.codex/config.toml · .codex/config.toml',
    purpose: 'MCP servers, plugins and connectors, by default or per project',
  },
  {
    field: 'Antigravity',
    file: '~/.gemini/config/mcp_config.json · .agents/mcp_config.json',
    purpose: 'MCP servers, by default or per project',
  },
  {
    field: 'Skill links',
    file: '.agents/skills',
    purpose: 'How skills reach Codex, Antigravity and Cursor',
  },
  {
    field: 'disabledMcpServers',
    file: '~/.claude.json, per project',
    purpose: 'Read. Cleared for a server when you turn it on in that project',
    readOnly: true,
  },
]

const HARNESSES = [
  {
    name: 'Claude Code',
    project: 'Plugins, MCP servers, connectors and skills',
    all: 'The same, as the default for every project',
  },
  {
    name: 'Codex',
    project: 'MCP servers, plugins and connectors, in folders you trust in Codex. One click trusts a folder',
    all: 'MCP servers, plugins and connectors',
  },
  {
    name: 'Antigravity',
    project: 'A project can add MCP servers. Global ones stay on',
    all: 'MCP servers and plugins. Plugins are global only',
  },
  {
    name: 'Cursor',
    project: 'Listed, read-only',
    all: 'Listed, read-only. Cursor keeps on and off in its own app state',
  },
]

const HARNESS_NOTES = [
  {
    title: 'One-time switch to default-off',
    body: 'In Claude Code a global block can’t be undone by a project. For per-project control, servers have to be off unless allowed. A banner asks first. What’s on today stays on, your settings are backed up, and Undo and a Restore menu item put them back. Until you switch, a project can turn things off but can’t turn on what’s globally blocked.',
  },
  {
    title: 'Kept out of git',
    body: 'Project files are .claude/settings.local.json, .codex/config.toml, .agents/mcp_config.json and .agents/skills. Loadout adds them to .git/info/exclude, so git status stays clean.',
  },
  {
    title: 'Skills reach the others',
    body: 'Codex, Antigravity and Cursor read skills through links in .agents/skills. Presets save the current set and apply it to another project, from the header’s … menu.',
  },
]

const NOTES = [
  {
    title: 'Atomic writes',
    body: 'Read, change, write to a temp file, swap. A file is never left half-written.',
  },
  {
    title: 'No hidden channel',
    body: 'Claude Code has no local socket to talk to. The clipboard hands over the reload, and you stay in charge of when.',
  },
  {
    title: 'Undo',
    body: 'The footer says what was saved, such as Figma off in tea-house, and offers Undo. Reset all puts a project back on the defaults.',
  },
]

const SPECS = [
  ['Platform', 'macOS 14+'],
  ['Built in', 'SwiftUI'],
  ['Reads', 'Local files and the claude CLI'],
]

const STATS = [
  ['9', 'Swift files'],
  ['1', 'build script'],
  ['0', 'daemons, accounts or patches'],
]

export default function Home() {
  return (
    <>
      <a href="#main" className="skip-link">
        Skip to content
      </a>

      <header className="site-header">
        <div className="shell frame">
          <div className="frame-label header-label">
            <a href="#top" className="wordmark no-underline">
              Loadout
            </a>
            <Cross />
          </div>
          <div className="header-main">
            <nav className="main-nav" aria-label="Sections">
              <a href="#features" className="nav-link no-underline">
                Features
              </a>
              <a href="#details" className="nav-link no-underline">
                How it works
              </a>
              <a href="#install" className="nav-link no-underline">
                Install
              </a>
            </nav>
            <a href={REPO} className="nav-link no-underline">
              GitHub
              <ArrowUpRight size={14} strokeWidth={1.75} aria-hidden />
            </a>
            <ThemeToggle />
          </div>
        </div>
      </header>

      <main id="main" tabIndex={-1}>
        <section id="top" className="band hero">
          <div className="shell frame">
            <aside className="frame-label hero-label">
              <p className="kicker">
                A menu bar app
                <br />
                for coding agents _
              </p>
              <p className="tategaki" lang="ja" aria-hidden>
                装備
              </p>
              <dl className="specs">
                {SPECS.map(([k, v]) => (
                  <div key={k}>
                    <dt>{k}</dt>
                    <dd>{v}</dd>
                  </div>
                ))}
              </dl>
            </aside>

            <div className="frame-main hero-main">
              <div className="hero-copy">
                <h1 className="hero-title">
                  Decide what
                  <br />
                  Claude carries.
                </h1>
                <p className="hero-lede">
                  <span className="dot" aria-hidden />A small macOS panel for
                  the plugins, skills and MCP servers your coding agents load
                  into every session.
                </p>
                <p className="hero-body">
                  Claude Code’s own switches mostly work one project at a time.
                  Loadout sets a default for every project, lets one project
                  differ, and shows which ones do. It also shows the dev
                  servers you forgot were running.
                </p>
                <div className="hero-actions">
                  <a
                    href="#install"
                    className="button button-primary no-underline"
                  >
                    Install
                    <ArrowDown size={15} strokeWidth={1.75} aria-hidden />
                  </a>
                  <a href={REPO} className="button button-quiet no-underline">
                    View source
                    <ArrowUpRight size={15} strokeWidth={1.75} aria-hidden />
                  </a>
                </div>
              </div>

              <figure className="hero-stage">
                <Panel initialTab="tools" className="stage-panel" />
                <figcaption className="stage-caption">
                  The panel, rebuilt for this page. Try the tabs and switches.
                </figcaption>
              </figure>
            </div>
          </div>
        </section>

        <section id="features" className="band">
          <div className="shell frame">
            <BandLabel numeral="01" label="What it does" />
            <div className="frame-main">
              <BandHead title="Three tabs. Every switch has a scope.">
                Click the menu bar icon and the panel opens on Ports. Choose
                which tools to show, pick All projects or one project, and the
                switches below change that scope. Each change saves straight away, says what
                it saved, and copies the reload command for you.
              </BandHead>

              <Tabs
                label="Features"
                items={FEATURES.map((f) => ({
                  id: f.name.toLowerCase(),
                  tab: f.name,
                  panel: (
                    <div className="feature">
                      <div className="feature-copy">
                        <p className="feature-label">
                          <span className="kanji" lang="ja" aria-hidden>
                            {f.kanji}
                          </span>
                          {f.name}
                        </p>
                        <h3>{f.title}</h3>
                        <p className="feature-body">{f.body}</p>
                        <ul className="rows">
                          {f.points.map((p) => (
                            <li key={p}>{p}</li>
                          ))}
                        </ul>
                      </div>
                      <div className="plate">
                        <Panel
                          initialTab={f.tab}
                          initialShown={f.shown}
                          label={`${f.name} tab, recreated`}
                          className="plate-panel"
                        />
                      </div>
                    </div>
                  ),
                }))}
              />
            </div>
          </div>
        </section>

        <section id="details" className="band">
          <div className="shell frame">
            <BandLabel numeral="02" label="How it works" />
            <div className="frame-main">
              <BandHead title="Off by default. On where you want it.">
                Every plugin, skill and MCP server you install is described to
                the model when a session starts. Claude Code can switch each one
                off, but mostly per project. Loadout writes the default for
                every project and the settings files for each project, and
                touches nothing else. No daemon, no account, no patching
                Claude Code.
              </BandHead>

              <Tabs
                label="How it works"
                items={[
                  {
                    id: 'why',
                    tab: 'Why',
                    panel: (
                      <>
                        <p className="panel-lede">
                          Claude Code’s own switches work. Most of them work on
                          one project at a time.
                        </p>
                        <ul className="spec-table">
                          {GAPS.map((gap) => (
                            <li key={gap.command}>
                              <code>{gap.command}</code>
                              <p>{gap.body}</p>
                            </li>
                          ))}
                        </ul>
                      </>
                    ),
                  },
                  {
                    id: 'cost',
                    tab: 'Cost',
                    panel: (
                      <>
                        <p className="panel-lede">
                          One skill, four states. Name only is in the right-click menu. What each adds to every
                          session, before you type anything.
                        </p>
                        <SkillCostFigure />
                      </>
                    ),
                  },
                  {
                    id: 'path',
                    tab: 'Write path',
                    panel: (
                      <>
                        <p className="panel-lede">
                          Loadout reads your config when it opens and writes the
                          same settings files you would edit by hand, for all
                          projects or for one.
                        </p>
                        <FlowFigure />
                        <ul className="notes">
                          {NOTES.map((n) => (
                            <li key={n.title}>
                              <strong>{n.title}</strong>
                              <p>{n.body}</p>
                            </li>
                          ))}
                        </ul>
                      </>
                    ),
                  },
                  {
                    id: 'harnesses',
                    tab: 'Harnesses',
                    panel: (
                      <>
                        <p className="panel-lede">
                          Claude Code gets everything. The others get what
                          their config allows.
                        </p>
                        <div className="table-wrap">
                          <table className="field-table">
                            <caption className="sr-only">
                              What Loadout can control in each tool
                            </caption>
                            <thead>
                              <tr>
                                <th scope="col">Tool</th>
                                <th scope="col">Per project</th>
                                <th scope="col">All projects</th>
                              </tr>
                            </thead>
                            <tbody>
                              {HARNESSES.map((h) => (
                                <tr key={h.name}>
                                  <th scope="row">{h.name}</th>
                                  <td>{h.project}</td>
                                  <td>{h.all}</td>
                                </tr>
                              ))}
                            </tbody>
                          </table>
                        </div>
                        <ul className="notes">
                          {HARNESS_NOTES.map((n) => (
                            <li key={n.title}>
                              <strong>{n.title}</strong>
                              <p>{n.body}</p>
                            </li>
                          ))}
                        </ul>
                      </>
                    ),
                  },
                  {
                    id: 'fields',
                    tab: 'Files',
                    panel: (
                      <div className="table-wrap">
                        <table className="field-table">
                          <caption className="sr-only">
                            Settings files and fields Loadout writes and reads
                          </caption>
                          <thead>
                            <tr>
                              <th scope="col">Field</th>
                              <th scope="col">File</th>
                              <th scope="col">Controls</th>
                            </tr>
                          </thead>
                          <tbody>
                            {FIELDS.map((f) => (
                              <tr key={f.field + f.file}>
                                <td>
                                  <code>{f.field}</code>
                                </td>
                                <td className="field-file">{f.file}</td>
                                <td>{f.purpose}</td>
                              </tr>
                            ))}
                          </tbody>
                        </table>
                      </div>
                    ),
                  },
                ]}
              />
            </div>
          </div>
        </section>

        <section id="install" className="band">
          <div className="shell frame">
            <BandLabel numeral="03" label="Install" />
            <div className="frame-main">
              <div className="install">
                <div className="install-grid">
                  <div>
                    <h2>Install it in a minute.</h2>
                    <p className="install-lede">
                      Download or build it, drop it in Applications, and the backpack
                      appears in your menu bar.
                    </p>
                    <dl className="stats">
                      {STATS.map(([n, label]) => (
                        <div key={label}>
                          <dt>{label}</dt>
                          <dd>{n}</dd>
                        </div>
                      ))}
                    </dl>
                  </div>
                  <div>
                    <pre className="install-code">
                      <code>
                        <span className="c"># clone and build</span>
                        {'\n'}git clone {REPO}.git
                        {'\n'}cd Loadout
                        {'\n'}./build.sh
                        {'\n\n'}
                        <span className="c"># install and open</span>
                        {'\n'}cp -R Loadout.app /Applications/
                        {'\n'}open /Applications/Loadout.app
                      </code>
                    </pre>
                    <ul className="install-reqs">
                      <li>
                        Or download the zip from{' '}
                        <a href={`${REPO}/releases/latest`}>Releases</a>. It isn’t notarized, so macOS blocks the first open: use Open Anyway in System Settings, Privacy &amp; Security
                      </li>
                      <li>macOS 14 Sonoma or later</li>
                      <li>Swift 5.9 toolchain (Xcode or Command Line Tools), to build from source</li>
                      <li>Claude Code, Codex, Antigravity or Cursor, for the settings it manages</li>
                    </ul>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </section>
      </main>

      <footer className="band site-footer">
        <div className="shell frame">
          <div className="frame-label">
            <p className="footer-mark">
              <span lang="ja">装備</span>
              <span>The equipment you choose to carry.</span>
            </p>
            <Cross />
          </div>
          <div className="frame-main">
            <p className="footer-credits">
              Pictograms from IBM Carbon (Apache-2.0). Port detection after{' '}
              <a href="https://github.com/LarsenCundric/port-whisperer">
                port-whisperer
              </a>
              . Not affiliated with Anthropic.
            </p>
          </div>
        </div>
      </footer>
    </>
  )
}

/** A registration mark where the column rule meets a band's top rule. */
function Cross() {
  return <span className="cross" aria-hidden />
}

function BandLabel({ numeral, label }: { numeral: string; label: string }) {
  return (
    <div className="frame-label">
      <Cross />
      <p className="band-numeral" aria-hidden>
        {numeral}
      </p>
      <p className="kicker">{label}</p>
    </div>
  )
}

function BandHead({
  title,
  children,
}: {
  title: string
  children: React.ReactNode
}) {
  return (
    <header className="band-head">
      <h2>{title}</h2>
      <p>{children}</p>
    </header>
  )
}
