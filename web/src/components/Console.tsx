import {
  useEffect,
  useMemo,
  useRef,
  useState,
  type KeyboardEvent,
  type ReactNode,
} from 'react'
import { useNavigate } from '@tanstack/react-router'
import { interpolate } from '@/i18n'
import { useApp } from '@/lib/app-context'
import {
  consoleNavItems,
  consoleSuggestion,
  initialHelp,
  runConsoleCommand,
  suggestionRemainder,
} from '@/lib/console-commands'
import {
  CONSOLE_HISTORY_LIMIT,
  STORAGE_KEYS,
} from '@/lib/constants'
import { formatThemeList } from '@/lib/highlight'
import { cn } from '@/lib/utils'
import { StatsModal } from '@/components/StatsModal'

type Line = { kind: 'in' | 'out'; text: string }

type HistoryNav = {
  prefix: string
  draft: string
  index: number
  items: string[]
}

function readConsoleHistory(): string[] {
  if (typeof window === 'undefined') return []
  const raw = localStorage.getItem(STORAGE_KEYS.consoleHistory)
  if (!raw) return []
  try {
    const parsed: unknown = JSON.parse(raw)
    if (!Array.isArray(parsed)) return []
    return parsed
      .filter((item): item is string => typeof item === 'string' && item.length > 0)
      .slice(-CONSOLE_HISTORY_LIMIT)
  } catch {
    return []
  }
}

function persistConsoleHistory(history: string[]) {
  localStorage.setItem(
    STORAGE_KEYS.consoleHistory,
    JSON.stringify(history.slice(-CONSOLE_HISTORY_LIMIT)),
  )
}

