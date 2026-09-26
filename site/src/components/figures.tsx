import { ArrowRight } from 'lucide-react'
import { PictogramTile } from './pictogram'
import type { PictogramName } from './pictograms'

/*
  What one skill costs in each state. The example is an 18 KB skill body,
  inside the 5–50 KB range the README gives; name-only is ~150 characters.
  Bars are to scale, which is the point: the name-only sliver is real.
*/
const COSTS = [
  {
    state: 'On',
    cost: '18 KB',
    note: 'Full body loaded every session',
    width: 100,
  },
  {
    state: 'Name',
    cost: '~150 B',
    note: 'Name and description. Claude can still find it',
    width: 0.83,
  },
  {
    state: 'Slash',
    cost: '0',
    note: 'Hidden from the model. You call it with /name',
    width: 0,
  },
  { state: 'Off', cost: '0', note: 'Gone until you turn it back', width: 0 },
]

export function SkillCostFigure() {
  return (
    <figure className="figure cost-figure">
      <figcaption className="figure-head">
        <span className="figure-kicker">One skill, four states</span>
        <span className="figure-meta">Context it adds per session</span>
      </figcaption>
      <ol className="cost-rows">
        {COSTS.map((c) => (
          <li key={c.state} className="cost-row" data-state={c.state}>
            <span className="cost-state">{c.state}</span>
            <span className="cost-track">
              <span
                className="cost-bar"
                style={{
                  width: `max(${c.width}%, ${c.width ? '3px' : '0px'})`,
                }}
              />
            </span>
            <span className="cost-value">{c.cost}</span>
            <span className="cost-note">{c.note}</span>
          </li>
        ))}
      </ol>
      <p className="figure-foot">
        Example: an 18 KB skill. Name-only is about 120 times smaller and the
        skill stays discoverable.
      </p>
    </figure>
  )
}

const FLOW: { title: string; body: string; picto: PictogramName }[] = [
  {
    title: 'You flip a switch',
    body: 'Plugin, skill state or MCP server, in the menu bar.',
    picto: 'toggle',
  },
  {
    title: 'Loadout writes the field',
    body: 'settings.json or ~/.claude.json. Temp file, then an atomic swap.',
    picto: 'install',
  },
  {
    title: '/reload-plugins is copied',
    body: 'Paste it into a running session. New sessions need nothing.',
    picto: 'backpack',
  },
]

export function FlowFigure() {
  return (
    <figure className="figure flow-figure">
      <figcaption className="sr-only">
        The write path: a toggle writes the settings field, then the reload
        command lands on the clipboard.
      </figcaption>
      <ol className="flow">
        {FLOW.map((step, i) => (
          <li key={step.title} className="flow-step glow-host">
            <div className="flow-top">
              <PictogramTile name={step.picto} />
              {i < FLOW.length - 1 && (
                <ArrowRight
                  className="flow-arrow"
                  size={16}
                  strokeWidth={1.6}
                  aria-hidden
                />
              )}
            </div>
            <span className="flow-index">0{i + 1}</span>
            <strong>{step.title}</strong>
            <p>{step.body}</p>
          </li>
        ))}
      </ol>
    </figure>
  )
}
