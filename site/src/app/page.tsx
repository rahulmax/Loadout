import { ArrowDown, ArrowUpRight } from 'lucide-react'
import { FlowFigure, SkillCostFigure } from '@/components/figures'
import { Panel } from '@/components/panel/panel'
import type { TabId } from '@/components/panel/panel-data'
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
    body: 'The one block that holds in every project. No UI: you type server names and URLs into settings.json.',
  },
]

const FEATURES: {
  tab: TabId
  kanji: string
  name: string
  title: string
  body: string
  points: string[]
}[] = [
  {
    tab: 'ports',
    kanji: '港',
    name: 'Ports',
    title: 'See what’s running. Stop what isn’t needed.',
    body: 'Every dev server listening on your Mac, with its project folder, framework, PID and uptime. A live probe marks each one as responding or not.',
    points: [
      'Restart relaunches the same command in the same folder',
      'Kill sends SIGTERM, then SIGKILL if it hangs on',
      'Kill all asks twice',
    ],
  },
  {
    tab: 'plugins',
    kanji: '具',
    name: 'Plugins',
    title: 'One switch per plugin.',
    body: 'Every installed plugin with its version and marketplace. The switch writes enabledPlugins. Off takes the plugin’s skills, agents and MCP servers with it.',
    points: [
      'Reads installed_plugins.json',
      'New sessions pick up the change',
      'Running ones reload with one paste',
    ],
  },
  {
    tab: 'skills',
    kanji: '技',
    name: 'Skills',
    title: 'Four states, one tap each.',
    body: 'On, Name, Slash or Off for every skill in ~/.claude/skills, set once for every project. Plugin skills are listed with their plugin. Claude Code ignores per-skill settings for them, so the plugin switch is the one that counts.',
    points: [
      'Writes skillOverrides in your user settings',
      'A folder marker shows projects that set their own state',
      'Turn all off, with a two-step confirm',
    ],
  },
  {
    tab: 'mcp',
    kanji: '繋',
    name: 'MCP',
    title: 'Off in every project, not just this one.',
    body: 'Local servers and claude.ai integrations both go on deniedMcpServers, the block list Claude Code checks in every project. Each server’s config stays where it is, so turning it back on is one click.',
    points: [
      'Flags servers that /mcp turned off in some projects',
      'Blocked integrations stay listed',
      'Live status from claude mcp list',
    ],
  },
]

const FIELDS = [
  {
    field: 'enabledPlugins',
    file: '~/.claude/settings.json',
    purpose: 'Plugin on or off, with its skills and MCP servers',
  },
  {
    field: 'skillOverrides',
    file: '~/.claude/settings.json',
    purpose: 'on · name-only · user-invocable-only · off, per user skill',
  },
  {
    field: 'deniedMcpServers',
    file: '~/.claude/settings.json',
    purpose: 'Servers blocked in every project, by name or URL',
  },
  {
    field: 'disabledMcpServers',
    file: '~/.claude.json, per project',
    purpose: 'Read only. What /mcp turned off in one project',
    readOnly: true,
  },
  {
    field: 'skillOverrides',
    file: '.claude/settings.local.json, per project',
    purpose: 'Read only. What /skills set in one project',
    readOnly: true,
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
    title: 'No undo',
    body: 'Toggles write straight away. To revert, toggle back. The two bulk actions ask twice.',
  },
]

const SPECS = [
  ['Platform', 'macOS 14+'],
  ['Built in', 'SwiftUI'],
  ['Reads', 'Local files only'],
]

const STATS = [
  ['2', 'Swift files'],
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
                for Claude Code _
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
                  the plugins, skills and MCP servers Claude Code loads into
                  every session.
                </p>
                <p className="hero-body">
                  Claude Code’s own switches work one project at a time. Loadout
                  sets them once for every project, and shows where a project
                  keeps its own. It also shows the dev servers you forgot were
                  running.
                </p>
                <div className="hero-actions">
                  <a
                    href="#install"
                    className="button button-primary no-underline"
                  >
                    Build it
                    <ArrowDown size={15} strokeWidth={1.75} aria-hidden />
                  </a>
                  <a href={REPO} className="button button-quiet no-underline">
                    View source
                    <ArrowUpRight size={15} strokeWidth={1.75} aria-hidden />
                  </a>
                </div>
              </div>

              <figure className="hero-stage">
                <Panel initialTab="skills" className="stage-panel" />
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
              <BandHead title="Four tabs. Every switch is global.">
                Click the menu bar icon and the panel opens on Ports. Every
                switch writes your user settings straight away and copies the
                reload command for you.
              </BandHead>

              <Tabs
                label="Features"
                items={FEATURES.map((f) => ({
                  id: f.tab,
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
              <BandHead title="Off should mean off everywhere.">
                Every plugin, skill and MCP server you install is described to
                the model when a session starts. Claude Code can switch each one
                off, but mostly per project. Loadout writes the user-level
                fields, reads the project ones, and touches nothing else. No
                daemon, no account, no patching Claude Code.
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
                          One skill, four states. What each adds to every
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
                          same user-level fields you would edit by hand.
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
                    id: 'fields',
                    tab: 'Fields',
                    panel: (
                      <div className="table-wrap">
                        <table className="field-table">
                          <caption className="sr-only">
                            Settings fields Loadout writes and reads
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
                    <h2>Build it in a minute.</h2>
                    <p className="install-lede">
                      Build it, drop it in Applications, and the backpack
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
                      <li>macOS 14 Sonoma or later</li>
                      <li>Swift 5.9 toolchain (Xcode or Command Line Tools)</li>
                      <li>Claude Code, for the settings it manages</li>
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
