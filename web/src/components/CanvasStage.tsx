import { useEffect, useRef, type RefObject } from 'react'
import type { Deck } from '@/lib/presentation'
import { paintFrame } from '@/lib/paintDeck'
import type { DeckAssets } from '@/lib/preloadDeck'
import { cn } from '@/lib/utils'

export function CanvasStage({
  deck,
  assets,
  tMs,
  canvasRef,
  className,
}: {
  deck: Deck
  assets: DeckAssets
  tMs: number
  canvasRef?: RefObject<HTMLCanvasElement | null>
  className?: string
}) {
  const localRef = useRef<HTMLCanvasElement>(null)
  const ref = canvasRef ?? localRef

  useEffect(() => {
    const canvas = ref.current
    const ctx = canvas?.getContext('2d')
    if (!canvas || !ctx) return
    if (canvas.width !== deck.size.w) canvas.width = deck.size.w
    if (canvas.height !== deck.size.h) canvas.height = deck.size.h
    paintFrame(ctx, deck, tMs, assets)
  }, [assets, canvasRef, deck, ref, tMs])

  return (
    <div
      className={cn(
        'flex max-h-[min(70vh,720px)] w-full items-center justify-center overflow-hidden border border-ink/30 bg-ink',
        className,
      )}
    >
      <canvas
        ref={ref}
        width={deck.size.w}
        height={deck.size.h}
        className="max-h-full max-w-full object-contain"
      />
    </div>
  )
}
