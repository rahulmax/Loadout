'use client'

import {
  Check,
  CheckCircle2,
  ChevronRight,
  Folder,
  FolderPlus,
  Layers,
  Lock,
  Power,
  RotateCw,
  Search,
  Sparkles,
  Square,
  Undo2,
  Wrench,
  X,
  ChevronsUpDown,
  type LucideIcon,
} from 'lucide-react'
import { useEffect, useRef, useState } from 'react'
import { Pictogram } from '../pictogram'
import {
  AUTHOR_LOCK_TIP,
  PORTS,
  HARNESSES,
  PROJECTS,
  SERVICES,
  SERVICE_OVERRIDES,
  SKILL_LEGEND,
  SKILL_OVERRIDES,
  SKILL_STATES,
  USER_SKILLS,
  formatTokens,
  type Port,
  type Scope,
  type Service,
  type Skill,
  type SkillState,
  type TabId,
} from './panel-data'
import type { Harness } from './panel-data'

const TABS: { id: TabId; label: string; icon: LucideIcon }[] = [
  { id: 'tools', label: 'Tools', icon: Wrench },
  { id: 'skills', label: 'Skills', icon: Sparkles },
]

/** Everything a switch can change. One snapshot per undo step. */
interface Data {
  svc: Record<string, boolean[]>
  svcOver: Record<string, Record<string, boolean[]>>
  skill: Record<string, SkillState>
  skillOver: Record<string, Record<string, SkillState>>
}

interface Note {
  text: string
  reload: boolean
}

const initialData = (): Data => ({
  svc: Object.fromEntries(SERVICES.map((s) => [s.id, [...s.on]])),
  svcOver: structuredClone(SERVICE_OVERRIDES),
  skill: Object.fromEntries(USER_SKILLS.map((s) => [s.name, s.state])),
  skillOver: structuredClone(SKILL_OVERRIDES),
})

type MainState = 'on' | 'off' | 'mixed' | 'locked-on' | 'locked-off'

function mainState(service: Service, values: boolean[]): MainState {
  const open = service.controls
    .map((c, i) => (c.lock ? null : values[i]))
    .filter((v): v is boolean => v !== null)
  if (open.length === 0) return values.some(Boolean) ? 'locked-on' : 'locked-off'
  if (open.every(Boolean)) return 'on'
  if (open.some(Boolean)) return 'mixed'
  return 'off'
}

/**
 * The Loadout menu bar panel, rebuilt in HTML from the SwiftUI views. It is a
 * working model: pick a project, flip switches, move skill states, stop a
 * server, undo. The footer says what was saved. Nothing persists.
 */
