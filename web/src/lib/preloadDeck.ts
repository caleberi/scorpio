import { createElement } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { flushSync } from 'react-dom'
import ReactMarkdown from 'react-markdown'
import remarkGfm from 'remark-gfm'
import rehypeRaw from 'rehype-raw'
import mermaid from 'mermaid'
import type { Cue, Deck, Font, Node, Soundtrack } from '@/lib/presentation'
import { API_MEDIA } from '@/lib/constants'

export type DeckAssets = {
  images: Map<string, ImageBitmap>
  bitmaps: Map<string, ImageBitmap>
  videos: Map<string, HTMLVideoElement>
  audio: Map<string, AudioBuffer>
  objectUrls: string[]
}

let mermaidReady = false

function ensureMermaid() {
  if (mermaidReady) return
  mermaid.initialize({
    startOnLoad: false,
    securityLevel: 'loose',
    theme: 'dark',
    fontFamily: 'IBM Plex Mono, ui-monospace, monospace',
    flowchart: { htmlLabels: false, useMaxWidth: false },
    sequence: { useMaxWidth: false },
  })
  mermaidReady = true
}

function sameOriginMedia(src: string): string {
  if (!src || src.startsWith('blob:') || src.startsWith('data:') || src.startsWith('/')) {
    return src
  }
  try {
    const url = new URL(src, window.location.href)
    if (url.origin === window.location.origin) return src
    if (url.protocol !== 'http:' && url.protocol !== 'https:') return src
    return `${API_MEDIA}?u=${encodeURIComponent(url.href)}`
  } catch {
    return src
  }
}

async function blobUrlFor(src: string, objectUrls: string[]): Promise<string> {
  const proxied = sameOriginMedia(src)
  if (proxied === src) return src
  const res = await fetch(proxied).catch(() => null)
  if (!res?.ok) return src
  const type = (res.headers.get('content-type') ?? '').toLowerCase()
  if (type.includes('text/html')) return src
  const blob = await res.blob().catch(() => null)
  if (!blob || blob.size === 0) return src
  if ((blob.type || type).includes('text/html')) return src
  const url = URL.createObjectURL(blob)
  objectUrls.push(url)
  return url
}

function loadImage(src: string, cors: boolean): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const img = new Image()
    if (cors) img.crossOrigin = 'anonymous'
    img.onload = () => resolve(img)
    img.onerror = () => reject(new Error(`image failed: ${src}`))
    img.src = src
  })
}

async function loadImageAny(src: string): Promise<HTMLImageElement | null> {
  const withCors = await loadImage(src, true).catch(() => null)
  if (withCors) return withCors
  return loadImage(src, false).catch(() => null)
}

function loadVideo(src: string): Promise<HTMLVideoElement> {
  return new Promise((resolve, reject) => {
    const video = document.createElement('video')
    video.muted = true
    video.playsInline = true
    video.preload = 'auto'
    video.src = src
    const done = () => {
      video.removeEventListener('loadeddata', done)
      video.removeEventListener('error', fail)
      resolve(video)
    }
    const fail = () => {
      video.removeEventListener('loadeddata', done)
      video.removeEventListener('error', fail)
      reject(new Error(`video failed: ${src}`))
    }
    video.addEventListener('loadeddata', done)
    video.addEventListener('error', fail)
    video.load()
  })
}

function prepareSvg(svg: string): string {
  let out = svg.trim().replace(/<br\s*>/gi, '<br/>')
  if (!out.includes('xmlns=')) {
    out = out.replace(
      /<svg\b/i,
      '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"',
    )
  }
  return `<?xml version="1.0" encoding="UTF-8"?>${out}`
}

async function svgToBitmap(svg: string): Promise<ImageBitmap | null> {
  const prepared = prepareSvg(svg)
  const url = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(prepared)}`
  const img = await loadImage(url, false).catch(() => null)
  if (!img) return null
  return createImageBitmap(img).catch(() => null)
}

function waitFrames(n = 2): Promise<void> {
  return new Promise((resolve) => {
    const step = (left: number) => {
      if (left <= 0) {
        resolve()
        return
      }
      requestAnimationFrame(() => step(left - 1))
    }
    step(n)
  })
}

function bitmapHasInk(bitmap: ImageBitmap): boolean {
  if (typeof document === 'undefined') return true
  const canvas = document.createElement('canvas')
  canvas.width = Math.max(1, Math.min(bitmap.width, 96))
  canvas.height = Math.max(1, Math.min(bitmap.height, 96))
  const ctx = canvas.getContext('2d', { willReadFrequently: true })
  if (!ctx) return true
  ctx.drawImage(bitmap, 0, 0, canvas.width, canvas.height)
  const data = ctx.getImageData(0, 0, canvas.width, canvas.height).data
  for (let i = 3; i < data.length; i += 4) {
    if (data[i] > 12) return true
  }
  return false
}

function fontCss(font?: Font, fill?: string): string {
  const size = font?.size_px ?? 28
  const weight = font?.weight ?? 400
  const family = font?.family ?? 'Inter, system-ui, sans-serif'
  const color = fill && fill.length > 0 ? fill : '#eef1f7'
  return `color:${color};font:${weight} ${size}px ${family};line-height:1.35`
}

async function rasterizeMarkdown(node: Node): Promise<ImageBitmap | null> {
  const text = node.text?.trim()
  if (!text) return null
  const host = document.createElement('div')
  host.setAttribute('xmlns', 'http://www.w3.org/1999/xhtml')
  const extra = node.style ? `;${node.style}` : ''
  host.style.cssText = [
    'position:fixed',
    'left:-12000px',
    'top:0',
    `width:${node.bounds.w}px`,
    `height:${node.bounds.h}px`,
    'overflow:hidden',
    'background:transparent',
    fontCss(node.font, node.fill),
    extra,
  ].join(';')
  document.body.appendChild(host)

  let root: Root | null = null
  try {
    root = createRoot(host)
    flushSync(() => {
      root?.render(
        createElement(
          'div',
          {
            xmlns: 'http://www.w3.org/1999/xhtml',
            style: {
              color: node.fill || '#eef1f7',
              fontSize: node.font?.size_px ?? 28,
              fontFamily: node.font?.family,
              fontWeight: node.font?.weight,
              lineHeight: 1.35,
            },
          },
          createElement(
            ReactMarkdown,
            { remarkPlugins: [remarkGfm], rehypePlugins: [rehypeRaw] },
            text,
          ),
        ),
      )
    })
    await waitFrames(2)
    const w = Math.max(1, Math.round(node.bounds.w))
    const h = Math.max(1, Math.round(node.bounds.h))
    const inner = host.innerHTML
      .replace(/<br\s*>/gi, '<br/>')
      .replace(/&nbsp;/g, '&#160;')
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}">
      <foreignObject width="100%" height="100%">
        <div xmlns="http://www.w3.org/1999/xhtml" style="width:${w}px;height:${h}px;overflow:hidden;${fontCss(node.font, node.fill)}">${inner}</div>
      </foreignObject>
    </svg>`
    const bitmap = await svgToBitmap(svg)
    if (!bitmap || !bitmapHasInk(bitmap)) {
      bitmap?.close()
      return null
    }
    return bitmap
  } catch {
    return null
  } finally {
    root?.unmount()
    host.remove()
  }
}

