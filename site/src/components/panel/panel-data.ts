/**
 * Demo inventory for the recreated panel. Names are public marketplace
 * services and invented projects, so the page never shows a real machine.
 * Labels and summary formats mirror the Swift views string for string.
 * Token figures are round demo numbers.
 */

export type TabId = 'ports' | 'tools' | 'skills'

/** Auto, Manual and Off. Name only exists too, from a skill's right-click menu. */
export type SkillState = 'auto' | 'manual' | 'off'

export type Harness = 'Claude Code' | 'Codex' | 'Antigravity' | 'Cursor'

/** The scope picker's value: null is All projects. */
export type Scope = string | null

export interface Project {
  id: string
  name: string
  path: string
}

export interface Port {
  port: number
  framework: string
  project: string
  pid: number
  process: string
  uptime: string
  healthy: boolean
}

export interface ToolControl {
  harness: Harness
  label: string
  /** Why the switch can't move, when it can't. */
  lock?: string
}

export interface Service {
  id: string
  name: string
  /** "Plugin + MCP", as the row's subtitle opens. */
  kind: string
  tokens: number
  /** Skills that ride along with a plugin. They follow its switch. */
  pluginSkills?: { count: number; tokens: number }
  controls: ToolControl[]
  /** The default for every project, one flag per control. */
  on: boolean[]
  /** claude.ai connector that isn't connected on the account. */
  notConnected?: boolean
}

export interface Skill {
  name: string
  tokens: number
  state: SkillState
  /** The skill turns off Auto itself, so only Manual and Off apply. */
  authorLocked?: boolean
}

export const PROJECTS: Project[] = [
  { id: 'tea-house', name: 'tea-house', path: '~/code/tea-house' },
  { id: 'field-notes', name: 'field-notes', path: '~/code/field-notes' },
  { id: 'kiln', name: 'kiln', path: '~/code/kiln' },
]

export const PORTS: Port[] = [
  {
    port: 3000,
    framework: 'Next.js',
    project: 'tea-house',
    pid: 48213,
    process: 'node',
    uptime: '1h 12m',
    healthy: true,
  },
  {
    port: 6006,
    framework: 'Storybook',
    project: 'tea-house',
    pid: 48590,
    process: 'node',
    uptime: '1h 9m',
    healthy: true,
  },
  {
    port: 5173,
    framework: 'Vite',
    project: 'field-notes',
    pid: 51902,
    process: 'node',
    uptime: '24m',
    healthy: true,
  },
  {
    port: 8000,
    framework: 'Python',
    project: 'kiln',
    pid: 39011,
    process: 'python3',
    uptime: '3d 4h',
    healthy: false,
  },
]

const CC = 'Claude Code'

export const SERVICES: Service[] = [
  {
    id: 'figma',
    name: 'Figma',
    kind: 'Plugin + MCP',
    tokens: 1700,
    pluginSkills: { count: 3, tokens: 420 },
    controls: [
      { harness: CC, label: 'Plugin' },
      { harness: CC, label: 'MCP server' },
      {
        harness: 'Cursor',
        label: 'MCP server',
        lock: 'Cursor keeps on and off in its own app state, so Loadout shows it read-only.',
      },
    ],
    on: [true, true, true],
  },
  {
    id: 'github',
    name: 'GitHub',
    kind: 'MCP',
    tokens: 900,
    controls: [
      { harness: CC, label: 'MCP server' },
      { harness: 'Codex', label: 'MCP server' },
    ],
    on: [true, true],
  },
  {
    id: 'playwright',
    name: 'Playwright',
    kind: 'Plugin + MCP',
    tokens: 1200,
    pluginSkills: { count: 2, tokens: 260 },
    controls: [
      { harness: CC, label: 'Plugin' },
      { harness: CC, label: 'MCP server' },
    ],
    on: [false, false],
  },
  {
    id: 'vercel',
    name: 'Vercel',
    kind: 'Plugin',
    tokens: 600,
    pluginSkills: { count: 4, tokens: 540 },
    controls: [{ harness: CC, label: 'Plugin' }],
    on: [false],
  },
  {
    id: 'slack',
    name: 'Slack',
    kind: 'Connector',
    tokens: 500,
    controls: [{ harness: CC, label: 'claude.ai connector' }],
    on: [true],
  },
  {
    id: 'higgsfield',
    name: 'Higgsfield',
    kind: 'Connector',
    tokens: 0,
    controls: [
      {
        harness: CC,
        label: 'claude.ai connector',
        lock: 'Not connected on claude.ai right now. Connect it there first.',
      },
    ],
    on: [false],
    notConnected: true,
  },
]

/** Per project, the services it sets for itself. Same shape as `on`. */
export const SERVICE_OVERRIDES: Record<string, Record<string, boolean[]>> = {
  'tea-house': {
    figma: [false, false, true],
    playwright: [true, true],
    slack: [false],
  },
  'field-notes': { github: [false, false] },
  kiln: {},
}

export const USER_SKILLS: Skill[] = [
  { name: 'brand-voice', tokens: 110, state: 'auto' },
  { name: 'changelog', tokens: 90, state: 'manual' },
  { name: 'color-audit', tokens: 120, state: 'auto' },
  {
    name: 'deploy-preview',
    tokens: 80,
    state: 'manual',
    authorLocked: true,
  },
  { name: 'haiku-commit', tokens: 70, state: 'auto' },
  { name: 'layout-grid', tokens: 130, state: 'off' },
  { name: 'release-notes', tokens: 100, state: 'off' },
]

/** Per project, the skills it sets for itself. */
export const SKILL_OVERRIDES: Record<string, Record<string, SkillState>> = {
  'tea-house': { 'brand-voice': 'off', 'layout-grid': 'auto' },
  'field-notes': { changelog: 'auto' },
  kiln: {},
}

export const SKILL_STATES: { id: SkillState; label: string; tip: string }[] = [
  {
    id: 'auto',
    label: 'Auto',
    tip: 'Auto — the agent can pick it',
  },
  {
    id: 'manual',
    label: 'Manual',
    tip: 'Manual — only when you type /name',
  },
  { id: 'off', label: 'Off', tip: 'Off — hidden everywhere' },
]

/** The always-visible legend under the Skills toolbar. */
export const SKILL_LEGEND: [string, string][] = [
  ['Auto', 'the agent can pick it'],
  ['Manual', 'only when you type /name'],
  ['Off', 'hidden everywhere'],
]

export const AUTHOR_LOCK_TIP =
  'Its author turned off Auto, so it can only be Manual or Off.'

export function formatTokens(tokens: number) {
  return `~${tokens.toLocaleString('en-US')} tokens`
}