export function Panel({
  initialShown,
  initialTab = 'tools',
  label = 'Loadout panel, recreated',
  className = '',
}: {
  initialTab?: TabId
  /** Tools shown at first. All of them unless a section is making a point. */
  initialShown?: Harness[]
  label?: string
  className?: string
}) {
  const [tab, setTab] = useState<TabId>(initialTab)
  const [shown, setShown] = useState<Harness[]>(
    initialShown ?? HARNESSES.map((h) => h.id),
  )
  const [scope, setScope] = useState<Scope>(null)
  const [picking, setPicking] = useState(false)
  const [data, setData] = useState<Data>(initialData)
  const [undo, setUndo] = useState<{ data: Data; note: Note }[]>([])
  const [note, setNote] = useState<Note | null>(null)
  const [ports, setPorts] = useState<Port[]>(PORTS)
  const [expanded, setExpanded] = useState<string[]>([])

  const project = PROJECTS.find((p) => p.id === scope) ?? null
  const where = project ? `in ${project.name}` : 'by default'

  const commit = (next: Data, text: string, reload = true) => {
    setUndo([...undo, { data, note: { text, reload } }])
    setData(next)
    setNote({ text, reload })
  }

  const pickScope = (next: Scope) => {
    setScope(next)
    setPicking(false)
  }

  // Service state for the current scope.
  const svcValues = (s: Service) =>
    (scope && data.svcOver[scope]?.[s.id]) || data.svc[s.id]
  const svcSetHere = (s: Service) => !!scope && !!data.svcOver[scope]?.[s.id]
  const svcProjects = (s: Service) =>
    scope
      ? []
      : PROJECTS.filter((p) => data.svcOver[p.id]?.[s.id]).map((p) => p.name)

  const writeService = (s: Service, values: boolean[], text: string) => {
    if (scope) {
      commit(
        {
          ...data,
          svcOver: {
            ...data.svcOver,
            [scope]: { ...data.svcOver[scope], [s.id]: values },
          },
        },
        text,
      )
    } else {
      commit({ ...data, svc: { ...data.svc, [s.id]: values } }, text)
    }
  }

  const setService = (s: Service, on: boolean) => {
    const cur = svcValues(s)
    writeService(
      s,
      s.controls.map((c, i) =>
        c.lock || !shown.includes(c.harness) ? cur[i] : on,
      ),
      `${s.name} ${on ? 'on' : 'off'} ${where}`,
    )
  }

  const setControl = (s: Service, index: number, on: boolean) => {
    const values = svcValues(s).map((v, i) => (i === index ? on : v))
    writeService(
      s,
      values,
      `${s.name} ${on ? 'on' : 'off'} in ${s.controls[index].harness} ${where}`,
    )
  }

  const resetService = (s: Service) => {
    if (!scope) return
    const { [s.id]: _removed, ...rest } = data.svcOver[scope]
    void _removed
    commit(
      { ...data, svcOver: { ...data.svcOver, [scope]: rest } },
      `${s.name} back to the default`,
    )
  }

  // Skill state for the current scope.
  const skillValue = (k: Skill): SkillState =>
    (scope && data.skillOver[scope]?.[k.name]) || data.skill[k.name]
  const skillSetHere = (k: Skill) =>
    !!scope && !!data.skillOver[scope]?.[k.name]
  const skillProjects = (k: Skill) =>
    scope
      ? []
      : PROJECTS.filter((p) => data.skillOver[p.id]?.[k.name]).map(
          (p) => `${p.name}: ${labelOf(data.skillOver[p.id][k.name])}`,
        )

  const writeSkills = (changes: Record<string, SkillState>, text: string) => {
    if (scope) {
      commit(
        {
          ...data,
          skillOver: {
            ...data.skillOver,
            [scope]: { ...data.skillOver[scope], ...changes },
          },
        },
        text,
      )
    } else {
      commit({ ...data, skill: { ...data.skill, ...changes } }, text)
    }
  }

  const setSkill = (k: Skill, state: SkillState) =>
    writeSkills({ [k.name]: state }, `${k.name} ${labelOf(state)} ${where}`)

  const resetSkill = (k: Skill) => {
    if (!scope) return
    const { [k.name]: _removed, ...rest } = data.skillOver[scope]
    void _removed
    commit(
      { ...data, skillOver: { ...data.skillOver, [scope]: rest } },
      `${k.name} back to the default`,
    )
  }

  const turnOffAll = () =>
    writeSkills(
      Object.fromEntries(USER_SKILLS.map((k) => [k.name, 'off' as const])),
      `All skills off ${where}`,
    )

  const setHereCount = scope
    ? Object.keys(data.svcOver[scope] ?? {}).length +
      Object.keys(data.skillOver[scope] ?? {}).length
    : 0

  const resetAll = () => {
    if (!project) return
    commit(
      {
        ...data,
        svcOver: { ...data.svcOver, [project.id]: {} },
        skillOver: { ...data.skillOver, [project.id]: {} },
      },
      `${project.name} back to the defaults`,
    )
  }

  const undoLast = () => {
    const last = undo[undo.length - 1]
    if (!last) return
    setData(last.data)
    setUndo(undo.slice(0, -1))
    setNote({ text: `Undid: ${last.note.text}`, reload: last.note.reload })
  }

  const kill = (list: Port[]) => {
    const gone = new Set(list.map((p) => p.port))
    setPorts(ports.filter((p) => !gone.has(p.port)))
    setNote({
      text:
        list.length === 1
          ? `Stopped localhost:${list[0].port}`
          : `Stopped ${list.length} servers`,
      reload: false,
    })
  }

  const restart = (p: Port) =>
    setNote({ text: `Restarted localhost:${p.port}`, reload: false })

  const counts: Record<TabId, number> = {
    tools: SERVICES.filter((s) => s.controls.some((c) => shown.includes(c.harness)))
      .length,
    skills:
      USER_SKILLS.length +
      (shown.includes('Claude Code')
        ? SERVICES.filter((s) => s.pluginSkills).length
        : 0),
  }

  return (
    <div className={`mac-panel ${className}`} role="group" aria-label={label}>
      <div className="mac-head">
        <span className="mac-appicon" aria-hidden>
          <Pictogram name="backpack" />
        </span>
        <span className="mac-title">Loadout</span>
        <span
          className="mac-icon-button"
          title="Presets and restore"
          aria-hidden
        >
          <RotateCw size={14} strokeWidth={1.8} />
        </span>
      </div>

      <PortsSection ports={ports} onKill={kill} onRestart={restart} />

      <div className="mac-harnesses" role="group" aria-label="Tools to show">
        <span className="mac-show">Show</span>
        {HARNESSES.map(({ id, label: name }) => {
          const on = shown.includes(id)
          return (
            <button
              key={id}
              type="button"
              className="mac-tool"
              aria-pressed={on}
              disabled={on && shown.length === 1}
              title={
                on && shown.length === 1
                  ? 'At least one tool has to stay on.'
                  : 'Hidden tools keep working. Loadout just won’t show or change them.'
              }
              onClick={() =>
                setShown(on ? shown.filter((h) => h !== id) : [...shown, id])
              }
            >
              <Check size={10} strokeWidth={3} aria-hidden />
              {name}
            </button>
          )
        })}
      </div>

      <div className="mac-scope">
        <button
          type="button"
          className="mac-picker"
          aria-expanded={picking}
          aria-label={`Changes apply to ${project?.name ?? 'All projects'}`}
          onClick={() => setPicking(!picking)}
        >
          {project ? (
            <Folder size={13} strokeWidth={1.8} aria-hidden />
          ) : (
            <Layers size={13} strokeWidth={1.8} aria-hidden />
          )}
          <span className="mac-row-text">
            <span className="mac-sub">Changes apply to</span>
            <span className="mac-picker-line">
              <span className="mac-name">{project?.name ?? 'All projects'}</span>
              {project && <span className="mac-sub">{project.path}</span>}
            </span>
          </span>
          <ChevronsUpDown size={12} strokeWidth={2} aria-hidden />
        </button>
        {picking ? (
          <ProjectMenu
            scope={scope}
            shown={shown}
            onPick={pickScope}
            onClose={() => setPicking(false)}
          />
        ) : (
          // All projects needs no line: the picker's own label says it.
          project && (
            <div className="mac-scope-line">
              <span>
                {setHereCount === 0
                  ? 'Everything follows the default.'
                  : `${setHereCount} overridden here, the rest follow the default.`}
              </span>
              {setHereCount > 0 && (
                <TwoStep
                  idle={`Reset ${setHereCount} to default`}
                  confirm="Confirm reset"
                  icon={Undo2}
                  onConfirm={resetAll}
                />
              )}
            </div>
          )
        )}
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
        {tab === 'tools' && (
          <ToolsView
            shown={shown}
            values={svcValues}
            setHere={svcSetHere}
            projects={svcProjects}
            expanded={expanded}
            onExpand={(id) =>
              setExpanded(
                expanded.includes(id)
                  ? expanded.filter((e) => e !== id)
                  : [...expanded, id],
              )
            }
            onService={setService}
            onControl={setControl}
            onReset={resetService}
          />
        )}
        {tab === 'skills' && (
          <SkillsView
            shown={shown}
            value={skillValue}
            setHere={skillSetHere}
            projects={skillProjects}
            values={svcValues}
            onSkill={setSkill}
            onReset={resetSkill}
            onTurnOffAll={turnOffAll}
            onOpenTools={() => setTab('tools')}
          />
        )}
      </div>

      <div className="mac-foot" aria-live="polite">
        {/* Empty until there's a change to report. */}
        {note && <CheckCircle2 size={12} className="mac-foot-ok" aria-hidden />}
        <span className="mac-foot-text">
          {note && (
            <>
              <span className="mac-foot-note">{note.text}</span>
              {note.reload && (
                <span>
                  <code>/reload-plugins</code> copied
                </span>
              )}
            </>
          )}
        </span>
        {undo.length > 0 && (
          <button type="button" className="mac-pill" onClick={undoLast}>
            Undo
          </button>
        )}
        <span className="mac-quit">
          Quit <kbd>⌘Q</kbd>
        </span>
      </div>
    </div>
  )
}

