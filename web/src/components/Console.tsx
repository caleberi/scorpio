import { useEffect, useRef, useState } from 'react'
import { useNavigate } from '@tanstack/react-router'
import { interpolate } from '@/i18n'
import { useApp } from '@/lib/app-context'
import {
  initialHelp,
  runConsoleCommand,
} from '@/lib/console-commands'
import { THEME_NAMES } from '@/lib/highlight'
import { cn } from '@/lib/utils'

type Line = { kind: 'in' | 'out'; text: string }

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
  const inputRef = useRef<HTMLInputElement>(null)
  const scrollRef = useRef<HTMLDivElement>(null)

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
      listThemes: () => `Themes: ${THEME_NAMES.join(', ')}`,
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
  }

  switch (consoleState) {
    case 'closed':
      return null
    case 'minimized':
      return (
        <button
          type="button"
          className="fixed bottom-4 right-4 z-50 border border-ink bg-console-bar px-3 py-1.5 font-mono text-[13px] uppercase tracking-wide shadow-sm"
          onClick={() => setConsoleState('open')}
        >
          {t.console.title}
        </button>
      )
    case 'open':
      return (
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
                className="px-1.5 font-mono text-sm leading-none hover:bg-black/10"
                onClick={() => setConsoleState('minimized')}
              >
                −
              </button>
              <button
                type="button"
                aria-label={t.console.close}
                className="px-1.5 font-mono text-sm leading-none hover:bg-black/10"
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
                void run(value)
              }}
            >
              <span className="text-accent">$</span>
              <input
                ref={inputRef}
                value={input}
                onChange={(e) => setInput(e.target.value)}
                className="min-w-0 flex-1 bg-transparent text-white outline-none caret-transparent"
                spellCheck={false}
                autoComplete="off"
                aria-label={t.console.commandAria}
              />
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
  }
}
