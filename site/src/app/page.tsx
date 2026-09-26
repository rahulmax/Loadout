import { ArrowDown, ArrowUpRight } from 'lucide-react'
import { FlowFigure, SkillCostFigure } from '@/components/figures'
import { Panel } from '@/components/panel/panel'
import type { TabId } from '@/components/panel/panel-data'
import { Tabs } from '@/components/tabs'
import { ThemeToggle } from '@/components/theme-toggle'

const REPO = 'https://github.com/rahulmax/Loadout'

const GAPS = [
  {
    command: '/plugin disable',
    body: 'Skills and agents go. A plugin’s bundled MCP servers can stay in mcpServers and keep advertising their tools.',
  },
  {
    command: '/mcp disconnect',
    body: 'Not a block. Tools can come back on reconnect, and nothing stops them loading next session.',
  },
  {
    command: 'skillOverrides',
    body: 'The biggest saving has no UI. Name-only and slash-only mean hand-editing settings.json.',
  },
  {
    command: '~/.claude/skills/',
    body: 'Your own skills can’t be reached from claude plugin commands at all.',
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
    body: 'Every installed plugin with its version and marketplace. The switch writes enabledPlugins, the field Claude Code reads when a session starts.',
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
    body: 'On, Name, Slash or Off for every skill: the ones plugins bring and the ones in your own ~/.claude/skills. All four states stay visible, so nothing hides behind a menu.',
    points: [
      'Writes skillOverrides',
      'Only On takes the accent. Reduced states stay quiet',
      'Turn all off, with a two-step confirm',
    ],
  },
  {
    tab: 'mcp',
    kanji: '繋',
    name: 'MCP',
    title: 'Blocked, not just disconnected.',
    body: 'Local servers move between mcpServers and a parked list in ~/.claude.json. claude.ai integrations go on deniedMcpServers, the one field that actually keeps them out.',
    points: [
      'Blocked integrations stay listed, so you can turn them back on',
      'Live status from claude mcp list',
      'Transport and command shown for each local server',
    ],
  },
]

const FIELDS = [
  ['enabledPlugins', '~/.claude/settings.json', 'Plugin on or off'],
  [
    'skillOverrides',
    '~/.claude/settings.json',
    'on · name-only · user-invocable-only · off',
  ],
  [
    'deniedMcpServers',
    '~/.claude/settings.json',
    'claude.ai integrations to block',
  ],
  ['mcpServers', '~/.claude.json', 'Local MCP servers that load'],
  ['_disabledMcpServers', '~/.claude.json', 'Local servers parked by Loadout'],
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
                <h1 className="hero-title">Decide what Claude carries.</h1>
                <p className="hero-lede">
                  <span className="dot" aria-hidden />A small macOS panel for
                  the plugins, skills and MCP servers Claude Code loads into
                  every session.
                </p>
                <p className="hero-body">
                  It switches them where Claude actually reads, so what you turn
                  off stays out of context. It also shows the dev servers you
                  forgot were running.
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
              <BandHead title="Four tabs. Each one writes a real field.">
                Click the menu bar icon and the panel opens on Ports. Every
                switch writes to your config straight away and copies the reload
                command for you.
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
              <BandHead title="Off should mean out of context.">
                Every plugin, skill and MCP server you install is described to
                the model when a session starts. Loadout edits the fields Claude
                reads, and nothing else. No daemon, no account, no patching
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
                          Claude Code has ways to switch things off, but they
                          don’t all do what you’d expect.
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
                          One skill, four states. What each adds to context,
                          every session.
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
                          same fields you would edit by hand.
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
                            Settings fields Loadout writes
                          </caption>
                          <thead>
                            <tr>
                              <th scope="col">Field</th>
                              <th scope="col">File</th>
                              <th scope="col">Controls</th>
                            </tr>
                          </thead>
                          <tbody>
                            {FIELDS.map(([field, file, purpose]) => (
                              <tr key={field}>
                                <td>
                                  <code>{field}</code>
                                </td>
                                <td className="field-file">{file}</td>
                                <td>{purpose}</td>
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