function labelOf(state: SkillState) {
  return SKILL_STATES.find((s) => s.id === state)?.label ?? state
}

function ProjectMenu({
  shown,
  scope,
  onPick,
  onClose,
}: {
  shown: Harness[]
  scope: Scope
  onPick: (id: Scope) => void
  onClose: () => void
}) {
  const [query, setQuery] = useState('')
  const term = query.trim().toLowerCase()
  const listed = PROJECTS.filter((p) => p.tools.some((t) => shown.includes(t)))
  const matches = listed.filter((p) => p.name.includes(term))
  const showAll = !term || 'all projects'.includes(term)

  return (
    <div
      className="mac-menu"
      onKeyDown={(e) => e.key === 'Escape' && onClose()}
    >
      <label className="mac-search">
        <Search size={12} strokeWidth={1.8} aria-hidden />
        <input
          autoFocus
          type="text"
          value={query}
          placeholder={`Search ${listed.length} projects`}
          aria-label="Search projects"
          onChange={(e) => setQuery(e.target.value)}
        />
      </label>
      <ul className="mac-menu-list">
        {showAll && (
          <li>
            <button
              type="button"
              className="mac-option"
              aria-current={scope === null || undefined}
              onClick={() => onPick(null)}
            >
              <Layers size={13} strokeWidth={1.8} aria-hidden />
              <span className="mac-row-text">
                <span className="mac-name">All projects</span>
                <span className="mac-sub">
                  The default every project starts from
                </span>
              </span>
            </button>
          </li>
        )}
        {matches.map((p) => (
          <li key={p.id}>
            <button
              type="button"
              className="mac-option"
              aria-current={scope === p.id || undefined}
              onClick={() => onPick(p.id)}
            >
              <Folder size={13} strokeWidth={1.8} aria-hidden />
              <span className="mac-row-text">
                <span className="mac-name">{p.name}</span>
                <span className="mac-sub">{p.path}</span>
              </span>
            </button>
          </li>
        ))}
        {!showAll && matches.length === 0 && (
          <li className="mac-empty">No project matches</li>
        )}
      </ul>
      <div className="mac-menu-foot">
        <span className="mac-menu-choose" title="Not part of this demo">
          <FolderPlus size={12} strokeWidth={1.8} aria-hidden />
          Choose folder…
        </span>
        <button type="button" className="mac-pill" onClick={onClose}>
          Cancel
        </button>
      </div>
    </div>
  )
}