export function Console() {
  const {
    consoleState,
    setConsoleState,
    documents,
    theme,
    setTheme,
    t,
  } = useApp()
  const navigate = useNavigate()
  const [lines, setLines] = useState<Line[]>(() =>
    initialHelp().map((text) => ({ kind: 'out', text })),
  )
  const [input, setInput] = useState('')
  const [history, setHistory] = useState<string[]>(readConsoleHistory)
  const [nav, setNav] = useState<HistoryNav | null>(null)
  const [statsOpen, setStatsOpen] = useState(false)
  const inputRef = useRef<HTMLInputElement>(null)
  const scrollRef = useRef<HTMLDivElement>(null)
  const openTargets = useMemo(() => {
    const seen = new Set<string>()
    const targets: string[] = []
    for (const doc of documents) {
      for (const target of [doc.path, doc.slug]) {
        if (seen.has(target)) continue
        seen.add(target)
        targets.push(target)
      }
    }
    return targets
  }, [documents])
  const suggestion = nav
    ? null
    : consoleSuggestion(input, history, openTargets)
  const remainder = suggestionRemainder(input, suggestion)

  useEffect(() => {
    if (consoleState === 'open') {
      inputRef.current?.focus()
    }
  }, [consoleState])

  useEffect(() => {
    scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight })
  }, [lines, consoleState])

  const run = async (raw: string) => {
    const result = await runConsoleCommand(raw, {
      listPaths: () => documents.map((d) => d.path),
      openPath: (target) => {
        const cleaned = target.replace(/^\//, '').replace(/\.md$/i, '')
        const match = documents.find(
          (d) =>
            d.slug === cleaned ||
            d.path === target ||
            d.path === `${cleaned}.md` ||
            d.slug.endsWith(cleaned),
        )
        if (!match) return `Error: not found "${target}"`
        void navigate({ to: '/posts/$', params: { _splat: match.slug } })
        return `Opening ${match.path}`
      },
      listThemes: () => formatThemeList().join('\n'),
      setTheme: (name) => {
        const n = name.toLowerCase()
        setTheme(n)
        return `Theme set to ${n}`
      },
      close: () => setConsoleState('closed'),
    })

    setLines((prev) => {
      const next: Line[] = result.clear
        ? []
        : [
            ...prev,
            { kind: 'in', text: `$ ${raw}` },
            ...result.lines.map((text) => ({ kind: 'out' as const, text })),
          ]
      return next
    })

    if (result.close) {
      window.setTimeout(() => setConsoleState('closed'), 200)
    }
    if (result.openStats) setStatsOpen(true)
  }

  const pushHistory = (command: string) => {
    const trimmed = command.trim()
    if (!trimmed) return
    setHistory((prev) => {
      const next =
        prev.at(-1) === trimmed ? prev : [...prev, trimmed]
      const capped = next.slice(-CONSOLE_HISTORY_LIMIT)
      persistConsoleHistory(capped)
      return capped
    })
    setNav(null)
  }

  const acceptSuggestion = () => {
    if (!suggestion) return
    setInput(suggestion)
    setNav(null)
  }

  const moveHistory = (direction: 1 | -1) => {
    const current = nav ?? {
      prefix: input,
      draft: input,
      index: -1,
      items: consoleNavItems(input, history, openTargets),
    }
    if (!current.items.length) return
    const nextIndex = current.index + direction
    if (nextIndex < -1 || nextIndex >= current.items.length) return
    if (nextIndex === -1) {
      setInput(current.draft)
      setNav(null)
      return
    }
    setNav({ ...current, index: nextIndex })
    setInput(current.items[nextIndex])
  }

  const onInputKeyDown = (e: KeyboardEvent<HTMLInputElement>) => {
    switch (e.key) {
      case 'ArrowUp':
        e.preventDefault()
        moveHistory(1)
        break
      case 'ArrowDown':
        e.preventDefault()
        moveHistory(-1)
        break
      case 'ArrowRight': {
        const node = e.currentTarget
        const atEnd =
          node.selectionStart === input.length &&
          node.selectionEnd === input.length
        if (atEnd && remainder) {
          e.preventDefault()
          acceptSuggestion()
        }
        break
      }
      case 'Tab':
        if (remainder) {
          e.preventDefault()
          acceptSuggestion()
        }
        break
      default:
        break
    }
  }

  let consoleUi: ReactNode = null
  switch (consoleState) {
    case 'closed':
      break
    case 'minimized':
      consoleUi = (
        <button
          type="button"
          className="fixed bottom-4 right-4 z-50 border border-ink bg-console-bar px-3 py-1.5 font-mono text-[13px] uppercase tracking-wide shadow-sm"
          onClick={() => setConsoleState('open')}
        >
          {t.console.title}
        </button>
      )
      break
    case 'open':
      consoleUi = (
        <div
          className={cn(
            'fixed bottom-4 right-4 z-50 flex w-[min(420px,calc(100vw-2rem))] flex-col overflow-hidden',
            'border border-ink bg-console shadow-[4px_4px_0_rgba(0,0,0,0.12)]',
          )}
          style={{ height: 280 }}
        >
          <div className="relative flex h-8 shrink-0 items-center justify-center bg-console-bar">
            <span className="font-mono text-[13px] uppercase tracking-widest text-ink">
              {t.console.title}
            </span>
            <div className="absolute right-2 flex items-center gap-1">
              <button
                type="button"
                aria-label={t.console.minimize}
                className="px-1.5 font-mono text-sm leading-none hover:bg-ink/10"
                onClick={() => setConsoleState('minimized')}
              >
                −
              </button>
              <button
                type="button"
                aria-label={t.console.close}
                className="px-1.5 font-mono text-sm leading-none hover:bg-ink/10"
                onClick={() => setConsoleState('closed')}
              >
                ×
              </button>
            </div>
          </div>

          <div
            ref={scrollRef}
            className="flex-1 overflow-y-auto bg-console px-3 py-2 font-mono text-[13px] leading-relaxed text-white"
          >
            {lines.map((line, i) => (
              <div
                key={`${i}-${line.text.slice(0, 12)}`}
                className={cn(line.kind === 'in' ? 'text-white/90' : 'text-white/75')}
              >
                {line.text}
              </div>
            ))}
            <form
              className="mt-1 flex items-center gap-2"
              onSubmit={(e) => {
                e.preventDefault()
                const value = input
                setInput('')
                setNav(null)
                pushHistory(value)
                void run(value)
              }}
            >
              <span className="text-accent">$</span>
              <div className="relative min-w-0 flex-1">
                {remainder ? (
                  <span
                    className="pointer-events-none absolute inset-0 overflow-hidden whitespace-pre"
                    aria-hidden
                  >
                    <span className="invisible">{input}</span>
                    <span className="text-white/30">{remainder}</span>
                  </span>
                ) : null}
                <input
                  ref={inputRef}
                  value={input}
                  onChange={(e) => {
                    setNav(null)
                    setInput(e.target.value)
                  }}
                  onKeyDown={onInputKeyDown}
                  className="relative w-full bg-transparent text-white outline-none caret-transparent"
                  spellCheck={false}
                  autoComplete="off"
                  aria-label={t.console.commandAria}
                />
              </div>
              <span
                className="inline-block h-4 w-2 animate-pulse bg-accent"
                aria-hidden
              />
            </form>
            <div className="sr-only">
              {interpolate(t.console.currentTheme, { theme })}
            </div>
          </div>
        </div>
      )
      break
  }

  return (
    <>
      {consoleUi}
      {statsOpen ? <StatsModal onClose={() => setStatsOpen(false)} /> : null}
    </>
  )
}
