'use client'

import {
  Calendar,
  CheckCircle2,
  ClipboardList,
  Copy,
  Folder,
  FolderOpen,
  Globe,
  Hash,
  Mail,
  PenTool,
  Power,
  Puzzle,
  Radio,
  RotateCw,
  Server,
  Sparkles,
  SquareTerminal,
  X,
  type LucideIcon,
} from 'lucide-react'
import { useEffect, useRef, useState } from 'react'
import { Pictogram } from '../pictogram'
import {
  AUTHOR_LOCK_TIP,
  HOSTED_MCPS,
  LOCAL_MCPS,
  PLUGIN_SKILL_NOTE,
  PLUGIN_SKILLS,
  PLUGINS,
  PORTS,
  SKILL_STATES,
  USER_SKILLS,
  type HostedMcp,
  type SkillState,
  type TabId,
} from './panel-data'

const TABS: { id: TabId; label: string; icon: LucideIcon }[] = [
  { id: 'ports', label: 'Ports', icon: Radio },
  { id: 'plugins', label: 'Plugins', icon: Puzzle },
  { id: 'skills', label: 'Skills', icon: Sparkles },
  { id: 'mcp', label: 'MCP', icon: Server },
]

const HOSTED_ICONS: Record<HostedMcp['icon'], LucideIcon> = {
  figma: PenTool,
  gmail: Mail,
  calendar: Calendar,
  drive: Folder,
  miro: Copy,
  slack: Hash,
}

/**
 * The Loadout menu bar panel, rebuilt in HTML from the SwiftUI views. It is a
 * working model: tabs switch, switches flip, skill states move, and every
 * change "copies" /reload-plugins the way the app does. Nothing persists.
 */
