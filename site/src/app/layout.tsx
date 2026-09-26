import type { Metadata, Viewport } from 'next'
import { Geist, Geist_Mono } from 'next/font/google'
import './globals.css'

const sans = Geist({
  subsets: ['latin'],
  variable: '--font-geist-sans',
  display: 'swap',
})

const mono = Geist_Mono({
  subsets: ['latin'],
  variable: '--font-geist-mono',
  display: 'swap',
})

export const metadata: Metadata = {
  title: 'Loadout · Decide what Claude carries',
  description:
    'A macOS menu bar panel that switches Claude Code plugins, skills and MCP servers at the level Claude actually reads, so what you turn off stays out of context.',
}

export const viewport: Viewport = {
  themeColor: [
    { media: '(prefers-color-scheme: light)', color: '#f4f5f7' },
    { media: '(prefers-color-scheme: dark)', color: '#0d0e10' },
  ],
}

/**
 * Resolve the mode before first paint. An effect would run after the browser
 * has painted, so the page would show light and then swap. `data-theme` is
 * always concrete, so the stylesheet keys dark on one attribute only.
 */
const PREPAINT = `try{
var t=localStorage.getItem('loadout:theme');
if(t!=='light'&&t!=='dark')t=matchMedia('(prefers-color-scheme: dark)').matches?'dark':'light';
document.documentElement.dataset.theme=t;
}catch(e){}`

export default function RootLayout({ children }: LayoutProps<'/'>) {
  return (
    <html
      lang="en"
      className={`${sans.variable} ${mono.variable}`}
      suppressHydrationWarning
    >
      <head>
        <script dangerouslySetInnerHTML={{ __html: PREPAINT }} />
      </head>
      <body>{children}</body>
    </html>
  )
}
