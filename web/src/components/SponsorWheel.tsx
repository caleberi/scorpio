import { useMemo, type CSSProperties } from 'react'
import { useRouterState } from '@tanstack/react-router'
import { useApp } from '@/lib/app-context'
import { assignBearings, loadSponsors, SPONSOR_WHEEL } from '@/lib/sponsors'
import { cn } from '@/lib/utils'

type GearProps = {
  teeth: number
}

function GearRing({ teeth }: GearProps) {
  const d = useMemo(() => buildGearPath(teeth, 37.5, 47.2), [teeth])

  return (
    <svg
      className="sponsor-wheel-gear"
      viewBox="0 0 100 100"
      aria-hidden
    >
      <path d={d} />
      <circle className="sponsor-wheel-race" cx="50" cy="50" r="34.5" />
      <circle className="sponsor-wheel-race sponsor-wheel-race-inner" cx="50" cy="50" r="18" />
    </svg>
  )
}

function buildGearPath(teeth: number, inner: number, outer: number): string {
  const step = (Math.PI * 2) / teeth
  const half = step * 0.18
  const flare = step * 0.08
  const parts: string[] = []

  for (let i = 0; i < teeth; i++) {
    const a = i * step - Math.PI / 2
    const p = (r: number, ang: number) =>
      `${(50 + r * Math.cos(ang)).toFixed(3)} ${(50 + r * Math.sin(ang)).toFixed(3)}`

    const cmd = i === 0 ? 'M' : 'L'
    parts.push(
      `${cmd}${p(inner, a - step / 2 + flare)}`,
      `L${p(inner, a - half)}`,
      `L${p(outer, a - half + flare)}`,
      `L${p(outer, a + half - flare)}`,
      `L${p(inner, a + half)}`,
    )
  }

  parts.push('Z')
  return parts.join(' ')
}

function BearingMark({ src, tone }: { src: string; tone: 'brand' | 'ink' }) {
  if (tone === 'ink') {
    return (
      <span
        className="sponsor-bearing-ink"
        style={{ '--bearing-mark': `url(${JSON.stringify(src)})` } as CSSProperties}
        aria-hidden
      />
    )
  }

  return <img src={src} alt="" draggable={false} />
}

export function SponsorWheel() {
  const { t } = useApp()
  const pathname = useRouterState({ select: (s) => s.location.pathname })

  const sponsors = useMemo(() => loadSponsors(), [])
  const seed = useMemo(
    () => (Math.floor(Math.random() * 0xffff_ffff) ^ (Date.now() & 0xffff)) >>> 0,
    [],
  )
  const bearings = useMemo(
    () => assignBearings(sponsors, SPONSOR_WHEEL.bearingCount, seed),
    [sponsors, seed],
  )

  if (!SPONSOR_WHEEL.enabled) return null
  if (SPONSOR_WHEEL.homeOnly && pathname !== '/') return null
  if (sponsors.length === 0) return null

  const count = bearings.length

  return (
    <div className="sponsor-wheel-slot">
      <div
        className="sponsor-wheel"
        role="group"
        aria-label={t.nav.sponsors}
      >
        <div className="sponsor-wheel-rotor">
          <GearRing teeth={SPONSOR_WHEEL.teeth} />
          <ul className="sponsor-wheel-cage">
            {bearings.map((bearing, i) => {
              const angle = (360 / count) * i
              const inner = (
                <span
                  className={cn(
                    'sponsor-bearing-ball',
                    bearing.spinReverse && 'sponsor-bearing-ball-reverse',
                  )}
                  style={
                    {
                      '--bearing-spin-dur': bearing.spinDuration,
                      '--bearing-spin-delay': bearing.spinDelay,
                    } as CSSProperties
                  }
                >
                  <BearingMark src={bearing.src} tone={bearing.tone} />
                </span>
              )

              return (
                <li
                  key={`${bearing.id}-${bearing.slot}`}
                  className="sponsor-bearing"
                  style={{ '--bearing-angle': `${angle}deg` } as CSSProperties}
                >
                  {bearing.href ? (
                    <a
                      href={bearing.href}
                      target="_blank"
                      rel="noopener noreferrer"
                      title={bearing.label}
                      aria-label={bearing.label}
                    >
                      {inner}
                    </a>
                  ) : (
                    <span title={bearing.label}>{inner}</span>
                  )}
                </li>
              )
            })}
          </ul>
        </div>
        <span className="sponsor-wheel-hub" aria-hidden>
          +
        </span>
      </div>
    </div>
  )
}
