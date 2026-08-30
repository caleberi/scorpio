import { useEffect, useMemo, useState, type ReactNode } from 'react'
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
  type PerfSnapshot,
} from '@/lib/perf'
import { cn } from '@/lib/utils'

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
      <div className="mt-1 flex items-baseline gap-2">
        <span className="text-xl font-semibold tracking-tight text-ink">{value}</span>
        <Delta value={delta} />
      </div>
      {hint ? (
        <div className="mt-1 flex items-center gap-1.5 font-mono text-[11px] text-muted">
          {icon}
          <span>{hint}</span>
        </div>
      ) : null}
    </div>
  )
}

export function StatsModal({ onClose }: { onClose: () => void }) {
  const { t } = useApp()
  const [stats, setStats] = useState<PerfSnapshot>(() => snapshot())

  useEffect(() => {
    const unsub = subscribe(() => setStats(snapshot()))
    const id = window.setInterval(() => setStats(snapshot()), 1000)
    return () => {
      unsub()
      window.clearInterval(id)
    }
  }, [])

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== 'Escape') return
      event.preventDefault()
      onClose()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [onClose])

  const loadAvg = average(stats.loadHistory)
  const responseAvg = average(stats.responseHistory)
  const memoryPct = stats.memory
    ? Math.min(100, (stats.memory.used / stats.memory.limit) * 100)
    : 0
  const sampleCount = Math.max(stats.loadHistory.length, stats.responseHistory.length)

  const node = (
    <div
      className="fixed inset-0 z-[60] flex items-center justify-center bg-ink/35 p-4"
      onClick={onClose}
    >
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby="stats-modal-title"
        className={cn(
          'flex w-[min(34rem,calc(100vw-2rem))] flex-col overflow-hidden',
          'border border-ink bg-surface shadow-[4px_4px_0_rgba(0,0,0,0.12)]',
        )}
        onClick={(e) => e.stopPropagation()}
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
            onClick={onClose}
          >
            ×
          </button>
        </div>

        <div className="bg-surface px-4 py-4">
          <div className="grid grid-cols-1 gap-4 sm:grid-cols-3 sm:gap-0">
            <div className="sm:pr-3">
              <Metric
                label={t.console.stats.loadTime}
                value={formatMs(stats.loadMs)}
                hint={
                  loadAvg == null
                    ? undefined
                    : interpolate(t.console.stats.average, {
                        value: formatMs(loadAvg),
                      })
                }
                delta={deltaPercent(stats.loadMs, stats.loadPrevMs)}
                icon={<Gauge className="size-3" aria-hidden />}
              />
            </div>
            <div className="sm:border-l sm:border-ink/15 sm:px-3">
              <Metric
                label={t.console.stats.responseTime}
                value={formatMs(stats.responseMs)}
                hint={
                  responseAvg == null
                    ? undefined
                    : interpolate(t.console.stats.average, {
                        value: formatMs(responseAvg),
                      })
                }
                delta={deltaPercent(stats.responseMs, stats.responsePrevMs)}
                icon={<Activity className="size-3" aria-hidden />}
              />
            </div>
            <div className="sm:border-l sm:border-ink/15 sm:pl-3">
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
          </div>

          <div className="mt-4 h-[4.5rem] border border-ink/15 bg-ground">
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

          <div className="mt-3 flex items-center justify-between font-mono text-[11px] text-muted">
            <span className="truncate">{stats.path || '/'}</span>
            <span>
              {interpolate(t.console.stats.samples, { n: sampleCount })}
            </span>
          </div>
        </div>
      </div>
    </div>
  )

  if (typeof document === 'undefined') return null
  return createPortal(node, document.body)
}
