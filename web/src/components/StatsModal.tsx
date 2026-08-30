import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { createPortal } from 'react-dom'
import { Activity, Gauge, MemoryStick } from 'lucide-react'
import { interpolate } from '@/i18n'
import { useApp } from '@/lib/app-context'
import {
  average,
  formatBytes,
  formatMs,
  snapshot,
  subscribe,
  type PageVisit,
  type PerfSnapshot,
} from '@/lib/perf'
import { cn } from '@/lib/utils'

const CLOSE_MS = 280

function prefersReducedMotion() {
  return (
    typeof window !== 'undefined' &&
    window.matchMedia('(prefers-reduced-motion: reduce)').matches
  )
}

function deltaPercent(current: number | null, previous: number | null): number | null {
  if (current == null || previous == null || previous === 0) return null
  return ((current - previous) / previous) * 100
}

function Sparkline({
  values,
  className,
}: {
  values: number[]
  className?: string
}) {
  const width = 320
  const height = 72
  const path = useMemo(() => {
    if (!values.length) return null
    const min = Math.min(...values)
    const max = Math.max(...values)
    const span = max - min || 1
    const series = values.length === 1 ? [values[0], values[0]] : values
    const points = series.map((value, i) => {
      const x = (i / (series.length - 1)) * width
      const y = height - ((value - min) / span) * (height - 8) - 4
      return `${x.toFixed(1)},${y.toFixed(1)}`
    })
    const line = points
      .map((point, i) => `${i === 0 ? 'M' : 'L'}${point}`)
      .join(' ')
    const last = points[points.length - 1].split(',')
    const area = `${line} L${width},${height} L0,${height} Z`
    return { line, area, lastX: Number(last[0]), lastY: Number(last[1]) }
  }, [values])

  return (
    <svg
      viewBox={`0 0 ${width} ${height}`}
      className={className}
      preserveAspectRatio="none"
      aria-hidden
    >
      {[0.2, 0.4, 0.6, 0.8].map((t) => (
        <line
          key={t}
          x1={width * t}
          x2={width * t}
          y1="0"
          y2={height}
          className="stroke-ink/15"
          strokeDasharray="2 4"
          strokeWidth="1"
        />
      ))}
      {path ? (
        <>
          <path d={path.area} className="fill-accent/20" />
          <path
            d={path.line}
            className="stroke-accent"
            fill="none"
            strokeWidth="2"
            strokeLinejoin="round"
            strokeLinecap="round"
          />
          <line
            x1={path.lastX}
            x2={path.lastX}
            y1="0"
            y2={height}
            className="stroke-accent/50"
            strokeDasharray="3 3"
            strokeWidth="1"
          />
          <circle
            cx={path.lastX}
            cy={path.lastY}
            r="3.5"
            className="fill-accent stroke-surface"
            strokeWidth="1.5"
          />
        </>
      ) : null}
    </svg>
  )
}

function Delta({ value }: { value: number | null }) {
  if (value == null || !Number.isFinite(value)) return null
  const improved = value < 0
  const label = `${value > 0 ? '+' : ''}${value.toFixed(0)}%`
  return (
    <span
      className={cn(
        'inline-flex items-center px-1.5 py-0.5 font-mono text-[10px] leading-none',
        improved ? 'bg-highlight text-ink' : 'bg-ink/10 text-muted',
      )}
    >
      {label}
    </span>
  )
}

function Metric({
  label,
  value,
  hint,
  delta,
  icon,
}: {
  label: string
  value: string
  hint?: string
  delta: number | null
  icon: ReactNode
}) {
  return (
    <div className="min-w-0">
      <div className="font-mono text-[10px] uppercase tracking-widest text-muted">
        {label}
      </div>
      <div className="mt-1 flex flex-wrap items-baseline gap-2">
        <span className="text-lg font-semibold tracking-tight text-ink">{value}</span>
        <Delta value={delta} />
      </div>
      {hint ? (
        <div className="mt-1 flex items-center gap-1.5 font-mono text-[11px] text-muted">
          {icon}
          <span className="truncate">{hint}</span>
        </div>
      ) : null}
    </div>
  )
}

