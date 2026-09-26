import { BatteryMedium, Search, Wifi } from 'lucide-react'
import { Pictogram } from './pictogram'

/** The right end of a macOS menu bar, with Loadout's item open. */
export function MenuBar() {
  return (
    <div className="menubar" aria-hidden>
      <span className="menubar-item">
        <BatteryMedium size={15} strokeWidth={1.6} />
      </span>
      <span className="menubar-item">
        <Wifi size={13} strokeWidth={2} />
      </span>
      <span className="menubar-item">
        <Search size={12} strokeWidth={2.2} />
      </span>
      <span className="menubar-item menubar-item-open">
        <Pictogram name="backpack" />
      </span>
      <span className="menubar-clock">Fri 26 Sep 9:41</span>
    </div>
  )
}