/**
 * Always at the top, whichever project is chosen: it says what's running on the
 * machine. Up to three servers to a row; actions appear on hover.
 */
function PortsSection({
  ports,
  onKill,
  onRestart,
}: {
  ports: Port[]
  onKill: (list: Port[]) => void
  onRestart: (port: Port) => void
}) {
  const ordered = PROJECTS.flatMap((p) => ports.filter((s) => s.project === p.id))
  return (
    <section className="mac-ports" aria-label="Ports">
      <div className="mac-ports-head">
        <span className="mac-section-label">Ports</span>
        {ports.length > 0 ? (
          <span className="mac-section-label">{ports.length}</span>
        ) : (
          <span className="mac-ports-status">No dev servers running</span>
        )}
        {ports.length > 1 && (
          <span className="mac-ports-stop">
            <TwoStep
              idle="Stop all"
              confirm="Confirm"
              icon={Square}
              onConfirm={() => onKill(ports)}
            />
          </span>
        )}
      </div>
      {ordered.length > 0 && (
        <ul className="mac-port-grid">
          {ordered.map((s) => {
            const p = PROJECTS.find((x) => x.id === s.project)
            return (
              <li
                key={s.port}
                className="mac-cell"
                title={`localhost:${s.port}\n${p?.path ?? ''}\n${s.framework}\n${s.process} · PID ${s.pid} · up ${s.uptime}`}
              >
                <span
                  className="mac-dot"
                  data-state={s.healthy ? 'ok' : 'down'}
                  aria-label={s.healthy ? 'Responding' : 'Not responding'}
                />
                <span className="mac-mono mac-cell-port">:{s.port}</span>
                <span className="mac-cell-cap">{p?.name}</span>
                <span className="mac-cell-actions">
                  <button
                    type="button"
                    className="mac-cell-btn"
                    aria-label={`Restart localhost:${s.port}`}
                    title="Restart: kill and relaunch the same command in the same folder"
                    onClick={() => onRestart(s)}
                  >
                    <RotateCw size={11} strokeWidth={2} aria-hidden />
                  </button>
                  <TwoStepIcon
                    label={`Kill localhost:${s.port}`}
                    onConfirm={() => onKill([s])}
                  />
                </span>
              </li>
            )
          })}
        </ul>
      )}
    </section>
  )
}

