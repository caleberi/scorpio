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

  // Names exist only while a scroll transition runs. Leaving them on makes
  // the cover snapshot and snap on every viewport resize.
  document.documentElement.dataset.vt = 'on'
  try {
    const vt = doc.startViewTransition(update)
    void vt.finished.finally(() => {
      delete document.documentElement.dataset.vt
    })
    return vt
  } catch (err) {
    delete document.documentElement.dataset.vt
    throw err
  }
}

/**
 * Keep the full-width title until the user has scrolled into the article.
 * Hysteresis avoids flipping back when the title docks into the sticky rail.
 * Scroll morphs the cover and title. Viewport resizes do not.
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

    let viewportW = window.innerWidth
    let viewportH = window.innerHeight
    let resizing = false
    let resizeTimer = 0

    const onScroll = () => {
      if (resizing) return
      const titleH = titleRef.current?.offsetHeight ?? 280
      const enterAt = Math.max(titleH * 0.45, 160)
      const y = window.scrollY
      const was = readingRef.current
      if (!was && y > enterAt) apply(true)
      else if (was && y < 32) apply(false)
    }

    const onResize = () => {
      const nextW = window.innerWidth
      const nextH = window.innerHeight
      if (nextW === viewportW && nextH === viewportH) return
      viewportW = nextW
      viewportH = nextH
      resizing = true
      window.clearTimeout(resizeTimer)
      resizeTimer = window.setTimeout(() => {
        resizing = false
      }, 180)
    }

    onScroll()
    window.addEventListener('scroll', onScroll, { passive: true })
    window.addEventListener('resize', onResize)
    return () => {
      window.clearTimeout(resizeTimer)
      window.removeEventListener('scroll', onScroll)
      window.removeEventListener('resize', onResize)
    }
  }, [titleRef])

  return reading
}