function VisitRow({
  visit,
  active,
  currentLabel,
  loadLabel,
  responseLabel,
  memoryLabel,
}: {
  visit: PageVisit
  active: boolean
  currentLabel: string
  loadLabel: string
  responseLabel: string
  memoryLabel: string
}) {
  const time = new Date(visit.visitedAt).toLocaleTimeString(undefined, {
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  })
  return (
    <li
      className={cn(
        'border border-ink/15 bg-ground px-3 py-2.5',
        active && 'border-accent bg-accent/10',
      )}
    >
      <div className="flex items-start justify-between gap-2">
        <div className="min-w-0 font-mono text-[12px] text-ink">
          <div className="truncate" title={visit.path}>
            {visit.path || '/'}
          </div>
          {active ? (
            <div className="mt-0.5 text-[10px] uppercase tracking-widest text-muted">
              {currentLabel}
            </div>
          ) : null}
        </div>
        <time
          className="shrink-0 font-mono text-[10px] text-muted"
          dateTime={new Date(visit.visitedAt).toISOString()}
        >
          {time}
        </time>
      </div>
      <dl className="mt-2 grid grid-cols-3 gap-2">
        <div>
          <dt className="font-mono text-[9px] uppercase tracking-widest text-muted">
            {loadLabel}
          </dt>
          <dd className="font-mono text-[11px] text-ink">{formatMs(visit.loadMs)}</dd>
        </div>
        <div>
          <dt className="font-mono text-[9px] uppercase tracking-widest text-muted">
            {responseLabel}
          </dt>
          <dd className="font-mono text-[11px] text-ink">{formatMs(visit.responseMs)}</dd>
        </div>
        <div>
          <dt className="font-mono text-[9px] uppercase tracking-widest text-muted">
            {memoryLabel}
          </dt>
          <dd className="font-mono text-[11px] text-ink">
            {visit.memory ? formatBytes(visit.memory.used) : '—'}
          </dd>
        </div>
      </dl>
    </li>
  )
}

