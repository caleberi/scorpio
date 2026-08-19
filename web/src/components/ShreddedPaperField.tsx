import { useMemo, type CSSProperties } from 'react'

type Shred = {
  id: number
  left: string
  top: string
  width: string
  height: string
  rot: string
  duration: string
  delay: string
  tone: number
  kind: 'strip' | 'scrap' | 'ribbon'
  opacity: string
}

function seeded(seed: number) {
  let s = seed >>> 0
  return () => {
    s = (Math.imul(s, 1664525) + 1013904223) >>> 0
    return s / 4294967296
  }
}

function makeShreds(count: number): Shred[] {
  const rand = seeded(0x5c0_10)
  const kinds: Shred['kind'][] = ['strip', 'scrap', 'ribbon']

  return Array.from({ length: count }, (_, id) => {
    const kind = kinds[Math.floor(rand() * kinds.length)]
    const tall = kind === 'strip'
    const width = tall ? 7 + rand() * 16 : kind === 'ribbon' ? 28 + rand() * 42 : 18 + rand() * 28
    const height = tall ? 52 + rand() * 90 : kind === 'ribbon' ? 8 + rand() * 12 : 22 + rand() * 34
    return {
      id,
      left: `${rand() * 94}%`,
      top: `${rand() * 92}%`,
      width: `${width}px`,
      height: `${height}px`,
      rot: `${(rand() * 160 - 80).toFixed(1)}deg`,
      duration: `${16 + rand() * 14}s`,
      delay: `${(-rand() * 18).toFixed(2)}s`,
      tone: Math.floor(rand() * 5),
      kind,
      opacity: (0.34 + rand() * 0.28).toFixed(2),
    }
  })
}

export function ShreddedPaperField() {
  const shreds = useMemo(() => makeShreds(22), [])

  return (
    <div className="paper-shred-field" aria-hidden>
      {shreds.map((shred) => (
        <span
          key={shred.id}
          className={`paper-shred paper-shred-${shred.kind} paper-shred-tone-${shred.tone}`}
          style={
            {
              left: shred.left,
              top: shred.top,
              width: shred.width,
              height: shred.height,
              opacity: shred.opacity,
              animationDuration: shred.duration,
              animationDelay: shred.delay,
              '--shred-rot': shred.rot,
            } as CSSProperties
          }
        />
      ))}
    </div>
  )
}
