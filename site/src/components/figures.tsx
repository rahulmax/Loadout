/*
  What one skill adds to every session. The listing carries a name and a
  description per skill; the body loads only when the skill is used.
  Measured on a real set of 28 skills: descriptions average ~400 characters,
  ~100 tokens at ~4 characters each. A name is ~5 tokens.
  Bars are to scale, so the name-only sliver is real.
*/
const COSTS = [
  {
    state: 'On',
    cost: '~100 tokens',
    note: 'Name and description. The body loads only when the skill is used',
    width: 100,
  },
  {
    state: 'Name',
    cost: '~5 tokens',
    note: 'Just the name. Claude can still find it',
    width: 5,
  },
  {
    state: 'Slash',
    cost: '0',
    note: 'Hidden from the model. You call it with /name',
    width: 0,
  },
  {
    state: 'Off',
    cost: '0',
    note: 'Gone from the model and from /',
    width: 0,
  },
]

/* The same set of 28, all on versus all name-only. */
const SET = [
  { label: '28 skills, all On', cost: '~2,800 tokens' },
  { label: '28 skills, all Name', cost: '~140 tokens' },
]

export function SkillCostFigure() {
  return (
    <figure className="cost-figure">
      <figcaption className="sr-only">
        Context one skill adds to every session in each of its four states, and
        what a set of 28 skills adds.
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
      <dl className="cost-set">
        {SET.map((row) => (
          <div key={row.label}>
            <dt>{row.label}</dt>
            <dd>{row.cost}</dd>
          </div>
        ))}
      </dl>
      <p className="cost-foot">
        Measured on a real set of 28 skills. Descriptions run from 50 to 1,400
        characters, and Claude Code caps each at 1,536. On a large set it may
        also trim the least-used descriptions to fit its own budget, so On is a
        ceiling.
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
    body: 'Your user settings.json. Temp file, then an atomic swap.',
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
