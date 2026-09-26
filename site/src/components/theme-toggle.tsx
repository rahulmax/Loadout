'use client'

import { Moon, Sun } from 'lucide-react'

/**
 * Ships both labels and lets the cascade pick one, so the button never holds
 * state and can never disagree with the page. `data-theme` is written before
 * first paint by the script in the root layout.
 */
export function ThemeToggle() {
  const flip = () => {
    const root = document.documentElement
    const next = root.dataset.theme === 'dark' ? 'light' : 'dark'
    root.dataset.theme = next
    try {
      localStorage.setItem('loadout:theme', next)
    } catch {
      /* The setting lasts for this visit. */
    }
  }
  return (
    <button type="button" onClick={flip} className="theme-toggle">
      <span className="when-light">
        <Moon size={16} strokeWidth={1.75} aria-hidden />
        <span className="sr-only">Switch to dark mode</span>
      </span>
      <span className="when-dark">
        <Sun size={16} strokeWidth={1.75} aria-hidden />
        <span className="sr-only">Switch to light mode</span>
      </span>
    </button>
  )
}
