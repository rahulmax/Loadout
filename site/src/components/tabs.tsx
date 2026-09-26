'use client'

import { useId, useRef, useState } from 'react'

export type TabItem = {
  id: string
  tab: React.ReactNode
  panel: React.ReactNode
}

/**
 * WAI-ARIA tabs with automatic activation. Every panel is in the markup and
 * the inactive ones are `hidden`, so the content is there without script.
 */
export function Tabs({
  label,
  items,
  className = '',
}: {
  label: string
  items: TabItem[]
  className?: string
}) {
  const [active, setActive] = useState(items[0]?.id)
  const refs = useRef<(HTMLButtonElement | null)[]>([])
  const base = useId()

  const onKeyDown = (e: React.KeyboardEvent, i: number) => {
    const last = items.length - 1
    const next =
      e.key === 'ArrowRight'
        ? i === last
          ? 0
          : i + 1
        : e.key === 'ArrowLeft'
          ? i === 0
            ? last
            : i - 1
          : e.key === 'Home'
            ? 0
            : e.key === 'End'
              ? last
              : null
    if (next === null) return
    e.preventDefault()
    setActive(items[next].id)
    refs.current[next]?.focus()
  }

  return (
    <div className={`tabs ${className}`}>
      <div className="tabs-list" role="tablist" aria-label={label}>
        {items.map((item, i) => {
          const selected = item.id === active
          return (
            <button
              key={item.id}
              ref={(el) => {
                refs.current[i] = el
              }}
              type="button"
              role="tab"
              id={`${base}-tab-${item.id}`}
              aria-controls={`${base}-panel-${item.id}`}
              aria-selected={selected}
              tabIndex={selected ? 0 : -1}
              className="tab"
              onClick={() => setActive(item.id)}
              onKeyDown={(e) => onKeyDown(e, i)}
            >
              <span className="tab-index">
                {String(i + 1).padStart(2, '0')}
              </span>
              {item.tab}
            </button>
          )
        })}
      </div>
      {items.map((item) => (
        <div
          key={item.id}
          role="tabpanel"
          id={`${base}-panel-${item.id}`}
          aria-labelledby={`${base}-tab-${item.id}`}
          hidden={item.id !== active}
          className="tabs-panel"
          tabIndex={0}
        >
          {item.panel}
        </div>
      ))}
    </div>
  )
}
