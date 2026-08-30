const HISTORY_LIMIT = 32

type MemoryInfo = {
  usedJSHeapSize: number
  totalJSHeapSize: number
  jsHeapSizeLimit: number
}

export type PerfMemory = {
  used: number
  total: number
  limit: number
}

export type PerfSnapshot = {
  loadMs: number | null
  loadPrevMs: number | null
  loadHistory: number[]
  responseMs: number | null
  responsePrevMs: number | null
  responseHistory: number[]
  memory: PerfMemory | null
  path: string
  sampledAt: number
}

const loadHistory: number[] = []
const responseHistory: number[] = []
const listeners = new Set<() => void>()

let started = false
let navStart: number | null = null
let lastPath = ''

function last(values: number[]): number | null {
  return values.length ? values[values.length - 1] : null
}

function prev(values: number[]): number | null {
  return values.length > 1 ? values[values.length - 2] : null
}

function push(values: number[], value: number) {
  if (!Number.isFinite(value) || value < 0) return
  values.push(value)
  if (values.length > HISTORY_LIMIT) values.splice(0, values.length - HISTORY_LIMIT)
}

function emit() {
  for (const listener of listeners) listener()
}

function readMemory(): PerfMemory | null {
  const mem = (performance as Performance & { memory?: MemoryInfo }).memory
  if (!mem || !mem.jsHeapSizeLimit) return null
  return {
    used: mem.usedJSHeapSize,
    total: mem.totalJSHeapSize,
    limit: mem.jsHeapSizeLimit,
  }
}

function ingestNavigation() {
  const entries = performance.getEntriesByType('navigation')
  const nav = entries[0] as PerformanceNavigationTiming | undefined
  if (!nav) return
  if (nav.duration > 0) push(loadHistory, nav.duration)
  const response = nav.responseEnd - nav.requestStart
  if (response > 0) push(responseHistory, response)
  try {
    lastPath = new URL(nav.name, location.origin).pathname || location.pathname
  } catch {
    lastPath = location.pathname
  }
}

export function startPerfCollector() {
  if (started || typeof performance === 'undefined') return
  started = true
  ingestNavigation()
  if (typeof PerformanceObserver === 'undefined') return
  try {
    const observer = new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) {
        if (entry.entryType !== 'navigation') continue
        const nav = entry as PerformanceNavigationTiming
        if (nav.duration > 0) {
          push(loadHistory, nav.duration)
          emit()
        }
      }
    })
    observer.observe({ type: 'navigation', buffered: true })
  } catch {
    // Some browsers reject `type` + `buffered` together.
  }
}

export function beginNavigation(path: string) {
  startPerfCollector()
  navStart = performance.now()
  lastPath = path
}

export function endNavigation() {
  if (navStart == null) return
  const start = navStart
  navStart = null
  const commit = () => {
    push(loadHistory, performance.now() - start)
    emit()
  }
  if (typeof requestAnimationFrame === 'undefined') {
    commit()
    return
  }
  requestAnimationFrame(() => requestAnimationFrame(commit))
}

export function recordResponse(ms: number) {
  startPerfCollector()
  push(responseHistory, ms)
  emit()
}

export function snapshot(): PerfSnapshot {
  startPerfCollector()
  if (!lastPath && typeof location !== 'undefined') lastPath = location.pathname
  return {
    loadMs: last(loadHistory),
    loadPrevMs: prev(loadHistory),
    loadHistory: loadHistory.slice(),
    responseMs: last(responseHistory),
    responsePrevMs: prev(responseHistory),
    responseHistory: responseHistory.slice(),
    memory: readMemory(),
    path: lastPath,
    sampledAt: Date.now(),
  }
}

export function subscribe(listener: () => void): () => void {
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}

export function formatMs(ms: number | null): string {
  if (ms == null || !Number.isFinite(ms)) return '—'
  if (ms < 1) return `${Math.max(ms, 0).toFixed(2)} ms`
  if (ms < 10) return `${ms.toFixed(1)} ms`
  if (ms < 1000) return `${Math.round(ms)} ms`
  return `${(ms / 1000).toFixed(2)} s`
}

export function formatBytes(bytes: number | null): string {
  if (bytes == null || !Number.isFinite(bytes)) return '—'
  if (bytes < 1024) return `${Math.round(bytes)} B`
  if (bytes < 1024 ** 2) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / 1024 ** 2).toFixed(1)} MB`
}

export function average(values: number[]): number | null {
  if (!values.length) return null
  return values.reduce((sum, value) => sum + value, 0) / values.length
}

export function formatStatLines(stats: PerfSnapshot): string[] {
  const memory = stats.memory
    ? `${formatBytes(stats.memory.used)} / ${formatBytes(stats.memory.limit)}`
    : 'unavailable'
  return [
    `Load time      ${formatMs(stats.loadMs)}`,
    `Response time  ${formatMs(stats.responseMs)}`,
    `Memory         ${memory}`,
  ]
}
