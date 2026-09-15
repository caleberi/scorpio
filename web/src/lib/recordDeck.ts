import type { Cue, Deck, Soundtrack } from '@/lib/presentation'
import { durationOf } from '@/lib/presentation'
import { paintFrame, seekDeckVideos } from '@/lib/paintDeck'
import type { DeckAssets } from '@/lib/preloadDeck'

function pickMime(hasAudio: boolean): string | undefined {
  const candidates = hasAudio
    ? [
        'video/webm;codecs=vp9,opus',
        'video/webm;codecs=vp8,opus',
        'video/webm',
        'video/mp4',
      ]
    : ['video/webm;codecs=vp9', 'video/webm;codecs=vp8', 'video/webm', 'video/mp4']
  for (const type of candidates) {
    if (typeof MediaRecorder !== 'undefined' && MediaRecorder.isTypeSupported(type)) {
      return type
    }
  }
  return undefined
}

function mixTrack(
  ctx: AudioContext,
  dest: MediaStreamAudioDestinationNode,
  buffer: AudioBuffer,
  track: Soundtrack | Cue,
  origin: number,
) {
  const source = ctx.createBufferSource()
  source.buffer = buffer
  const gain = ctx.createGain()
  gain.gain.value = track.volume ?? 1
  source.connect(gain)
  gain.connect(dest)
  const startAt = origin + Math.max(0, (track.start_ms ?? 0) / 1000)
  const offset = Math.max(0, (track.offset_ms ?? 0) / 1000)
  source.start(startAt, offset)
}

function wait(ms: number): Promise<void> {
  return new Promise((resolve) => window.setTimeout(resolve, ms))
}

export async function recordDeck(
  canvas: HTMLCanvasElement,
  deck: Deck,
  assets: DeckAssets,
  onProgress?: (tMs: number) => void,
): Promise<Blob> {
  const fps = Math.max(1, deck.fps || 30)
  const dt = 1000 / fps
  const total = durationOf(deck)
  if (typeof MediaRecorder === 'undefined') {
    throw new Error('MediaRecorder is not available in this browser.')
  }

  const recordCanvas = document.createElement('canvas')
  recordCanvas.width = canvas.width || deck.size.w
  recordCanvas.height = canvas.height || deck.size.h
  const recordCtx = recordCanvas.getContext('2d')
  if (!recordCtx) throw new Error('Canvas 2d context is unavailable.')
  paintFrame(recordCtx, deck, 0, assets)

  let canvasStream: MediaStream
  try {
    canvasStream = recordCanvas.captureStream(fps)
  } catch (err) {
    const detail = err instanceof Error ? err.message : 'Canvas is not origin-clean.'
    throw new Error(detail)
  }
  const videoTrack = canvasStream.getVideoTracks()[0] as MediaStreamTrack & {
    requestFrame?: () => void
  }
  if (!videoTrack) throw new Error('Could not capture the canvas stream.')

  const hasAudio = [...assets.audio.values()].length > 0
  let audioCtx: AudioContext | null = null
  const tracks: MediaStreamTrack[] = [videoTrack]
  if (hasAudio) {
    audioCtx = new AudioContext()
    await audioCtx.resume().catch(() => undefined)
    const dest = audioCtx.createMediaStreamDestination()
    const origin = audioCtx.currentTime + 0.05
    if (deck.soundtrack?.url) {
      const buffer = assets.audio.get(deck.soundtrack.url)
      if (buffer) mixTrack(audioCtx, dest, buffer, deck.soundtrack, origin)
    }
    for (const slide of deck.slides) {
      for (const cue of slide.cues ?? []) {
        const buffer = assets.audio.get(cue.url)
        if (buffer) mixTrack(audioCtx, dest, buffer, cue, origin)
      }
    }
    const audioTrack = dest.stream.getAudioTracks()[0]
    if (audioTrack) tracks.push(audioTrack)
  }

  const mixed = new MediaStream(tracks)
  const mime = pickMime(tracks.length > 1)
  const recorder = mime
    ? new MediaRecorder(mixed, { mimeType: mime })
    : new MediaRecorder(mixed)

  const chunks: BlobPart[] = []
  recorder.ondataavailable = (event) => {
    if (event.data.size > 0) chunks.push(event.data)
  }
  const stopped = new Promise<void>((resolve, reject) => {
    recorder.onstop = () => resolve()
    recorder.onerror = () => reject(new Error('Recording failed.'))
  })

  recorder.start(200)
  await wait(80)

  for (let t = 0; t <= total; t += dt) {
    await seekDeckVideos(deck, assets, t)
    paintFrame(recordCtx, deck, t, assets)
    videoTrack.requestFrame?.()
    onProgress?.(t)
    await wait(dt)
  }

  if (recorder.state !== 'inactive') {
    try {
      recorder.requestData()
    } catch {
      /* not every browser implements requestData */
    }
    recorder.stop()
  }
  await stopped
  if (audioCtx) await audioCtx.close().catch(() => undefined)
  for (const track of mixed.getTracks()) track.stop()

  const blob = new Blob(chunks, { type: recorder.mimeType || mime || 'video/webm' })
  if (blob.size === 0) {
    throw new Error('Recording produced an empty file.')
  }
  return blob
}

export function downloadBlob(blob: Blob, name: string) {
  const url = URL.createObjectURL(blob)
  const link = document.createElement('a')
  link.href = url
  link.download = name
  link.click()
  window.setTimeout(() => URL.revokeObjectURL(url), 1000)
}