export function Panel({
  initialTab = 'ports',
  label = 'Loadout panel, recreated',
  className = '',
}: {
  initialTab?: TabId
  label?: string
  className?: string
}) {
  const [tab, setTab] = useState<TabId>(initialTab)
  const [plugins, setPlugins] = useState(() => PLUGINS.map((p) => p.enabled))
  const [skills, setSkills] = useState<Record<string, SkillState>>(() =>
    Object.fromEntries(USER_SKILLS.map((s) => [s.name, s.state])),
  )
  const [local, setLocal] = useState(() => LOCAL_MCPS.map((m) => m.enabled))
  const [hosted, setHosted] = useState(() => HOSTED_MCPS.map((m) => m.allowed))
  const [copied, setCopied] = useState(false)
  const timer = useRef<ReturnType<typeof setTimeout>>(undefined)

  useEffect(() => () => clearTimeout(timer.current), [])

  const didWrite = () => {
    setCopied(true)
    clearTimeout(timer.current)
    timer.current = setTimeout(() => setCopied(false), 2200)
  }

  const flip = (list: boolean[], i: number) =>
    list.map((v, j) => (j === i ? !v : v))

  const skillValues = Object.values(skills)
  const counts: Record<TabId, number> = {
    ports: PORTS.length,
    plugins: PLUGINS.length,
    skills: skillValues.length + PLUGIN_SKILLS.length,
    mcp: LOCAL_MCPS.length + HOSTED_MCPS.length,
  }

  return (
    <div className={`mac-panel ${className}`} role="group" aria-label={label}>
      <div className="mac-head">
        <span className="mac-appicon" aria-hidden>
          <Pictogram name="backpack" />
        </span>
        <span className="mac-title">Loadout</span>
        <span className="mac-icon-button" aria-hidden>
          <RotateCw size={14} strokeWidth={1.8} />
        </span>
      </div>

      <div className="mac-tabs" role="tablist" aria-label="Panel tabs">
        {TABS.map(({ id, label: tabLabel, icon: Icon }) => (
          <button
            key={id}
            type="button"
            role="tab"
            aria-selected={tab === id}
            className="mac-tab"
            onClick={() => setTab(id)}
          >
            <Icon size={13} strokeWidth={1.8} aria-hidden />
            {tabLabel}
            <span className="mac-count">{counts[id]}</span>
          </button>
        ))}
      </div>

      <div className="mac-body" role="tabpanel">
        {tab === 'ports' && <PortsView />}

        {tab === 'plugins' && (
          <>
            <Toolbar
              summary={`${plugins.filter(Boolean).length} of ${PLUGINS.length} enabled`}
            />
            <ul className="mac-list">
              {PLUGINS.map((p, i) => (
                <li key={p.name} className="mac-row">
                  <span className="mac-letter" aria-hidden>
                    {p.name[0].toUpperCase()}
                  </span>
                  <span className="mac-row-text">
                    <span
                      className="mac-name"
                      data-dim={!plugins[i] || undefined}
                    >
                      {p.name}
                    </span>
                    <span className="mac-sub">
                      {p.version} · {p.marketplace}
                    </span>
                  </span>
                  <Switch
                    on={plugins[i]}
                    label={p.name}
                    onChange={() => {
                      setPlugins(flip(plugins, i))
                      didWrite()
                    }}
                  />
                </li>
              ))}
            </ul>
          </>
        )}

        {tab === 'skills' && (
          <>
            <Toolbar
              summary={skillSummary(skillValues, PLUGIN_SKILLS.length)}
              action="Turn all off"
            />
            <SectionLabel name="User" count={USER_SKILLS.length} />
            <ul className="mac-list">
              {USER_SKILLS.map((s) => (
                <li key={s.name} className="mac-row mac-row-skill">
                  <span
                    className="mac-name"
                    data-dim={skills[s.name] === 'off' || undefined}
                  >
                    {s.name}
                  </span>
                  {s.projects ? (
                    <Marker
                      label={`${s.projects} projects`}
                      tip="These projects set their own state, which wins over this one"
                    />
                  ) : null}
                  <Segmented
                    value={skills[s.name]}
                    label={s.name}
                    allowed={
                      s.authorLocked
                        ? ['user-invocable-only', 'off']
                        : undefined
                    }
                    onChange={(state) => {
                      setSkills({ ...skills, [s.name]: state })
                      didWrite()
                    }}
                  />
                </li>
              ))}
            </ul>
            <SectionLabel name="Plugins" count={PLUGIN_SKILLS.length} />
            <ul className="mac-list">
              {PLUGIN_SKILLS.map((s) => (
                <li key={s.name} className="mac-row mac-row-skill">
                  <span className="mac-row-text">
                    <span
                      className="mac-name"
                      data-dim={!plugins[s.plugin] || undefined}
                    >
                      {s.name}
                    </span>
                    <span className="mac-sub">{PLUGINS[s.plugin].name}</span>
                  </span>
                  <span
                    className="mac-lock"
                    title="Plugin skills ignore skillOverrides. Use the plugin's switch in Plugins."
                  >
                    {plugins[s.plugin] ? 'On with plugin' : 'Off with plugin'}
                  </span>
                </li>
              ))}
            </ul>
            <p className="mac-note">{PLUGIN_SKILL_NOTE}</p>
          </>
        )}

        {tab === 'mcp' && (
          <>
            <Toolbar
              summary={`${local.filter(Boolean).length + hosted.filter(Boolean).length} of ${counts.mcp} allowed`}
            />
            <SectionLabel name="User" count={LOCAL_MCPS.length} />
            <ul className="mac-list">
              {LOCAL_MCPS.map((m, i) => (
                <li key={m.name} className="mac-row">
                  <span className="mac-glyph" aria-hidden>
                    {m.transport === 'HTTP' ? (
                      <Globe size={15} strokeWidth={1.6} />
                    ) : (
                      <SquareTerminal size={15} strokeWidth={1.6} />
                    )}
                  </span>
                  <span className="mac-row-text">
                    <span
                      className="mac-name"
                      data-dim={!local[i] || undefined}
                    >
                      {m.name}
                    </span>
                    <span className="mac-sub mac-mono">
                      <span className="mac-transport">{m.transport}</span>
                      {m.target}
                    </span>
                  </span>
                  {local[i] && m.offIn ? (
                    <Marker
                      label={`Off in ${m.offIn}`}
                      tip="Turned off with /mcp in some projects"
                    />
                  ) : null}
                  <Switch
                    on={local[i]}
                    label={m.name}
                    onChange={() => {
                      setLocal(flip(local, i))
                      didWrite()
                    }}
                  />
                </li>
              ))}
            </ul>
            <SectionLabel name="claude.ai" count={HOSTED_MCPS.length} />
            <ul className="mac-list">
              {HOSTED_MCPS.map((m, i) => {
                const Icon = HOSTED_ICONS[m.icon]
                return (
                  <li key={m.name} className="mac-row">
                    <span className="mac-glyph" aria-hidden>
                      <Icon size={15} strokeWidth={1.6} />
                    </span>
                    <span className="mac-row-text">
                      <span
                        className="mac-name"
                        data-dim={!hosted[i] || undefined}
                      >
                        {m.name}
                      </span>
                      <span className="mac-sub mac-status">
                        <span
                          className="mac-dot"
                          data-state={hosted[i] ? 'ok' : 'idle'}
                        />
                        {hosted[i] ? 'Connected' : 'Blocked locally'}
                      </span>
                    </span>
                    {hosted[i] && m.offIn ? (
                      <Marker
                        label={`Off in ${m.offIn}`}
                        tip="Turned off with /mcp in some projects"
                      />
                    ) : null}
                    <Switch
                      on={hosted[i]}
                      label={m.name}
                      onChange={() => {
                        setHosted(flip(hosted, i))
                        didWrite()
                      }}
                    />
                  </li>
                )
              })}
            </ul>
          </>
        )}
      </div>

      <div className="mac-foot" aria-live="polite">
        {copied ? (
          <CheckCircle2 size={12} className="mac-foot-ok" aria-hidden />
        ) : (
          <ClipboardList size={12} aria-hidden />
        )}
        <span>
          {copied ? 'Copied' : 'Changes copy'} <code>/reload-plugins</code>
          {copied && ' · paste in Claude'}
        </span>
        <span className="mac-quit">
          Quit <kbd>⌘Q</kbd>
        </span>
      </div>
    </div>
  )
}

