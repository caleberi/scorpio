import { useCallback, useEffect, useLayoutEffect, useRef } from 'react'
import type { KeyboardEvent, PointerEvent } from 'react'
import {
  SIDEBAR_CONTENT_FLOOR,
  SIDEBAR_DEFAULT,
  SIDEBAR_MAX,
  SIDEBAR_MIN,
  STORAGE_KEYS,
} from '@/lib/constants'

const PAGE_MAX = 1400
/** Remaining page width where the post meta column drops above the body. */
const RAIL_STACK_AT = 980

function pageWidth(viewport = window.innerWidth) {
  return Math.min(viewport, PAGE_MAX)
}

export function sidebarMax(viewport = window.innerWidth) {
  return Math.max(
    SIDEBAR_MIN,
    Math.min(SIDEBAR_MAX, pageWidth(viewport) - SIDEBAR_CONTENT_FLOOR),
  )
}

export function clampSidebarWidth(width: number, viewport = window.innerWidth) {
  return Math.round(Math.min(sidebarMax(viewport), Math.max(SIDEBAR_MIN, width)))
}

function readPreferred() {
  try {
    const raw = localStorage.getItem(STORAGE_KEYS.sidebarWidth)
    const n = raw ? Number(raw) : SIDEBAR_DEFAULT
    if (!Number.isFinite(n)) return SIDEBAR_DEFAULT
    return Math.min(SIDEBAR_MAX, Math.max(SIDEBAR_MIN, n))
  } catch {
    return SIDEBAR_DEFAULT
  }
}

function publish(preferred: number, handle: HTMLDivElement | null) {
  const width = clampSidebarWidth(preferred)
  const root = document.documentElement
  root.style.setProperty('--sidebar-width', `${width}px`)
  root.dataset.postRail = pageWidth() - width < RAIL_STACK_AT ? 'stack' : 'beside'
  if (handle) {
    handle.setAttribute('aria-valuenow', String(width))
    handle.setAttribute('aria-valuemin', String(SIDEBAR_MIN))
    handle.setAttribute('aria-valuemax', String(sidebarMax()))
  }
  return width
}

export function useSidebarWidth() {
  const preferredRef = useRef(SIDEBAR_DEFAULT)
  const handleRef = useRef<HTMLDivElement>(null)
  const dragRef = useRef<{ x: number; width: number } | null>(null)

  const apply = useCallback(() => {
    publish(preferredRef.current, handleRef.current)
  }, [])

  const persist = useCallback(() => {
    try {
      localStorage.setItem(STORAGE_KEYS.sidebarWidth, String(preferredRef.current))
    } catch {
      /* private mode or a full disk */
    }
  }, [])

  const setPreferred = useCallback(
    (next: number) => {
      preferredRef.current = Math.min(SIDEBAR_MAX, Math.max(SIDEBAR_MIN, next))
      apply()
    },
    [apply],
  )

  useLayoutEffect(() => {
    preferredRef.current = readPreferred()
    apply()
  }, [apply])

  useEffect(() => {
    const onResize = () => apply()
    window.addEventListener('resize', onResize)
    return () => window.removeEventListener('resize', onResize)
  }, [apply])

  const onPointerDown = (event: PointerEvent<HTMLDivElement>) => {
    if (event.button !== 0) return
    event.preventDefault()
    event.currentTarget.focus()
    event.currentTarget.setPointerCapture(event.pointerId)
    dragRef.current = {
      x: event.clientX,
      width: clampSidebarWidth(preferredRef.current),
    }
    document.documentElement.dataset.sidebarDragging = 'true'
  }

  const onPointerMove = (event: PointerEvent<HTMLDivElement>) => {
    const drag = dragRef.current
    if (!drag) return
    setPreferred(clampSidebarWidth(drag.width + event.clientX - drag.x))
  }

  const endDrag = (event: PointerEvent<HTMLDivElement>) => {
    if (!dragRef.current) return
    dragRef.current = null
    delete document.documentElement.dataset.sidebarDragging
    if (event.currentTarget.hasPointerCapture(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId)
    }
    persist()
  }

  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    const step = event.shiftKey ? 48 : 16
    switch (event.key) {
      case 'ArrowLeft':
        event.preventDefault()
        setPreferred(clampSidebarWidth(clampSidebarWidth(preferredRef.current) - step))
        persist()
        break
      case 'ArrowRight':
        event.preventDefault()
        setPreferred(clampSidebarWidth(clampSidebarWidth(preferredRef.current) + step))
        persist()
        break
      case 'Home':
        event.preventDefault()
        setPreferred(SIDEBAR_MIN)
        persist()
        break
      case 'End':
        event.preventDefault()
        setPreferred(sidebarMax())
        persist()
        break
      case 'Enter':
        event.preventDefault()
        setPreferred(SIDEBAR_DEFAULT)
        persist()
        break
      default:
        break
    }
  }

  const onDoubleClick = () => {
    setPreferred(SIDEBAR_DEFAULT)
    persist()
  }

  return {
    handleRef,
    onPointerDown,
    onPointerMove,
    onPointerUp: endDrag,
    onPointerCancel: endDrag,
    onKeyDown,
    onDoubleClick,
  }
}
