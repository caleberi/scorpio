import { useEffect, useState } from 'react'
import { useApp } from '@/lib/app-context'
import { highlightCode } from '@/lib/syntax'

export function CodeBlock({
  code,
  lang,
}: {
  code: string
  lang?: string
}) {
  const { theme } = useApp()
  const [html, setHtml] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    highlightCode(code, lang, theme)
      .then((next) => {
        if (!cancelled) setHtml(next)
      })
      .catch(() => {
        if (!cancelled) setHtml(null)
      })
    return () => {
      cancelled = true
    }
  }, [code, lang, theme])

  return (
    <div className="code-block">
      {lang ? <div className="code-block-lang">{lang}</div> : null}
      {html ? (
        <div
          className="code-block-body"
          dangerouslySetInnerHTML={{ __html: html }}
        />
      ) : (
        <pre className="code-block-fallback">
          <code>{code}</code>
        </pre>
      )}
    </div>
  )
}
