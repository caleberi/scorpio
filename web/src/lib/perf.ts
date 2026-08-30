const HISTORY_LIMIT = 48

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

export type PageVisit = {
  id: number
  href: string
  path: string
  loadMs: number | null
  responseMs: number | null
  responses: number[]
  memory: PerfMemory | null
  visitedAt: number
}

export type PerfSnapshot = {
  visits: PageVisit[]
  current: PageVisit | null
  memory: PerfMemory | null
  loadHistory: number[]
  responseHistory: number[]
  sampledAt: number
}

const visits: PageVisit[] = []
const listeners = new Set<() => void>()

let started = false
let navStart: number | null = null
let pending: PageVisit | null = null
let nextId = 1

function last(values: number[]): number | null {
  return values.length ? values[values.length - 1] : null
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

function pathFromHref(href: string): string {
  try {
    const url = href.startsWith('http')
      ? new URL(href)
      : new URL(href, typeof location === 'undefined' ? 'http://local' : location.origin)
    return `${url.pathname}${url.search}` || '/'
  } catch {
    return href || '/'
  }
}

function makeVisit(href: string): PageVisit {
  return {
    id: nextId++,
    href,
    path: pathFromHref(href),
    loadMs: null,
    responseMs: null,
    responses: [],
    memory: readMemory(),
    visitedAt: Date.now(),
  }
}

function trimVisits() {
  if (visits.length > HISTORY_LIMIT) visits.splice(0, visits.length - HISTORY_LIMIT)
}

function commitVisit(visit: PageVisit, loadMs: number | null) {
  if (loadMs != null && Number.isFinite(loadMs) && loadMs >= 0) visit.loadMs = loadMs
  visit.memory = readMemory()
  if (visit.responseMs == null) visit.responseMs = last(visit.responses)
  visits.push(visit)
  trimVisits()
}

function ingestNavigation() {
  const href =
    typeof location === 'undefined' ? '/' : `${location.pathname}${location.search}`
  const visit = makeVisit(href)
  const entries = performance.getEntriesByType('navigation')
  const nav = entries[0] as PerformanceNavigationTiming | undefined
  if (nav && nav.duration > 0) visit.loadMs = nav.duration
  visits.push(visit)
}

export function startPerfCollector() {
  if (started || typeof performance === 'undefined') return
  started = true
  ingestNavigation()
}

export function beginNavigation(href: string) {
  startPerfCollector()
  if (pending) {
    const elapsed = navStart != null ? performance.now() - navStart : null
    commitVisit(pending, elapsed)
    pending = null
  }
  navStart = performance.now()
  pending = makeVisit(href)
  emit()
}

export function endNavigation() {
  if (!pending) return
  const start = navStart
  navStart = null
  const visit = pending
  const commit = () => {
    if (pending !== visit) return
    pending = null
    commitVisit(visit, start == null ? null : performance.now() - start)
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
  if (!Number.isFinite(ms) || ms < 0) return
  const target = pending ?? visits[visits.length - 1]
  if (!target) return
  target.responses.push(ms)
  if (target.responseMs == null) target.responseMs = ms
  emit()
}

export function snapshot(): PerfSnapshot {
  startPerfCollector()
  const list = pending ? [...visits, pending] : visits.slice()
  const loadHistory = list
    .map((visit) => visit.loadMs)
    .filter((value): value is number => value != null)
  const responseHistory = list
    .map((visit) => visit.responseMs)
    .filter((value): value is number => value != null)
  return {
    visits: list,
    current: pending ?? visits[visits.length - 1] ?? null,
    memory: readMemory(),
    loadHistory,
    responseHistory,
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
  const current = stats.current
  const memory = stats.memory
    ? `${formatBytes(stats.memory.used)} / ${formatBytes(stats.memory.limit)}`
    : 'unavailable'
  const lines = [
    `Load time      ${formatMs(current?.loadMs ?? null)}`,
    `Response time  ${formatMs(current?.responseMs ?? null)}`,
    `Memory         ${memory}`,
    `Pages          ${stats.visits.length}`,
  ]
  const recent = stats.visits.slice(-8)
  for (const visit of recent) {
    const path = visit.path.length > 28 ? `…${visit.path.slice(-27)}` : visit.path
    lines.push(`  ${path.padEnd(28)} ${formatMs(visit.loadMs)}`)
  }
  return lines
}
