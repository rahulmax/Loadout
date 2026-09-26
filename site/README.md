# Loadout site

The marketing page for Loadout. Next.js, static export.

```sh
pnpm install
pnpm dev      # http://localhost:3000
pnpm build    # writes the static site to out/
pnpm lint
```

`out/` is self-contained: upload it to any static host, or point Vercel at this folder.

## What's where

- `src/app/page.tsx`: the page and all its copy
- `src/components/panel/`: the menu bar panel rebuilt in HTML. The demo data is invented, so no real machine shows. Sizes were measured off the app's `LOADOUT_SNAPSHOT` renders.
- `src/components/pictograms.ts`: IBM Carbon pictograms (Apache-2.0), inlined
- `public/motifs/`: the mist and washi fibre, cut from a generated sumi-e sheet as alpha masks. They take the ink colour of the current theme.
