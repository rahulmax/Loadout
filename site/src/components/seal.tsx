import { Pictogram } from './pictogram'

/**
 * The brand mark: Carbon's backpack pictogram cut into a coral hanko seal.
 * Square with softened corners, the way a carved stone seal prints.
 */
export function Seal({ size = 32 }: { size?: number }) {
  return (
    <span
      className="seal"
      style={{ '--seal': `${size}px` } as React.CSSProperties}
      aria-hidden
    >
      <Pictogram name="backpack" />
    </span>
  )
}