export function StatsModal({ onClose }: { onClose: () => void }) {
  const { t } = useApp()
  const reduced = prefersReducedMotion()
  const [visible, setVisible] = useState(reduced)
  const [stats, setStats] = useState<PerfSnapshot>(() => snapshot())
  const closing = useRef(false)

  useEffect(() => {
    if (reduced) return
    const id = window.requestAnimationFrame(() => setVisible(true))
    return () => window.cancelAnimationFrame(id)
  }, [reduced])

  useEffect(() => {
    const unsub = subscribe(() => setStats(snapshot()))
    const id = window.setInterval(() => setStats(snapshot()), 1000)
    return () => {
      unsub()
      window.clearInterval(id)
    }
  }, [])

  const dismiss = useCallback(() => {
    if (closing.current) return
    closing.current = true
    if (reduced) {
      onClose()
      return
    }
    setVisible(false)
    window.setTimeout(onClose, CLOSE_MS)
  }, [onClose, reduced])

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== 'Escape') return
      event.preventDefault()
      dismiss()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [dismiss])

  const current = stats.current
  const previous = stats.visits.length > 1 ? stats.visits[stats.visits.length - 2] : null
  const loadAvg = average(stats.loadHistory)
  const responseAvg = average(stats.responseHistory)
  const memoryPct = stats.memory
    ? Math.min(100, (stats.memory.used / stats.memory.limit) * 100)
    : 0
  const pages = [...stats.visits].reverse()

  const node = (
    <div className="fixed inset-0 z-[60]">
      <button
        type="button"
        aria-label={t.console.stats.close}
        className={cn(
          'absolute inset-0 bg-ink/35 transition-opacity ease-out',
          reduced ? 'duration-0' : 'duration-300',
          visible ? 'opacity-100' : 'opacity-0',
        )}
        onClick={dismiss}
      />
      <aside
        role="dialog"
        aria-modal="true"
        aria-labelledby="stats-modal-title"
        className={cn(
          'absolute inset-y-0 left-0 flex w-[min(24rem,calc(100vw-1.5rem))] flex-col',
          'border-r border-ink bg-surface shadow-[4px_0_0_rgba(0,0,0,0.12)]',
          'transition-transform ease-out',
          reduced ? 'duration-0' : 'duration-300',
          visible ? 'translate-x-0' : '-translate-x-full',
        )}
      >
        <div className="relative flex h-8 shrink-0 items-center justify-center bg-console-bar">
          <span
            id="stats-modal-title"
            className="font-mono text-[13px] uppercase tracking-widest text-ink"
          >
            {t.console.stats.title}
          </span>
          <button
            type="button"
            aria-label={t.console.stats.close}
            className="absolute right-2 px-1.5 font-mono text-sm leading-none hover:bg-ink/10"
            onClick={dismiss}
          >
            ×
          </button>
        </div>

        <div className="shrink-0 border-b border-ink/15 bg-surface px-4 py-4">
          <div className="grid grid-cols-3 gap-3">
            <Metric
              label={t.console.stats.loadTime}
              value={formatMs(current?.loadMs ?? null)}
              hint={
                loadAvg == null
                  ? undefined
                  : interpolate(t.console.stats.average, {
                      value: formatMs(loadAvg),
                    })
              }
              delta={deltaPercent(current?.loadMs ?? null, previous?.loadMs ?? null)}
              icon={<Gauge className="size-3" aria-hidden />}
            />
            <Metric
              label={t.console.stats.responseTime}
              value={formatMs(current?.responseMs ?? null)}
              hint={
                responseAvg == null
                  ? undefined
                  : interpolate(t.console.stats.average, {
                      value: formatMs(responseAvg),
                    })
              }
              delta={deltaPercent(
                current?.responseMs ?? null,
                previous?.responseMs ?? null,
              )}
              icon={<Activity className="size-3" aria-hidden />}
            />
            <Metric
              label={t.console.stats.memory}
              value={stats.memory ? formatBytes(stats.memory.used) : t.console.stats.unavailable}
              hint={
                stats.memory
                  ? interpolate(t.console.stats.usedOf, {
                      used: formatBytes(stats.memory.used),
                      total: formatBytes(stats.memory.limit),
                    })
                  : undefined
              }
              delta={null}
              icon={<MemoryStick className="size-3" aria-hidden />}
            />
          </div>

          <div className="mt-4 h-16 border border-ink/15 bg-ground">
            <Sparkline values={stats.loadHistory} className="h-full w-full text-accent" />
          </div>

          {stats.memory ? (
            <div className="mt-3">
              <div
                className="h-2 overflow-hidden bg-ink/10"
                role="progressbar"
                aria-valuemin={0}
                aria-valuemax={100}
                aria-valuenow={Math.round(memoryPct)}
                aria-label={t.console.stats.memory}
              >
                <div className="h-full bg-accent" style={{ width: `${memoryPct}%` }} />
              </div>
            </div>
          ) : null}
        </div>

        <div className="flex min-h-0 flex-1 flex-col">
          <div className="flex shrink-0 items-center justify-between px-4 py-2">
            <span className="font-mono text-[10px] uppercase tracking-widest text-muted">
              {t.console.stats.pages}
            </span>
            <span className="font-mono text-[11px] text-muted">
              {interpolate(t.console.stats.pageCount, { n: stats.visits.length })}
            </span>
          </div>
          <div className="min-h-0 flex-1 overflow-y-auto px-4 pb-4">
            {pages.length === 0 ? (
              <p className="font-mono text-[12px] text-muted">{t.console.stats.empty}</p>
            ) : (
              <ol className="space-y-2">
                {pages.map((visit) => (
                  <VisitRow
                    key={visit.id}
                    visit={visit}
                    active={current?.id === visit.id}
                    currentLabel={t.console.stats.current}
                    loadLabel={t.console.stats.loadTime}
                    responseLabel={t.console.stats.responseTime}
                    memoryLabel={t.console.stats.memory}
                  />
                ))}
              </ol>
            )}
          </div>
        </div>
      </aside>
    </div>
  )

  if (typeof document === 'undefined') return null
  return createPortal(node, document.body)
}
