import { useEffect, useRef, useState, type RefObject } from 'react'
import { flushSync } from 'react-dom'

type ViewTransition = {
  finished: Promise<void>
}

function startViewTransition(update: () => void): ViewTransition | null {
  if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
    update()
    return null
  }

  const doc = document as Document & {
    startViewTransition?: (cb: () => void) => ViewTransition
  }
  if (typeof doc.startViewTransition !== 'function') {
    update()
    return null
  }

  return doc.startViewTransition(update)
}

/**
 * Keep the full-width title until the user has scrolled into the article.
 * Hysteresis avoids flipping back when the title docks into the sticky rail.
 * View Transitions morph the cover/title so the grid change does not snap.
 */
export function useReadingLayout(titleRef: RefObject<HTMLElement | null>) {
  const [reading, setReading] = useState(false)
  const readingRef = useRef(false)
  const runningRef = useRef(false)
  const queuedRef = useRef<boolean | null>(null)

  useEffect(() => {
    const commit = (next: boolean) => {
      readingRef.current = next
      flushSync(() => setReading(next))
    }

    const apply = (next: boolean) => {
      if (next === readingRef.current && !runningRef.current) return
      if (runningRef.current) {
        queuedRef.current = next
        return
      }

      const vt = startViewTransition(() => commit(next))
      if (!vt) return

      runningRef.current = true
      void vt.finished.finally(() => {
        runningRef.current = false
        const queued = queuedRef.current
        queuedRef.current = null
        if (queued !== null && queued !== readingRef.current) apply(queued)
      })
    }

    const onScroll = () => {
      const titleH = titleRef.current?.offsetHeight ?? 280
      const enterAt = Math.max(titleH * 0.45, 160)
      const y = window.scrollY
      const was = readingRef.current
      if (!was && y > enterAt) apply(true)
      else if (was && y < 32) apply(false)
    }

    onScroll()
    window.addEventListener('scroll', onScroll, { passive: true })
    return () => window.removeEventListener('scroll', onScroll)
  }, [titleRef])

  return reading
}