/** An × that asks once before it acts, like the app's. */
function TwoStepIcon({
  label,
  onConfirm,
}: {
  label: string
  onConfirm: () => void
}) {
  const [armed, setArmed] = useState(false)
  const timer = useRef<ReturnType<typeof setTimeout>>(undefined)
  useEffect(() => () => clearTimeout(timer.current), [])

  return (
    <button
      type="button"
      className="mac-cell-btn"
      data-armed={armed || undefined}
      aria-label={armed ? `${label}: click again to confirm` : label}
      title={armed ? 'Click again to confirm' : 'Kill: SIGTERM, then SIGKILL if it doesn’t stop'}
      onClick={() => {
        clearTimeout(timer.current)
        if (armed) {
          setArmed(false)
          onConfirm()
        } else {
          setArmed(true)
          timer.current = setTimeout(() => setArmed(false), 3000)
        }
      }}
    >
      {armed ? <b aria-hidden>!</b> : <X size={11} strokeWidth={2.4} aria-hidden />}
    </button>
  )
}

function ToolsView({
  shown,
  values,
  setHere,
  projects,
  expanded,
  onExpand,
  onService,
  onControl,
  onReset,
}: {
  shown: Harness[]
  values: (s: Service) => boolean[]
  setHere: (s: Service) => boolean
  projects: (s: Service) => string[]
  expanded: string[]
  onExpand: (id: string) => void
  onService: (s: Service, on: boolean) => void
  onControl: (s: Service, index: number, on: boolean) => void
  onReset: (s: Service) => void
}) {
  const [filter, setFilter] = useState('')
  const term = filter.trim().toLowerCase()
  // A hidden tool's controls don't exist as far as this tab goes.
  const indexes = (s: Service) =>
    s.controls.flatMap((c, i) => (shown.includes(c.harness) ? [i] : []))
  const visible = SERVICES.filter((s) => indexes(s).length > 0)
  const narrow = (s: Service) => ({
    ...s,
    controls: indexes(s).map((i) => s.controls[i]),
  })
  const narrowValues = (s: Service) => indexes(s).map((i) => values(s)[i])
  const matches = visible.filter((s) => s.name.toLowerCase().includes(term))
  const on = visible.filter((s) => {
    const m = mainState(narrow(s), narrowValues(s))
    return m === 'on' || m === 'mixed' || m === 'locked-on'
  })
  const skillTokens = on.reduce((n, s) => n + (s.pluginSkills?.tokens ?? 0), 0)

  return (
    <>
      <FilterField
        value={filter}
        onChange={setFilter}
        placeholder="Filter tools"
      />
      <Toolbar
        summary={`${on.length} of ${visible.length} on${skillTokens > 0 ? ` · plugin skills ${formatTokens(skillTokens)}` : ''}`}
      />
      {matches.length === 0 && (
        <p className="mac-empty">Nothing matches {filter}</p>
      )}
      <ul className="mac-list">
        {matches.map((s) => {
          const v = narrowValues(s)
          const controls = narrow(s).controls
          const state = mainState(narrow(s), v)
          const open = expanded.includes(s.id)
          const harnesses = [...new Set(controls.map((c) => c.harness))]
          const subtitle = [
            s.kind,
            s.tokens > 0 ? formatTokens(s.tokens) : '',
            harnesses.join(', '),
          ]
            .filter(Boolean)
            .join(' · ')
          const elsewhere = projects(s)
          const lock = controls.find((c) => c.lock)?.lock
          return (
            <li key={s.id} className="mac-service">
              <div className="mac-row">
                <button
                  type="button"
                  className="mac-disclose"
                  aria-expanded={open}
                  aria-label={`${s.name}, details`}
                  onClick={() => onExpand(s.id)}
                >
                  <ChevronRight size={11} strokeWidth={2.2} aria-hidden />
                  <span className="mac-row-text">
                    <span className="mac-title-line">
                      <span
                        className="mac-name"
                        data-dim={
                          state === 'off' || state === 'locked-off' || undefined
                        }
                      >
                        {s.name}
                      </span>
                      {setHere(s) && <span className="mac-tag">This project</span>}
                    </span>
                    <span className="mac-sub">{subtitle}</span>
                    {s.notConnected && !open && (
                      <span className="mac-sub">Not connected</span>
                    )}
                  </span>
                </button>
                {elsewhere.length > 0 && (
                  <Marker
                    label={elsewhere.length === 1 ? `Overridden in ${elsewhere[0]}` : `Overridden in ${elsewhere.length} projects`}
                    tip={elsewhere.join(', ')}
                  />
                )}
                {setHere(s) && (
                  <button
                    type="button"
                    className="mac-icon"
                    title="Back to the default"
                    aria-label={`Reset ${s.name} to the default`}
                    onClick={() => onReset(s)}
                  >
                    <Undo2 size={13} strokeWidth={1.8} aria-hidden />
                  </button>
                )}
                {state === 'locked-on' || state === 'locked-off' ? (
                  <span className="mac-locked" title={lock}>
                    <Lock size={10} strokeWidth={2} aria-hidden />
                    {state === 'locked-on' ? 'On' : 'Off'}
                  </span>
                ) : (
                  <>
                    {state === 'mixed' && (
                      <span className="mac-partly">Partly on</span>
                    )}
                    <Switch
                      on={state !== 'off'}
                      label={s.name}
                      onChange={() => onService(s, state === 'off')}
                    />
                  </>
                )}
              </div>
              {open && (
                <div className="mac-detail">
                  {controls.map((c, i) => (
                    <div key={c.harness + c.label} className="mac-control">
                      <span className="mac-control-text">
                        <span>
                          {c.harness}: {c.label}
                        </span>
                        {c.lock && <span className="mac-sub">{c.lock}</span>}
                      </span>
                      {c.lock ? (
                        <Lock
                          size={10}
                          strokeWidth={2}
                          className="mac-lock-icon"
                          aria-label="Locked"
                        />
                      ) : (
                        <Switch
                          on={v[i]}
                          label={`${s.name} in ${c.harness}`}
                          onChange={() => onControl(s, indexes(s)[i], !v[i])}
                        />
                      )}
                    </div>
                  ))}
                  {s.pluginSkills && (
                    <p className="mac-sub mac-wrap">
                      {s.pluginSkills.count} skills come with this plugin. They
                      go on and off with it.
                    </p>
                  )}
                </div>
              )}
            </li>
          )
        })}
      </ul>
    </>
  )
}

