import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { Button } from '@/components/ui/button'
import { CanvasStage } from '@/components/CanvasStage'
import { interpolate } from '@/i18n'
import { useApp } from '@/lib/app-context'
import {
  DECK_VERSION,
  durationOf,
  formatClock,
  slideAt,
  slideTitle,
  type Deck,
} from '@/lib/presentation'
import { syncDeckVideos } from '@/lib/paintDeck'
import { disposeAssets, preloadDeck, type DeckAssets } from '@/lib/preloadDeck'
import { downloadBlob, recordDeck } from '@/lib/recordDeck'
import { cn } from '@/lib/utils'

const EMPTY_ASSETS: DeckAssets = {
  images: new Map(),
  bitmaps: new Map(),
  videos: new Map(),
  audio: new Map(),
  objectUrls: [],
}

export function PresentationPlayer({ deck }: { deck: Deck }) {
  const { t } = useApp()
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const [assets, setAssets] = useState<DeckAssets>(EMPTY_ASSETS)
  const [ready, setReady] = useState(false)
  const [index, setIndex] = useState(0)
  const [tMs, setTMs] = useState(0)
  const [playing, setPlaying] = useState(true)
  const [outline, setOutline] = useState(false)
  const [recording, setRecording] = useState(false)
  const [recordError, setRecordError] = useState<string | null>(null)
  const playingRef = useRef(playing)
  const indexRef = useRef(index)
  const tRef = useRef(tMs)

  playingRef.current = playing
  indexRef.current = index
  tRef.current = tMs

  const total = durationOf(deck)
  const slide = deck.slides[index]
  const unsupported = deck.version > DECK_VERSION

  useEffect(() => {
    let cancelled = false
    setReady(false)
    void preloadDeck(deck).then((next) => {
      if (cancelled) {
        disposeAssets(next)
        return
      }
      setAssets(next)
      setReady(true)
    })
    return () => {
      cancelled = true
    }
  }, [deck])

  useEffect(() => () => disposeAssets(assets), [assets])

  const seekSlide = useCallback(
    (next: number) => {
      const clamped = Math.min(Math.max(0, next), Math.max(0, deck.slides.length - 1))
      const start = deck.slides[clamped]?.start_ms ?? 0
      setIndex(clamped)
      setTMs(start)
    },
    [deck],
  )

  useEffect(() => {
    if (!playing || recording || unsupported || !ready) return
    let frame = 0
    let last = performance.now()
    const tick = (now: number) => {
      const dt = now - last
      last = now
      const nextT = Math.min(total, tRef.current + dt)
      syncDeckVideos(deck, assets, nextT, true)
      setTMs(nextT)
      if (nextT >= total) {
        setPlaying(false)
        return
      }
      frame = requestAnimationFrame(tick)
    }
    frame = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(frame)
  }, [assets, deck, playing, ready, recording, total, unsupported])

  useEffect(() => {
    if (!ready || recording) return
    syncDeckVideos(deck, assets, tMs, playing)
  }, [assets, deck, playing, ready, recording, tMs])

  useEffect(() => {
    setIndex(slideAt(deck, tMs))
  }, [deck, tMs])

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      const tag = (event.target as HTMLElement | null)?.tagName
      switch (tag) {
        case 'INPUT':
        case 'TEXTAREA':
          return
        default:
          if ((event.target as HTMLElement | null)?.isContentEditable) return
      }
      switch (event.key) {
        case 'ArrowRight':
          event.preventDefault()
          seekSlide(indexRef.current + 1)
          break
        case 'ArrowLeft':
          event.preventDefault()
          seekSlide(indexRef.current - 1)
          break
        case ' ':
          event.preventDefault()
          setPlaying((value) => !value)
          break
        case 'Home':
          event.preventDefault()
          seekSlide(0)
          break
        case 'End':
          event.preventDefault()
          seekSlide(deck.slides.length - 1)
          break
        case 't':
        case 'T':
          event.preventDefault()
          setOutline((value) => !value)
          break
        default:
          break
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [deck.slides.length, seekSlide])

  const progress = total > 0 ? Math.min(1, tMs / total) : 0

  const fileName = useMemo(
    () => `${deck.slug.replaceAll('/', '-')}.webm`,
    [deck.slug],
  )

  const onRecord = async () => {
    const canvas = canvasRef.current
    if (!canvas || !ready || recording) return
    setRecording(true)
    setPlaying(false)
    setRecordError(null)
    const blob = await recordDeck(canvas, deck, assets, (clock) => {
      setTMs(clock)
    }).catch((err: unknown) => {
      setRecordError(err instanceof Error ? err.message : t.slides.recordFailed)
      return null
    })
    setRecording(false)
    if (blob) downloadBlob(blob, fileName)
  }

  if (unsupported) {
    return (
      <p className="mt-6 font-mono text-sm text-red-700">
        {interpolate(t.slides.unsupportedVersion, { n: deck.version })}
      </p>
    )
  }

  return (
    <div className="relative">
      {!ready && (
        <p className="mb-4 font-mono text-sm text-muted">{t.slides.loading}</p>
      )}
      <CanvasStage deck={deck} assets={assets} tMs={tMs} canvasRef={canvasRef} />
      {recordError ? (
        <p className="mt-3 font-mono text-sm text-red-700">{recordError}</p>
      ) : null}

      <div className="mt-4 flex flex-wrap items-center gap-2 font-mono text-[13px] uppercase tracking-wide">
        <Button
          type="button"
          variant="outline"
          size="sm"
          onClick={() => seekSlide(index - 1)}
          disabled={index <= 0}
        >
          ←
        </Button>
        <Button
          type="button"
          variant="outline"
          size="sm"
          onClick={() => setPlaying((value) => !value)}
        >
          {playing ? 'Pause' : 'Play'}
        </Button>
        <Button
          type="button"
          variant="outline"
          size="sm"
          onClick={() => seekSlide(index + 1)}
          disabled={index >= deck.slides.length - 1}
        >
          →
        </Button>
        <Button
          type="button"
          variant="outline"
          size="sm"
          onClick={() => setOutline((value) => !value)}
        >
          {t.slides.outline}
        </Button>
        <Button
          type="button"
          variant="outline"
          size="sm"
          onClick={() => void onRecord()}
          disabled={!ready || recording}
        >
          {recording ? t.slides.recording : t.slides.record}
        </Button>
        <span className="ml-auto text-muted">
          {formatClock(tMs)} / {formatClock(total)}
          {slide ? ` · ${slideTitle(slide)}` : ''}
        </span>
      </div>

      <div className="mt-3 h-1.5 w-full bg-ink/15">
        <div className="h-full bg-ink" style={{ width: `${progress * 100}%` }} />
      </div>

      {outline && (
        <aside className="mt-6 border border-ink/30 bg-surface p-4">
          <div className="section-label mb-3">{t.slides.outline}</div>
          <ol className="space-y-1 font-mono text-sm">
            {deck.slides.map((item, i) => (
              <li key={item.id}>
                <button
                  type="button"
                  className={cn(
                    'w-full rounded px-2 py-1 text-left hover:bg-ink/[0.06]',
                    i === index && 'bg-accent/40',
                  )}
                  onClick={() => seekSlide(i)}
                >
                  {String(i + 1).padStart(2, '0')} · {slideTitle(item)}
                </button>
              </li>
            ))}
          </ol>
        </aside>
      )}
    </div>
  )
}
