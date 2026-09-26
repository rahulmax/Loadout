import type { NextConfig } from 'next'

// Static export: `pnpm build` writes a self-contained site to out/, ready for any static host.
const nextConfig: NextConfig = {
  output: 'export',
  images: { unoptimized: true },
}

export default nextConfig
