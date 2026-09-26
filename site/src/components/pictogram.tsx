import { PICTOGRAMS, type PictogramName } from './pictograms'

/** A bare Carbon pictogram. Decoration beside text that already says the thing. */
export function Pictogram({
  name,
  className = '',
}: {
  name: PictogramName
  className?: string
}) {
  return (
    <svg
      viewBox="0 0 32 32"
      className={className}
      aria-hidden
      focusable="false"
      dangerouslySetInnerHTML={{ __html: PICTOGRAMS[name] }}
    />
  )
}

/**
 * A pictogram on Groundwork's tile: a one-hue vertical fill, a 1px edge and a
 * faint inner ring. It lights coral when an ancestor marked `glow-host` is
 * hovered or focused, so the card decides when and the tile decides how.
 */
export function PictogramTile({
  name,
  size = 'md',
}: {
  name: PictogramName
  size?: 'sm' | 'md' | 'lg'
}) {
  return (
    <span className={`pictogram-tile pictogram-tile-${size}`} aria-hidden>
      <Pictogram name={name} />
    </span>
  )
}
