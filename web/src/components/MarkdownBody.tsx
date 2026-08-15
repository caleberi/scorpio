import type { ReactNode } from 'react'
import type { Components } from 'react-markdown'
import ReactMarkdown from 'react-markdown'
import remarkGfm from 'remark-gfm'
import rehypeRaw from 'rehype-raw'
import { MermaidDiagram } from '@/components/MermaidDiagram'
import { cn } from '@/lib/utils'

function getText(node: ReactNode): string {
  switch (typeof node) {
    case 'string':
      return node
    case 'number':
      return String(node)
    case 'object':
      if (Array.isArray(node)) return node.map(getText).join('')
      if (node && 'props' in node) {
        const el = node as { props?: { children?: ReactNode } }
        return getText(el.props?.children)
      }
      return ''
    default:
      return ''
  }
}

function isMermaidElement(node: ReactNode): boolean {
  if (!node || typeof node !== 'object' || !('type' in node)) return false
  return (node as { type?: unknown }).type === MermaidDiagram
}

const components: Components = {
  code({ className, children, ...props }) {
    const text = getText(children).replace(/\n$/, '')
    const lang = /language-(\w+)/.exec(className ?? '')?.[1]

    if (lang === 'mermaid') {
      return <MermaidDiagram chart={text} />
    }

    return (
      <code className={className} {...props}>
        {children}
      </code>
    )
  },
  pre({ children }) {
    const child = Array.isArray(children) ? children[0] : children
    if (isMermaidElement(child)) {
      return <>{children}</>
    }
    return (
      <pre className="overflow-x-auto border border-ink/20 bg-surface p-4 font-mono text-[13px] leading-relaxed">
        {children}
      </pre>
    )
  },
  table({ children }) {
    return (
      <div className="prose-table-wrap">
        <table>{children}</table>
      </div>
    )
  },
}

export function MarkdownBody({
  content,
  className,
}: {
  content: string
  className?: string
}) {
  return (
    <div className={cn('prose-blog', className)}>
      <ReactMarkdown
        remarkPlugins={[remarkGfm]}
        rehypePlugins={[rehypeRaw]}
        components={components}
      >
        {content}
      </ReactMarkdown>
    </div>
  )
}
