import { useEffect, useId, useRef, useState } from 'react'
import mermaid from 'mermaid'

let mermaidReady = false

function ensureMermaid() {
  if (mermaidReady) return
  mermaid.initialize({
    startOnLoad: false,
    securityLevel: 'loose',
    theme: 'neutral',
    fontFamily: 'IBM Plex Mono, ui-monospace, monospace',
  })
  mermaidReady = true
}

export function MermaidDiagram({ chart }: { chart: string }) {
  const reactId = useId().replace(/:/g, '')
  const renderId = `mermaid-${reactId}`
  const containerRef = useRef<HTMLDivElement>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    async function render() {
      ensureMermaid()
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
  }, [chart, renderId])

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
