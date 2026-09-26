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
