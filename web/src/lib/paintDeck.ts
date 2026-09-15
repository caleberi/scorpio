import type { Bounds, Deck, Node, Slide, Transform } from '@/lib/presentation'
import { durationOf, slideAt } from '@/lib/presentation'
import { sampleTransform } from '@/lib/sampleTrack'
import type { DeckAssets } from '@/lib/preloadDeck'

function cssColor(value: string | undefined, fallback = '#0a0d14'): string {
  return value && value.length > 0 ? value : fallback
}

function quoteFamily(family: string): string {
  return family
    .split(',')
    .map((part) => {
      const name = part.trim()
      if (!name) return ''
      if (/^[a-zA-Z-]+$/.test(name)) return name
      return `"${name.replaceAll('"', '')}"`
    })
    .filter(Boolean)
    .join(', ')
}

function canvasFont(family: string, size: number, weight: number): string {
  return `${weight} ${size}px ${quoteFamily(family)}`
}

function originOf(node: Node): { x: number; y: number } {
  if (node.origin) return node.origin
  return {
    x: node.bounds.x + node.bounds.w / 2,
    y: node.bounds.y + node.bounds.h / 2,
  }
}

function wrapLines(
  ctx: CanvasRenderingContext2D,
  text: string,
  maxWidth: number,
): string[] {
  const lines: string[] = []
  for (const paragraph of text.split('\n')) {
    const words = paragraph.split(/\s+/).filter(Boolean)
    if (!words.length) {
      lines.push('')
      continue
    }
    let current = ''
    for (const word of words) {
      const next = current ? `${current} ${word}` : word
      if (ctx.measureText(next).width <= maxWidth || !current) {
        current = next
        continue
      }
      lines.push(current)
      current = word
    }
    if (current) lines.push(current)
  }
  return lines.length ? lines : ['']
}

