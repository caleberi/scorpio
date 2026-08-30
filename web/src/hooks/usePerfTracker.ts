import { useEffect } from 'react'
import { useRouter } from '@tanstack/react-router'
import { beginNavigation, endNavigation, startPerfCollector } from '@/lib/perf'

export function usePerfTracker() {
  const router = useRouter()

  useEffect(() => {
    startPerfCollector()
    const offStart = router.subscribe('onBeforeLoad', (event) => {
      if (!event.pathChanged && !event.hrefChanged) return
      beginNavigation(event.toLocation.href)
    })
    const offEnd = router.subscribe('onRendered', () => {
      endNavigation()
    })
    return () => {
      offStart()
      offEnd()
    }
  }, [router])
}
