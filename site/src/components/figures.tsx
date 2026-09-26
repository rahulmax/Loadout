/*
  What one skill costs in each state. The example is an 18 KB skill body,
  inside the 5–50 KB range the README gives; name-only is ~150 characters.
  Tokens at ~4 characters each: ~4.5k for the body, ~40 for name-only.
  Bars are to scale, which is the point: the name-only sliver is real.
*/
const COSTS = [
  {
    state: 'On',
    cost: '~4.5k tokens',
    note: 'Full body loaded every session',
    width: 100,
  },
  {
    state: 'Name',
    cost: '~40 tokens',
    note: 'Name and description. Claude can still find it',
    width: 0.89,
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
    <figure className="cost-figure">
      <figcaption className="sr-only">
        Context one 4.5k-token skill adds per session, in each of its four
        states.
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
      <p className="cost-foot">
        Example: an 18 KB skill, about 4.5k tokens. Name-only is over 100 times
        smaller and the skill stays discoverable.
      </p>
    </figure>
  )
}

const FLOW = [
  {
    title: 'You flip a switch',
    body: 'Plugin, skill state or MCP server, in the menu bar.',
  },
  {
    title: 'Loadout writes the field',
    body: 'settings.json or ~/.claude.json. Temp file, then an atomic swap.',
  },
  {
    title: '/reload-plugins is copied',
    body: 'Paste it into a running session. New sessions need nothing.',
  },
]

export function FlowFigure() {
  return (
    <figure>
      <figcaption className="sr-only">
        The write path: a toggle writes the settings field, then the reload
        command lands on the clipboard.
      </figcaption>
      <ol className="flow">
        {FLOW.map((step, i) => (
          <li key={step.title} className="flow-step">
            <span className="flow-index">{String(i + 1).padStart(2, '0')}</span>
            <strong>{step.title}</strong>
            <p>{step.body}</p>
          </li>
        ))}
      </ol>
    </figure>
  )
}
