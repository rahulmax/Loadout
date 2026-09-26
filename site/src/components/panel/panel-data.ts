/**
 * Demo inventory for the recreated panel. Names are public marketplace
 * plugins and invented projects, so the page never shows a real machine.
 * Labels and summary formats mirror the Swift views string for string.
 */

export type TabId = 'ports' | 'plugins' | 'skills' | 'mcp'

export type SkillState = 'on' | 'name-only' | 'user-invocable-only' | 'off'

export interface Port {
  port: number
  framework: string
  path: string
  pid: number
  process: string
  uptime: string
  healthy: boolean
}

export interface Plugin {
  name: string
  version: string
  marketplace: string
  enabled: boolean
}

export interface Skill {
  name: string
  state: SkillState
}

export interface LocalMcp {
  name: string
  transport: 'HTTP' | 'STDIO'
  target: string
  enabled: boolean
}

export interface HostedMcp {
  name: string
  icon: 'figma' | 'gmail' | 'calendar' | 'drive' | 'miro' | 'slack'
  allowed: boolean
}

export const PORTS: Port[] = [
  {
    port: 3000,
    framework: 'Next.js',
    path: '~/code/tea-house/web',
    pid: 48213,
    process: 'node',
    uptime: '1h 12m',
    healthy: true,
  },
  {
    port: 5173,
    framework: 'Vite',
    path: '~/code/field-notes',
    pid: 51902,
    process: 'node',
    uptime: '24m',
    healthy: true,
  },
  {
    port: 8000,
    framework: 'Python',
    path: '~/code/kiln/api',
    pid: 39011,
    process: 'python3',
    uptime: '3d 4h',
    healthy: false,
  },
]

export const PLUGINS: Plugin[] = [
  {
    name: 'code-simplifier',
    version: '1.0.0',
    marketplace: 'claude-plugins-official',
    enabled: false,
  },
  {
    name: 'figma',
    version: '2.2.120',
    marketplace: 'claude-plugins-official',
    enabled: true,
  },
  {
    name: 'frontend-design',
    version: 'fa59bc903774',
    marketplace: 'claude-plugins-official',
    enabled: true,
  },
  {
    name: 'playwright',
    version: 'fa59bc903774',
    marketplace: 'claude-plugins-official',
    enabled: false,
  },
  {
    name: 'swift-lsp',
    version: '1.0.0',
    marketplace: 'claude-plugins-official',
    enabled: true,
  },
  {
    name: 'vercel',
    version: '0.50.0',
    marketplace: 'claude-plugins-official',
    enabled: false,
  },
]

export const USER_SKILLS: Skill[] = [
  { name: 'animate', state: 'off' },
  { name: 'better-typography', state: 'name-only' },
  { name: 'brand-voice', state: 'on' },
  { name: 'changelog', state: 'user-invocable-only' },
  { name: 'color-audit', state: 'name-only' },
  { name: 'deploy-preview', state: 'user-invocable-only' },
  { name: 'haiku-commit', state: 'on' },
  { name: 'layout-grid', state: 'off' },
  { name: 'release-notes', state: 'off' },
]

export const PLUGIN_SKILLS: Skill[] = [
  { name: 'frontend-design', state: 'on' },
  { name: 'figma-implement', state: 'name-only' },
  { name: 'swift-concurrency', state: 'off' },
]

export const LOCAL_MCPS: LocalMcp[] = [
  {
    name: 'figma',
    transport: 'HTTP',
    target: 'https://mcp.figma.com/mcp',
    enabled: true,
  },
  {
    name: 'github',
    transport: 'STDIO',
    target: 'npx -y @modelcontextprotocol/server-github',
    enabled: false,
  },
  {
    name: 'postgres',
    transport: 'STDIO',
    target: 'uvx mcp-server-postgres --read-only',
    enabled: false,
  },
]

export const HOSTED_MCPS: HostedMcp[] = [
  { name: 'Figma', icon: 'figma', allowed: false },
  { name: 'Gmail', icon: 'gmail', allowed: false },
  { name: 'Google Calendar', icon: 'calendar', allowed: true },
  { name: 'Google Drive', icon: 'drive', allowed: false },
  { name: 'Miro', icon: 'miro', allowed: false },
  { name: 'Slack', icon: 'slack', allowed: true },
]

export const SKILL_STATES: { id: SkillState; label: string; tip: string }[] = [
  { id: 'on', label: 'On', tip: 'On — full skill body available to the model' },
  {
    id: 'name-only',
    label: 'Name',
    tip: 'Name only — ~150 chars (name + description), keeps it discoverable',
  },
  {
    id: 'user-invocable-only',
    label: 'Slash',
    tip: 'Slash only — invocable as /skill-name, hidden from model discovery',
  },
  { id: 'off', label: 'Off', tip: 'Off — fully disabled' },
]