function SkillsView({
  shown,
  value,
  setHere,
  projects,
  values,
  onSkill,
  onReset,
  onTurnOffAll,
  onOpenTools,
}: {
  shown: Harness[]
  value: (k: Skill) => SkillState
  setHere: (k: Skill) => boolean
  projects: (k: Skill) => string[]
  values: (s: Service) => boolean[]
  onSkill: (k: Skill, state: SkillState) => void
  onReset: (k: Skill) => void
  onTurnOffAll: () => void
  onOpenTools: () => void
}) {
  const [filter, setFilter] = useState('')
  const term = filter.trim().toLowerCase()
  const matches = USER_SKILLS.filter((k) => k.name.includes(term))
  const auto = USER_SKILLS.filter((k) => value(k) === 'auto')
  const tokens = auto.reduce((n, k) => n + k.tokens, 0)
  const plugins = shown.includes('Claude Code')
    ? SERVICES.filter((s) => s.pluginSkills)
    : []

  return (
    <>
      <FilterField
        value={filter}
        onChange={setFilter}
        placeholder="Filter skills"
      />
      <Toolbar
        summary={`${auto.length} of ${USER_SKILLS.length} on Auto · ${formatTokens(tokens)} every session`}
      >
        <TwoStep
          idle="Turn all off"
          confirm="Confirm"
          icon={Power}
          onConfirm={onTurnOffAll}
        />
      </Toolbar>
      <dl className="mac-legend">
        {SKILL_LEGEND.map(([term, text]) => (
          <div key={term}>
            <dt>{term}</dt> <dd>{text}</dd>
          </div>
        ))}
      </dl>
      <SectionLabel name="Your skills" count={USER_SKILLS.length} />
      <ul className="mac-list">
        {matches.map((k) => {
          const state = value(k)
          const elsewhere = projects(k)
          const subtitle = k.authorLocked
            ? 'Its author turned off Auto'
            : state === 'auto'
              ? formatTokens(k.tokens)
              : `Saves ${formatTokens(k.tokens)}`
          return (
            <li key={k.name} className="mac-row mac-row-skill">
              <span className="mac-row-text">
                <span className="mac-title-line">
                  <span className="mac-name" data-dim={state === 'off' || undefined}>
                    {k.name}
                  </span>
                  {setHere(k) && <span className="mac-tag">This project</span>}
                </span>
                <span className="mac-sub">
                  {subtitle}
                  {elsewhere.length > 0 && (
                    <>
                      {' · '}
                      <span title={elsewhere.join(', ')}>
                        {elsewhere.length === 1
                          ? `Overridden in ${elsewhere[0]}`
                          : `Overridden in ${elsewhere.length} projects`}
                      </span>
                    </>
                  )}
                </span>
              </span>
              {setHere(k) && (
                <button
                  type="button"
                  className="mac-icon"
                  title="Back to the default"
                  aria-label={`Reset ${k.name} to the default`}
                  onClick={() => onReset(k)}
                >
                  <Undo2 size={13} strokeWidth={1.8} aria-hidden />
                </button>
              )}
              <Segmented
                value={state}
                label={k.name}
                allowed={k.authorLocked ? ['manual', 'off'] : undefined}
                onChange={(next) => onSkill(k, next)}
              />
            </li>
          )
        })}
      </ul>
      <SectionLabel name="From plugins" count={plugins.length} />
      <ul className="mac-list">
        {plugins.map((s) => {
          const m = mainState(s, values(s))
          const isOn = m !== 'off' && m !== 'locked-off'
          const cost = formatTokens(s.pluginSkills!.tokens)
          return (
            <li key={s.id} className="mac-row mac-row-skill">
              <span className="mac-row-text">
                <span className="mac-name" data-dim={!isOn || undefined}>
                  {s.name}
                </span>
                <span className="mac-sub">
                  {s.pluginSkills!.count} skills ·{' '}
                  {isOn ? cost : `Off, saves ${cost}`}
                </span>
              </span>
              <button type="button" className="mac-pill" onClick={onOpenTools}>
                Change in Tools
              </button>
            </li>
          )
        })}
      </ul>
    </>
  )
}

