import type { Keyframe, Track, Transform } from '@/lib/presentation'
import { IDENTITY } from '@/lib/presentation'

export type Ease =
  | 'linear'
  | 'ease'
  | 'ease-in'
  | 'ease-out'
  | 'cubic-in'
  | 'cubic-out'
  | 'cubic-in-out'

export function parseEase(name?: string): Ease {
  switch ((name ?? 'linear').toLowerCase()) {
    case 'ease-in':
      return 'ease-in'
    case 'ease-out':
      return 'ease-out'
    case 'ease-in-out':
    case 'cubic-in-out':
      return 'cubic-in-out'
    case 'cubic-in':
      return 'cubic-in'
    case 'cubic-out':
      return 'cubic-out'
    case 'ease':
      return 'ease'
    default:
      return 'linear'
  }
}

/** Outgoing-keyframe easing. Must match libraries/processor/presentation/renderer/animation.zig. */
export function applyEase(ease: Ease, t: number): number {
  const x = Math.min(1, Math.max(0, t))
  switch (ease) {
    case 'linear':
      return x
    case 'ease':
      return x * x * (3 - 2 * x)
    case 'ease-in':
      return x * x
    case 'ease-out':
      return 1 - (1 - x) * (1 - x)
    case 'cubic-in':
      return x * x * x
    case 'cubic-out':
      return 1 - (1 - x) ** 3
    case 'cubic-in-out':
      return x < 0.5 ? 4 * x * x * x : 1 - (-2 * x + 2) ** 3 / 2
  }
}

function lerp(a: number, b: number, t: number): number {
  return a + (b - a) * t
}

export function samplePair(
  keys: Keyframe[],
  tMs: number,
): { x: number; y: number } {
  if (!keys.length) return { x: 0, y: 0 }
  const sorted = [...keys].sort((a, b) => a.t_ms - b.t_ms)
  const first = sorted[0]
  const last = sorted[sorted.length - 1]
  const vx = (k: Keyframe) => k.value[0] ?? 0
  const vy = (k: Keyframe) => k.value[1] ?? k.value[0] ?? 0
  if (tMs <= first.t_ms) return { x: vx(first), y: vy(first) }
  if (tMs >= last.t_ms) return { x: vx(last), y: vy(last) }
  for (let i = 0; i + 1 < sorted.length; i++) {
    const a = sorted[i]
    const b = sorted[i + 1]
    if (tMs > b.t_ms) continue
    const span = b.t_ms - a.t_ms
    const u = span <= 0 ? 1 : (tMs - a.t_ms) / span
    const e = applyEase(parseEase(a.ease), u)
    return { x: lerp(vx(a), vx(b), e), y: lerp(vy(a), vy(b), e) }
  }
  return { x: vx(last), y: vy(last) }
}

export function sampleTransform(
  tracks: Track[],
  target: string,
  tMs: number,
): Transform {
  const xf: Transform = { ...IDENTITY }
  for (const track of tracks) {
    if (track.target !== target) continue
    const p = samplePair(track.keyframes ?? [], tMs)
    switch (track.channel) {
      case 'translate':
        xf.tx = p.x
        xf.ty = p.y
        break
      case 'scale':
        xf.sx = p.x
        xf.sy = p.y === 0 ? p.x : p.y
        break
      case 'rotate':
        xf.rotate_deg = p.x
        break
      case 'opacity':
        xf.opacity = p.x
        break
      default:
        break
    }
  }
  return xf
}

/** Worked example from RENDER.md: translate 0,40 → 0,0 over 800ms, linear. */
export const WORKED_KEYS: Keyframe[] = [
  { t_ms: 0, value: [0, 40], ease: 'linear' },
  { t_ms: 800, value: [0, 0], ease: 'linear' },
]
