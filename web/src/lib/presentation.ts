export const DECK_VERSION = 1

export type Size = { w: number; h: number }

export type Font = {
  family: string
  size_px: number
  weight: number
}

export type Bounds = { x: number; y: number; w: number; h: number }

export type Origin = { x: number; y: number }

export type Node = {
  id: string
  kind: string
  bounds: Bounds
  z?: number
  src?: string
  text?: string
  fill?: string
  stroke?: string
  stroke_width?: number
  shape?: string
  fit?: string
  font?: Font
  headers?: string[]
  rows?: string[][]
  source?: string
  clip?: boolean
  children?: string[]
  origin?: Origin | null
  style?: string
}

export type Keyframe = {
  t_ms: number
  value: number[]
  ease?: string
}

export type Track = {
  target: string
  channel: string
  keyframes: Keyframe[]
}

export type Cue = {
  url: string
  start_ms?: number
  offset_ms?: number
  volume?: number
}

export type Soundtrack = {
  url: string
  start_ms?: number
  offset_ms?: number
  volume?: number
}

export type Transition = {
  kind?: string
  duration_ms?: number
}

export type SlideCanvas = {
  width: number
  height: number
  background?: string
}

export type Slide = {
  id: string
  start_ms: number
  duration_ms: number
  transition?: Transition
  canvas: SlideCanvas
  nodes: Node[]
  tracks: Track[]
  cues?: Cue[]
}

export type Deck = {
  version: number
  slug: string
  title: string
  path: string
  fps: number
  size: Size
  soundtrack?: Soundtrack | null
  slides: Slide[]
}

export type PresentationListing = {
  slug: string
  title: string
  path: string
  duration_ms: number
  size: Size
}

export type Transform = {
  tx: number
  ty: number
  sx: number
  sy: number
  rotate_deg: number
  opacity: number
}

export const IDENTITY: Transform = {
  tx: 0,
  ty: 0,
  sx: 1,
  sy: 1,
  rotate_deg: 0,
  opacity: 1,
}

export function durationOf(deck: Deck): number {
  if (!deck.slides.length) return 0
  const last = deck.slides[deck.slides.length - 1]
  return last.start_ms + last.duration_ms
}

export function slideAt(deck: Deck, tMs: number): number {
  if (!deck.slides.length) return 0
  let idx = 0
  for (let i = 0; i < deck.slides.length; i++) {
    if (deck.slides[i].start_ms <= tMs) idx = i
  }
  return idx
}

export function formatClock(ms: number): string {
  const total = Math.max(0, Math.round(ms / 1000))
  const m = Math.floor(total / 60)
  const s = total % 60
  return `${m}:${String(s).padStart(2, '0')}`
}

export function slideTitle(slide: Slide): string {
  const heading = slide.nodes.find((node) => node.kind === 'text' && node.text)
  return heading?.text?.trim() || slide.id
}