/**
 * "12 on · 3 trimmed · 8 off · 20 from plugins", skipping empty buckets, as
 * the app does.
 */
function skillSummary(states: SkillState[], fromPlugins: number) {
  const on = states.filter((s) => s === 'on').length
  const off = states.filter((s) => s === 'off').length
  const trimmed = states.length - on - off
  return [
    on && `${on} on`,
    trimmed && `${trimmed} trimmed`,
    off && `${off} off`,
    fromPlugins && `${fromPlugins} from plugins`,
  ]
    .filter(Boolean)
    .join(' · ')
}

function PortsView() {
  return (
    <>
      <Toolbar summary={`${PORTS.length} listening`} action="Kill all" />
      <ul className="mac-list mac-ports">
        {PORTS.map((p) => (
          <li key={p.port} className="mac-port">
            <span
              className="mac-dot"
              data-state={p.healthy ? 'ok' : 'down'}
              title={p.healthy ? 'Responding' : 'Not responding'}
            />
            <span className="mac-row-text">
              <span className="mac-port-line">
                <span className="mac-mono mac-port-host">
                  localhost:<b>{p.port}</b>
                </span>
                <span className="mac-chip">{p.framework}</span>
              </span>
              <span className="mac-port-path">{p.path}</span>
              <span className="mac-port-meta">
                PID {p.pid} · {p.process} · up {p.uptime}
              </span>
            </span>
            <span className="mac-port-actions" aria-hidden>
              <RotateCw size={13} strokeWidth={1.8} />
              <span className="mac-pill">Kill</span>
            </span>
          </li>
        ))}
      </ul>
    </>
  )
}

function Toolbar({ summary, action }: { summary: string; action?: string }) {
  return (
    <div className="mac-toolbar">
      <span>{summary}</span>
      {action && (
        <span className="mac-pill mac-pill-icon" aria-hidden>
          {action === 'Kill all' ? (
            <X size={11} strokeWidth={2.2} />
          ) : (
            <Power size={11} strokeWidth={2.2} />
          )}
          {action}
        </span>
      )}
    </div>
  )
}

function SectionLabel({ name, count }: { name: string; count: number }) {
  return (
    <div className="mac-section">
      {name} <span>{count}</span>
    </div>
  )
}

function Switch({
  on,
  label,
  onChange,
}: {
  on: boolean
  label: string
  onChange: () => void
}) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={on}
      aria-label={label}
      className="mac-switch"
      onClick={onChange}
    />
  )
}

/** Quiet note that some projects differ, with the detail in a tooltip. */
function Marker({ label, tip }: { label: string; tip: string }) {
  return (
    <span className="mac-marker" title={tip}>
      <FolderOpen size={11} strokeWidth={1.8} aria-hidden />
      {label}
    </span>
  )
}

function Segmented({
  value,
  label,
  allowed,
  onChange,
}: {
  value: SkillState
  label: string
  allowed?: SkillState[]
  onChange: (state: SkillState) => void
}) {
  const index = SKILL_STATES.findIndex((s) => s.id === value)
  return (
    <span
      className="mac-seg"
      role="radiogroup"
      aria-label={label}
      data-state={value}
      style={{ '--i': index } as React.CSSProperties}
    >
      <span className="mac-seg-thumb" aria-hidden />
      {SKILL_STATES.map((s) => (
        <button
          key={s.id}
          type="button"
          role="radio"
          aria-checked={value === s.id}
          disabled={allowed && !allowed.includes(s.id)}
          title={allowed && !allowed.includes(s.id) ? AUTHOR_LOCK_TIP : s.tip}
          onClick={() => onChange(s.id)}
        >
          {s.label}
        </button>
      ))}
    </span>
  )
}