function stripInline(text: string): string {
  return text
    .replace(/\*\*([^*]+)\*\*/g, '$1')
    .replace(/\*([^*]+)\*/g, '$1')
    .replace(/`([^`]+)`/g, '$1')
    .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
}

function applyNodeTransform(
  ctx: CanvasRenderingContext2D,
  node: Node,
  xf: Transform,
  extra: { alpha: number; tx: number; ty: number },
) {
  const origin = originOf(node)
  ctx.globalAlpha = xf.opacity * extra.alpha
  ctx.translate(origin.x + xf.tx + extra.tx, origin.y + xf.ty + extra.ty)
  ctx.rotate((xf.rotate_deg * Math.PI) / 180)
  ctx.scale(xf.sx, xf.sy)
  ctx.translate(-node.bounds.w / 2, -node.bounds.h / 2)
}

function fitRect(
  bounds: Bounds,
  srcW: number,
  srcH: number,
  fit: string | undefined,
): { dx: number; dy: number; dw: number; dh: number } {
  if (fit === 'stretch' || srcW <= 0 || srcH <= 0) {
    return { dx: 0, dy: 0, dw: bounds.w, dh: bounds.h }
  }
  const scale =
    fit === 'cover'
      ? Math.max(bounds.w / srcW, bounds.h / srcH)
      : Math.min(bounds.w / srcW, bounds.h / srcH)
  const dw = srcW * scale
  const dh = srcH * scale
  return {
    dx: (bounds.w - dw) / 2,
    dy: (bounds.h - dh) / 2,
    dw,
    dh,
  }
}

function clipNode(ctx: CanvasRenderingContext2D, node: Node) {
  ctx.beginPath()
  ctx.rect(0, 0, node.bounds.w, node.bounds.h)
  ctx.clip()
}

function drawText(ctx: CanvasRenderingContext2D, node: Node) {
  const font = node.font
  const size = font?.size_px ?? 32
  const weight = font?.weight ?? 400
  const family = font?.family ?? 'Inter, system-ui, sans-serif'
  ctx.save()
  clipNode(ctx, node)
  ctx.fillStyle = cssColor(node.fill, '#eef1f7')
  ctx.font = canvasFont(family, size, weight)
  ctx.textBaseline = 'top'
  const lines = wrapLines(ctx, stripInline(node.text ?? ''), node.bounds.w)
  const lineHeight = size * 1.25
  for (let i = 0; i < lines.length; i++) {
    const y = i * lineHeight
    if (y >= node.bounds.h) break
    ctx.fillText(lines[i], 0, y)
  }
  ctx.restore()
}

function drawMarkdown(ctx: CanvasRenderingContext2D, node: Node) {
  const font = node.font
  const size = font?.size_px ?? 28
  const weight = font?.weight ?? 400
  const family = font?.family ?? 'Inter, system-ui, sans-serif'
  ctx.save()
  clipNode(ctx, node)
  ctx.fillStyle = cssColor(node.fill, '#eef1f7')
  ctx.textBaseline = 'top'
  const lineHeight = size * 1.35
  let y = 0
  for (const raw of (node.text ?? '').split('\n')) {
    const bullet = raw.match(/^(\s*)([-*]|\d+\.)\s+(.*)$/)
    const indent = bullet ? 28 : 0
    const body = stripInline(bullet ? bullet[3] : raw)
    ctx.font = canvasFont(family, size, weight)
    if (bullet) {
      ctx.fillText('•', 0, y)
    }
    const wrapped = wrapLines(ctx, body, node.bounds.w - indent)
    for (const line of wrapped) {
      if (y >= node.bounds.h) break
      const bold = /\*\*/.test(raw)
      ctx.font = canvasFont(family, size, bold ? 700 : weight)
      ctx.fillText(line, indent, y)
      y += lineHeight
    }
    if (!raw.trim()) y += lineHeight * 0.35
  }
  ctx.restore()
}

function drawShape(ctx: CanvasRenderingContext2D, node: Node) {
  ctx.beginPath()
  if (node.shape === 'ellipse') {
    ctx.ellipse(
      node.bounds.w / 2,
      node.bounds.h / 2,
      node.bounds.w / 2,
      node.bounds.h / 2,
      0,
      0,
      Math.PI * 2,
    )
  } else {
    ctx.rect(0, 0, node.bounds.w, node.bounds.h)
  }
  if (node.fill) {
    ctx.fillStyle = node.fill
    ctx.fill()
  }
  if (node.stroke && (node.stroke_width ?? 0) > 0) {
    ctx.strokeStyle = node.stroke
    ctx.lineWidth = node.stroke_width ?? 1
    ctx.stroke()
  }
}

function drawTable(ctx: CanvasRenderingContext2D, node: Node) {
  const headers = node.headers ?? []
  const rows = node.rows ?? []
  const cols = Math.max(headers.length, ...rows.map((row) => row.length), 1)
  const totalRows = rows.length + (headers.length ? 1 : 0)
  if (totalRows === 0) return
  const cellW = node.bounds.w / cols
  const cellH = node.bounds.h / totalRows
  const font = node.font
  const size = Math.min(font?.size_px ?? 22, cellH * 0.45)
  const family = font?.family ?? 'IBM Plex Mono, ui-monospace, monospace'
  ctx.strokeStyle = node.stroke || 'rgba(238,241,247,0.35)'
  ctx.lineWidth = node.stroke_width || 1
  ctx.textBaseline = 'middle'
  ctx.fillStyle = cssColor(node.fill, '#eef1f7')

  const paintCell = (text: string, col: number, row: number, bold: boolean) => {
    const x = col * cellW
    const y = row * cellH
    ctx.strokeRect(x, y, cellW, cellH)
    ctx.font = canvasFont(family, size, bold ? 700 : 400)
    const lines = wrapLines(ctx, stripInline(text), cellW - 16)
    const startY = y + cellH / 2 - ((lines.length - 1) * size * 1.1) / 2
    for (let i = 0; i < lines.length; i++) {
      ctx.fillText(lines[i], x + 8, startY + i * size * 1.1)
    }
  }

  let rowIndex = 0
  if (headers.length) {
    for (let c = 0; c < cols; c++) paintCell(headers[c] ?? '', c, 0, true)
    rowIndex = 1
  }
  for (let r = 0; r < rows.length; r++) {
    for (let c = 0; c < cols; c++) {
      paintCell(rows[r]?.[c] ?? '', c, rowIndex + r, false)
    }
  }
}

function drawBitmap(
  ctx: CanvasRenderingContext2D,
  node: Node,
  bitmap: ImageBitmap,
  fit?: string,
) {
  const dest = fitRect(node.bounds, bitmap.width, bitmap.height, fit)
  ctx.save()
  clipNode(ctx, node)
  ctx.drawImage(bitmap, dest.dx, dest.dy, dest.dw, dest.dh)
  ctx.restore()
}

function drawVideo(ctx: CanvasRenderingContext2D, node: Node, video: HTMLVideoElement) {
  const srcW = video.videoWidth
  const srcH = video.videoHeight
  if (srcW <= 0 || srcH <= 0) return
  const dest = fitRect(node.bounds, srcW, srcH, node.fit)
  ctx.save()
  clipNode(ctx, node)
  ctx.drawImage(video, dest.dx, dest.dy, dest.dw, dest.dh)
  ctx.restore()
}

function drawNode(
  ctx: CanvasRenderingContext2D,
  slide: Slide,
  node: Node,
  tMs: number,
  assets: DeckAssets,
  extra: { alpha: number; tx: number; ty: number },
) {
  const xf = sampleTransform(slide.tracks, node.id, tMs)
  if (xf.opacity * extra.alpha <= 0) return

  ctx.save()
  applyNodeTransform(ctx, node, xf, extra)
  if (node.kind === 'group' && node.clip) {
    clipNode(ctx, node)
  }

  switch (node.kind) {
    case 'text':
      drawText(ctx, node)
      break
    case 'shape':
      drawShape(ctx, node)
      break
    case 'table':
      drawTable(ctx, node)
      break
    case 'image': {
      const bitmap = assets.images.get(node.src ?? '') ?? assets.bitmaps.get(node.id)
      if (bitmap) drawBitmap(ctx, node, bitmap, node.fit)
      else {
        const video = assets.videos.get(node.src ?? '')
        if (video) drawVideo(ctx, node, video)
      }
      break
    }
    case 'video': {
      const video = assets.videos.get(node.src ?? '')
      if (video) drawVideo(ctx, node, video)
      else {
        const bitmap = assets.images.get(node.src ?? '')
        if (bitmap) drawBitmap(ctx, node, bitmap, node.fit)
      }
      break
    }
    case 'mermaid': {
      const bitmap = assets.bitmaps.get(node.id)
      if (bitmap) drawBitmap(ctx, node, bitmap, node.fit || 'contain')
      else if (node.source) {
        const fallback: Node = { ...node, kind: 'text', text: node.source, font: node.font }
        drawText(ctx, fallback)
      }
      break
    }
    case 'markdown': {
      const bitmap = assets.bitmaps.get(node.id)
      if (bitmap) drawBitmap(ctx, node, bitmap, 'stretch')
      else if (node.text) drawMarkdown(ctx, node)
      break
    }
    case 'group':
      for (const childId of node.children ?? []) {
        const child = slide.nodes.find((item) => item.id === childId)
        if (child) drawNode(ctx, slide, child, tMs, assets, { alpha: 1, tx: 0, ty: 0 })
      }
      break
    default:
      break
  }
  ctx.restore()
}

function paintSlide(
  ctx: CanvasRenderingContext2D,
  deck: Deck,
  slide: Slide,
  tMs: number,
  assets: DeckAssets,
  extra: { alpha: number; tx: number; ty: number },
) {
  ctx.save()
  ctx.globalAlpha = extra.alpha
  ctx.translate(extra.tx, extra.ty)
  ctx.fillStyle = cssColor(slide.canvas.background)
  ctx.fillRect(0, 0, deck.size.w, deck.size.h)
  const nodes = [...slide.nodes].sort((a, b) => (a.z ?? 0) - (b.z ?? 0))
  for (const node of nodes) {
    drawNode(ctx, slide, node, tMs, assets, { alpha: 1, tx: 0, ty: 0 })
  }
  ctx.restore()
}

let fadeA: HTMLCanvasElement | null = null
let fadeB: HTMLCanvasElement | null = null

function scratch(slot: 0 | 1, w: number, h: number): HTMLCanvasElement | null {
  if (typeof document === 'undefined') return null
  const current = slot === 0 ? fadeA : fadeB
  if (current && current.width === w && current.height === h) return current
  const canvas = document.createElement('canvas')
  canvas.width = w
  canvas.height = h
  if (slot === 0) fadeA = canvas
  else fadeB = canvas
  return canvas
}

function videosOnSlide(slide: Slide | null | undefined, assets: DeckAssets): HTMLVideoElement[] {
  if (!slide) return []
  const out: HTMLVideoElement[] = []
  for (const node of slide.nodes) {
    if (node.kind !== 'video' && node.kind !== 'image') continue
    const video = assets.videos.get(node.src ?? '')
    if (video) out.push(video)
  }
  return out
}

function targetTime(video: HTMLVideoElement, tMs: number, slideStart: number): number {
  const local = Math.max(0, (tMs - slideStart) / 1000)
  const duration = Number.isFinite(video.duration) ? video.duration : 0
  return duration > 0 ? Math.min(local, Math.max(0, duration - 0.04)) : local
}

/** Keep attached videos in wall-clock sync without seeking every paint. */
export function syncDeckVideos(
  deck: Deck,
  assets: DeckAssets,
  tMs: number,
  playing: boolean,
) {
  const idx = slideAt(deck, tMs)
  const slide = deck.slides[idx]
  const prev = idx > 0 ? deck.slides[idx - 1] : null
  const dur = slide?.transition?.duration_ms ?? 0
  const kind = slide?.transition?.kind ?? 'none'
  const overlap =
    prev &&
    kind !== 'none' &&
    dur > 0 &&
    tMs < (slide?.start_ms ?? 0) + dur
  const active = new Set<HTMLVideoElement>()

  const drive = (s: Slide | null | undefined) => {
    if (!s) return
    for (const video of videosOnSlide(s, assets)) {
      active.add(video)
      const target = targetTime(video, tMs, s.start_ms)
      const drift = Math.abs((video.currentTime || 0) - target)
      if (!playing) {
        if (!video.paused) video.pause()
        if (drift > 1 / 24) {
          try {
            video.currentTime = target
          } catch {
            /* seek can throw while loading */
          }
        }
        continue
      }
      if (video.paused) {
        try {
          video.currentTime = target
        } catch {
          /* ignore */
        }
        void video.play().catch(() => undefined)
      } else if (drift > 0.35) {
        try {
          video.currentTime = target
        } catch {
          /* ignore */
        }
      }
    }
  }

  drive(slide)
  if (overlap) drive(prev)

  for (const video of assets.videos.values()) {
    if (!active.has(video) && !video.paused) video.pause()
  }
}

export async function seekDeckVideos(
  deck: Deck,
  assets: DeckAssets,
  tMs: number,
): Promise<void> {
  const idx = slideAt(deck, tMs)
  const slide = deck.slides[idx]
  if (!slide) return
  const waits: Promise<void>[] = []
  for (const video of videosOnSlide(slide, assets)) {
    if (video.readyState < 1) continue
    const target = targetTime(video, tMs, slide.start_ms)
    if (Math.abs((video.currentTime || 0) - target) <= 0.02) continue
    waits.push(
      new Promise((resolve) => {
        const done = () => {
          video.removeEventListener('seeked', done)
          resolve()
        }
        video.addEventListener('seeked', done)
        try {
          video.currentTime = target
        } catch {
          done()
          return
        }
        window.setTimeout(done, 120)
      }),
    )
  }
  if (waits.length) await Promise.all(waits)
}

export function paintFrame(
  ctx: CanvasRenderingContext2D,
  deck: Deck,
  tMs: number,
  assets: DeckAssets,
) {
  const total = durationOf(deck)
  const clamped = total <= 0 ? 0 : Math.min(Math.max(0, tMs), total)
  const idx = slideAt(deck, clamped)
  const slide = deck.slides[idx]
  if (!slide) {
    ctx.fillStyle = '#0a0d14'
    ctx.fillRect(0, 0, deck.size.w, deck.size.h)
    return
  }

  const trans = slide.transition
  const dur = trans?.duration_ms ?? 0
  const kind = trans?.kind ?? 'none'
  const prev = idx > 0 ? deck.slides[idx - 1] : null
  const inOverlap =
    prev &&
    kind !== 'none' &&
    dur > 0 &&
    clamped < slide.start_ms + dur

  ctx.setTransform(1, 0, 0, 1, 0, 0)
  ctx.globalAlpha = 1
  ctx.clearRect(0, 0, deck.size.w, deck.size.h)

  if (inOverlap && prev) {
    const p = Math.min(1, Math.max(0, (clamped - slide.start_ms) / dur))
    if (kind === 'fade') {
      const a = scratch(0, deck.size.w, deck.size.h)
      const b = scratch(1, deck.size.w, deck.size.h)
      const aCtx = a?.getContext('2d')
      const bCtx = b?.getContext('2d')
      if (a && b && aCtx && bCtx) {
        aCtx.setTransform(1, 0, 0, 1, 0, 0)
        bCtx.setTransform(1, 0, 0, 1, 0, 0)
        aCtx.globalAlpha = 1
        bCtx.globalAlpha = 1
        paintSlide(aCtx, deck, prev, clamped, assets, { alpha: 1, tx: 0, ty: 0 })
        paintSlide(bCtx, deck, slide, clamped, assets, { alpha: 1, tx: 0, ty: 0 })
        ctx.globalAlpha = 1
        ctx.drawImage(a, 0, 0)
        ctx.globalAlpha = p
        ctx.drawImage(b, 0, 0)
        ctx.globalAlpha = 1
        return
      }
      paintSlide(ctx, deck, prev, clamped, assets, { alpha: 1, tx: 0, ty: 0 })
      paintSlide(ctx, deck, slide, clamped, assets, { alpha: p, tx: 0, ty: 0 })
      return
    }
    if (kind === 'slide_left') {
      paintSlide(ctx, deck, prev, clamped, assets, {
        alpha: 1,
        tx: -deck.size.w * p,
        ty: 0,
      })
      paintSlide(ctx, deck, slide, clamped, assets, {
        alpha: 1,
        tx: deck.size.w * (1 - p),
        ty: 0,
      })
      return
    }
  }

  paintSlide(ctx, deck, slide, clamped, assets, { alpha: 1, tx: 0, ty: 0 })
}
