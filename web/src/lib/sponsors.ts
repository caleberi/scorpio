import { FEATURES } from '@/lib/constants'
import catalog from '@/sponsors/sponsors.json'

export type SponsorTone = 'brand' | 'ink'

export type SponsorMeta = {
  href: string
  label: string
  tone?: SponsorTone
}

export type Sponsor = {
  id: string
  src: string
  href: string | null
  label: string
  tone: SponsorTone
}

export type SponsorBearing = Sponsor & {
  slot: number
  spinDuration: string
  spinDelay: string
  spinReverse: boolean
}

export const SPONSOR_WHEEL = {
  enabled: FEATURES.sponsorWheel,
  homeOnly: true,
  bearingCount: 8,
  teeth: 16,
} as const

const IMAGE_MODULES = import.meta.glob<string>(
  '../sponsors/*.{svg,png,webp,jpg,jpeg,gif}',
  { eager: true, query: '?url', import: 'default' },
)

function isTone(value: unknown): value is SponsorTone {
  return value === 'brand' || value === 'ink'
}

function readMeta(id: string): SponsorMeta | undefined {
  const raw = (catalog as Record<string, { href?: string; label?: string; tone?: string }>)[id]
  if (!raw) return undefined
  return {
    href: raw.href ?? '',
    label: raw.label ?? id,
    tone: isTone(raw.tone) ? raw.tone : undefined,
  }
}

function fileStem(path: string): string {
  const file = path.split('/').pop() ?? path
  return file.replace(/\.[^.]+$/, '').toLowerCase()
}

function mulberry32(seed: number) {
  let s = seed >>> 0
  return () => {
    s = (Math.imul(s, 1664525) + 1013904223) >>> 0
    return s / 4294967296
  }
}

function shuffle<T>(items: T[], rand: () => number): T[] {
  const next = [...items]
  for (let i = next.length - 1; i > 0; i--) {
    const j = Math.floor(rand() * (i + 1))
    const left = next[i]
    const right = next[j]
    if (left === undefined || right === undefined) continue
    next[i] = right
    next[j] = left
  }
  return next
}

export function loadSponsors(): Sponsor[] {
  if (!SPONSOR_WHEEL.enabled) return []

  return Object.entries(IMAGE_MODULES)
    .map(([path, src]) => {
      const id = fileStem(path)
      const meta = readMeta(id)
      return {
        id,
        src,
        href: meta?.href || null,
        label: meta?.label ?? id,
        tone: meta?.tone ?? 'brand',
      }
    })
    .sort((a, b) => a.id.localeCompare(b.id))
}

/** Fill the gearbox with a random arrangement, repeating icons as needed. */
export function assignBearings(
  sponsors: Sponsor[],
  count: number,
  seed: number,
): SponsorBearing[] {
  if (sponsors.length === 0 || count <= 0) return []

  const rand = mulberry32(seed)
  const unique = shuffle(sponsors, rand)
  const picked: Sponsor[] = []

  for (let i = 0; i < count; i++) {
    const guaranteed = unique[i]
    if (guaranteed) {
      picked.push(guaranteed)
      continue
    }
    const extra = sponsors[Math.floor(rand() * sponsors.length)]
    if (extra) picked.push(extra)
  }

  return shuffle(picked, rand).map((sponsor, slot) => ({
    ...sponsor,
    slot,
    spinDuration: `${3.6 + rand() * 6.4}s`,
    spinDelay: `${(-rand() * 8).toFixed(2)}s`,
    spinReverse: rand() > 0.5,
  }))
}