async function rasterizeMermaid(node: Node, index: number): Promise<ImageBitmap | null> {
  const source = node.source?.trim()
  if (!source) return null
  ensureMermaid()
  const id = `deck-mermaid-${index}-${node.id.replace(/[^a-zA-Z0-9_-]/g, '')}`
  const rendered = await mermaid.render(id, source).catch(() => null)
  if (!rendered) return null
  return svgToBitmap(rendered.svg)
}

async function decodeAudio(ctx: AudioContext, url: string): Promise<AudioBuffer | null> {
  const res = await fetch(url).catch(() => null)
  if (!res?.ok) return null
  const bytes = await res.arrayBuffer().catch(() => null)
  if (!bytes) return null
  return ctx.decodeAudioData(bytes.slice(0)).catch(() => null)
}

function audioUrls(deck: Deck): string[] {
  const urls: string[] = []
  const push = (track?: Soundtrack | Cue | null) => {
    if (track?.url) urls.push(track.url)
  }
  push(deck.soundtrack)
  for (const slide of deck.slides) {
    for (const cue of slide.cues ?? []) push(cue)
  }
  return [...new Set(urls)]
}

export async function preloadDeck(deck: Deck): Promise<DeckAssets> {
  const images = new Map<string, ImageBitmap>()
  const bitmaps = new Map<string, ImageBitmap>()
  const videos = new Map<string, HTMLVideoElement>()
  const audio = new Map<string, AudioBuffer>()
  const objectUrls: string[] = []

  if (typeof document !== 'undefined' && 'fonts' in document) {
    await document.fonts.ready.catch(() => undefined)
  }

  const mediaSrcs: { src: string; preferVideo: boolean }[] = []
  const markdownNodes: Node[] = []
  const mermaidNodes: Node[] = []
  for (const slide of deck.slides) {
    for (const node of slide.nodes) {
      if ((node.kind === 'image' || node.kind === 'video') && node.src) {
        mediaSrcs.push({ src: node.src, preferVideo: node.kind === 'video' })
      }
      if (node.kind === 'markdown') markdownNodes.push(node)
      if (node.kind === 'mermaid') mermaidNodes.push(node)
    }
  }

  await Promise.all(
    mediaSrcs.map(async ({ src, preferVideo }) => {
      if (images.has(src) || videos.has(src)) return
      const local = await blobUrlFor(src, objectUrls)
      if (!preferVideo) {
        const img = await loadImageAny(local)
        if (img) {
          const bitmap = await createImageBitmap(img).catch(() => null)
          if (bitmap) {
            images.set(src, bitmap)
            return
          }
        }
      }
      const video = await loadVideo(local).catch(() => null)
      if (video) videos.set(src, video)
    }),
  )

  await Promise.all(
    mermaidNodes.map(async (node, index) => {
      const bitmap = await rasterizeMermaid(node, index)
      if (bitmap) bitmaps.set(node.id, bitmap)
    }),
  )

  await Promise.all(
    markdownNodes.map(async (node) => {
      const bitmap = await rasterizeMarkdown(node)
      if (bitmap) bitmaps.set(node.id, bitmap)
    }),
  )

  const urls = audioUrls(deck)
  if (urls.length > 0) {
    const ctx = new AudioContext()
    try {
      await Promise.all(
        urls.map(async (url) => {
          const buffer = await decodeAudio(ctx, await blobUrlFor(url, objectUrls))
          if (buffer) audio.set(url, buffer)
        }),
      )
    } finally {
      await ctx.close().catch(() => undefined)
    }
  }

  return { images, bitmaps, videos, audio, objectUrls }
}

export function disposeAssets(assets: DeckAssets) {
  for (const bitmap of assets.images.values()) bitmap.close()
  for (const bitmap of assets.bitmaps.values()) bitmap.close()
  for (const video of assets.videos.values()) {
    video.pause()
    video.removeAttribute('src')
    video.load()
  }
  for (const url of assets.objectUrls ?? []) URL.revokeObjectURL(url)
  assets.images.clear()
  assets.bitmaps.clear()
  assets.videos.clear()
  assets.audio.clear()
  assets.objectUrls = []
}
