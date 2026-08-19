import { useEffect, useState, type RefObject } from 'react'

/**
 * Keep the full-width title until the user has scrolled into the article.
 * Hysteresis avoids flipping back when the title docks into the sticky rail.
 */
export function useReadingLayout(titleRef: RefObject<HTMLElement | null>) {
  const [reading, setReading] = useState(false)

  useEffect(() => {
    const onScroll = () => {
      const titleH = titleRef.current?.offsetHeight ?? 280
      const enterAt = Math.max(titleH * 0.45, 160)
      const y = window.scrollY
      setReading((was) => {
        if (!was && y > enterAt) return true
        if (was && y < 32) return false
        return was
      })
    }

    onScroll()
    window.addEventListener('scroll', onScroll, { passive: true })
    return () => window.removeEventListener('scroll', onScroll)
  }, [titleRef])

  return reading
}
