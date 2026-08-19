import { useEffect, useId, useRef, useState } from 'react'
import mermaid from 'mermaid'
import { useApp } from '@/lib/app-context'
import { isDarkTheme } from '@/lib/highlight'

let mermaidMode: 'light' | 'dark' | null = null

function ensureMermaid(dark: boolean) {
  const mode = dark ? 'dark' : 'light'
  if (mermaidMode === mode) return
  mermaid.initialize({
    startOnLoad: false,
    securityLevel: 'loose',
    theme: dark ? 'dark' : 'neutral',
    fontFamily: 'IBM Plex Mono, ui-monospace, monospace',
  })
  mermaidMode = mode
}

export function MermaidDiagram({ chart }: { chart: string }) {
  const { theme } = useApp()
  const dark = isDarkTheme(theme)
  const reactId = useId().replace(/:/g, '')
  const renderId = `mermaid-${reactId}-${dark ? 'd' : 'l'}`
  const containerRef = useRef<HTMLDivElement>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    async function render() {
      ensureMermaid(dark)
      setError(null)
      const rendered = await mermaid
        .render(renderId, chart.trim())
        .catch((err: unknown) => {
          if (!cancelled) {
            setError(err instanceof Error ? err.message : 'Mermaid render failed')
          }
          return null
        })
      if (!rendered || cancelled || !containerRef.current) return
      containerRef.current.innerHTML = rendered.svg
      rendered.bindFunctions?.(containerRef.current)
    }
    void render()
    return () => {
      cancelled = true
    }
  }, [chart, renderId, dark])

  if (error) {
    return (
      <pre className="overflow-x-auto border border-red-300 bg-surface p-4 font-mono text-[13px] text-red-700">
        {error}
        {'\n\n'}
        {chart}
      </pre>
    )
  }

  return (
    <div
      ref={containerRef}
      className="mermaid-diagram my-6 overflow-x-auto border border-ink/20 bg-surface p-4"
    />
  )
}