function FilterField({
  value,
  onChange,
  placeholder,
}: {
  value: string
  onChange: (v: string) => void
  placeholder: string
}) {
  return (
    <label className="mac-filter">
      <Search size={12} strokeWidth={1.8} aria-hidden />
      <input
        type="text"
        value={value}
        placeholder={placeholder}
        aria-label={placeholder}
        onChange={(e) => onChange(e.target.value)}
      />
    </label>
  )
}

function Toolbar({
  summary,
  children,
}: {
  summary: string
  children?: React.ReactNode
}) {
  return (
    <div className="mac-toolbar">
      <span>{summary}</span>
      {children}
    </div>
  )
}

/** Asks twice, then lets go after a few seconds, like the app's confirm button. */
function TwoStep({
  idle,
  confirm,
  icon: Icon,
  onConfirm,
}: {
  idle: string
  confirm: string
  icon: LucideIcon
  onConfirm: () => void
}) {
  const [armed, setArmed] = useState(false)
  const timer = useRef<ReturnType<typeof setTimeout>>(undefined)
  useEffect(() => () => clearTimeout(timer.current), [])

  return (
    <button
      type="button"
      className="mac-pill mac-pill-icon"
      data-armed={armed || undefined}
      onClick={() => {
        clearTimeout(timer.current)
        if (armed) {
          setArmed(false)
          onConfirm()
        } else {
          setArmed(true)
          timer.current = setTimeout(() => setArmed(false), 3000)
        }
      }}
    >
      <Icon size={11} strokeWidth={2.2} aria-hidden />
      {armed ? confirm : idle}
    </button>
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

/** Quiet note that some projects override this, with the detail in a tooltip. */
function Marker({ label, tip }: { label: string; tip: string }) {
  return (
    <span className="mac-marker" title={tip}>
      <Folder size={10} strokeWidth={1.8} aria-hidden />
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
