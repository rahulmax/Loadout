import { ArrowDown, ArrowUpRight } from 'lucide-react'
import { FlowFigure, SkillCostFigure } from '@/components/figures'
import { MenuBar } from '@/components/menu-bar'
import { Panel } from '@/components/panel/panel'
import type { TabId } from '@/components/panel/panel-data'
import { PictogramTile } from '@/components/pictogram'
import type { PictogramName } from '@/components/pictograms'
import { Seal } from '@/components/seal'
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
  picto: PictogramName
  kanji: string
  name: string
  title: string
  body: string
  points: string[]
}[] = [
  {
    tab: 'ports',
    picto: 'ports',
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
    picto: 'plugins',
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
    picto: 'skills',
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
    picto: 'mcp',
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

export default function Home() {
  return (
    <>
      <a href="#main" className="skip-link">
        Skip to content
      </a>

      <header className="site-header">
        <div className="shell nav-inner">
          <a href="#top" className="wordmark no-underline">
            <Seal size={30} />
            Loadout
          </a>
          <nav className="main-nav" aria-label="Sections">
            <a href="#why" className="nav-link no-underline">
              Why
            </a>
            <a href="#what" className="nav-link no-underline">
              What it does
            </a>
            <a href="#how" className="nav-link no-underline">
              How
            </a>
            <a href="#install" className="nav-link no-underline">
              Install
            </a>
          </nav>
          <div className="nav-tools">
            <a href={REPO} className="nav-link nav-repo no-underline">
              GitHub
              <ArrowUpRight size={14} strokeWidth={1.75} aria-hidden />
            </a>
            <ThemeToggle />
          </div>
        </div>
      </header>

      <main id="main" tabIndex={-1}>
        <section id="top" className="hero">
          <div className="hero-mist" aria-hidden />
          <div className="shell hero-grid">
            <div className="hero-copy">
              <p className="eyebrow">
                <span className="status-dot" aria-hidden />A menu bar app for
                Claude Code
              </p>
              <h1 className="hero-title">
                Decide what
                <br />
                Claude carries.
              </h1>
              <p className="hero-lede">
                Loadout is a small macOS panel for the plugins, skills and MCP
                servers Claude Code loads into every session. It switches them
                where Claude actually reads, so what you turn off stays out of
                context. It also shows the dev servers you forgot were running.
              </p>
              <div className="hero-actions">
                <a
                  href="#install"
                  className="button button-primary no-underline"
                >
                  Build it
                  <ArrowDown size={15} strokeWidth={1.9} aria-hidden />
                </a>
                <a href={REPO} className="button button-quiet no-underline">
                  View source
                  <ArrowUpRight size={15} strokeWidth={1.9} aria-hidden />
                </a>
              </div>
              <ul className="hero-meta">
                <li>macOS 14 or later</li>
                <li>Native SwiftUI</li>
                <li>Local files only</li>
              </ul>
            </div>

            <div className="hero-stage">
              <p className="tategaki" aria-hidden>
                装備<span>soubi · equipment</span>
              </p>
              <div className="desk">
                <MenuBar />
                <Panel initialTab="skills" className="desk-panel" />
              </div>
              <p className="stage-caption">
                The panel, rebuilt for this page. Try the tabs and switches.
              </p>
            </div>
          </div>
        </section>

        <section id="why" className="section">
          <div className="shell">
            <SectionHead
              numeral="壱"
              label="Why it exists"
              title="Off should mean out of context."
            >
              Every plugin, skill and MCP server you install is described to the
              model when a session starts. That spends context before you type a
              word. Claude Code has ways to switch things off, but they don’t
              all do what you’d expect.
            </SectionHead>

            <div className="why-grid">
              <ol className="gap-list">
                {GAPS.map((gap, i) => (
                  <li key={gap.command} className="gap-row">
                    <span className="gap-number">0{i + 1}</span>
                    <div>
                      <code className="gap-command">{gap.command}</code>
                      <p>{gap.body}</p>
                    </div>
                  </li>
                ))}
              </ol>
              <SkillCostFigure />
            </div>

            <p className="pull">
              Loadout sits between what you mean, <em>keep this out</em>, and
              the fields Claude actually reads.
            </p>
          </div>
        </section>

        <section id="what" className="section section-tinted">
          <div className="shell">
            <SectionHead
              numeral="弐"
              label="What it does"
              title="Four tabs. Each one writes a real field."
            >
              Click the menu bar icon and the panel opens on Ports. Every switch
              writes to your config straight away and copies the reload command
              for you.
            </SectionHead>

            <div className="features">
              {FEATURES.map((f, i) => (
                <article
                  key={f.tab}
                  className="feature glow-host"
                  data-flip={i % 2 === 1 || undefined}
                >
                  <div className="feature-copy">
                    <div className="feature-label">
                      <PictogramTile name={f.picto} />
                      <span>
                        <span className="feature-kanji" aria-hidden>
                          {f.kanji}
                        </span>
                        {f.name}
                      </span>
                    </div>
                    <h3>{f.title}</h3>
                    <p>{f.body}</p>
                    <ul className="feature-points">
                      {f.points.map((p) => (
                        <li key={p}>{p}</li>
                      ))}
                    </ul>
                  </div>
                  <div className="feature-shot">
                    <Panel
                      initialTab={f.tab}
                      label={`${f.name} tab, recreated`}
                      className="shot-panel"
                    />
                  </div>
                </article>
              ))}
            </div>
          </div>
        </section>

        <section id="how" className="section">
          <div className="shell">
            <SectionHead
              numeral="参"
              label="How it works"
              title="It edits the files Claude reads. Nothing else."
            >
              No daemon, no account, no patching Claude Code. Loadout reads your
              config when it opens and writes the same fields you would edit by
              hand.
            </SectionHead>

            <FlowFigure />

            <div className="how-grid">
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
              <ul className="notes">
                {NOTES.map((n) => (
                  <li key={n.title}>
                    <strong>{n.title}</strong>
                    <p>{n.body}</p>
                  </li>
                ))}
              </ul>
            </div>
          </div>
        </section>

        <section id="install" className="section section-tinted">
          <div className="shell install-grid">
            <SectionHead
              numeral="肆"
              label="Install"
              title="Build it in a minute."
            >
              Loadout is two Swift files and a build script. Build it, drop it
              in Applications, and the backpack appears in your menu bar.
            </SectionHead>

            <div className="install-card">
              <div className="install-toolbar">
                <span className="install-dots" aria-hidden>
                  <i />
                  <i />
                  <i />
                </span>
                <span>Terminal</span>
              </div>
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
        </section>
      </main>

      <footer className="site-footer">
        <div className="seigaiha" aria-hidden />
        <div className="shell footer-inner">
          <div className="footer-brand">
            <Seal size={26} />
            <div>
              <strong>Loadout</strong>
              <p>
                <span lang="ja">装備</span>. The equipment you choose to carry.
              </p>
            </div>
          </div>
          <p className="footer-credits">
            Pictograms from IBM Carbon (Apache-2.0). Port detection after{' '}
            <a href="https://github.com/LarsenCundric/port-whisperer">
              port-whisperer
            </a>
            . Not affiliated with Anthropic.
          </p>
        </div>
      </footer>
    </>
  )
}

function SectionHead({
  numeral,
  label,
  title,
  children,
}: {
  numeral: string
  label: string
  title: string
  children: React.ReactNode
}) {
  return (
    <header className="section-head">
      <p className="eyebrow">
        <span className="numeral" lang="ja" aria-hidden>
          {numeral}
        </span>
        {label}
      </p>
      <h2>{title}</h2>
      <p className="section-lede">{children}</p>
    </header>
  )
}
