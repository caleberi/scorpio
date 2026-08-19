import type { ReactNode } from 'react'
import type { Components } from 'react-markdown'
import ReactMarkdown from 'react-markdown'
import remarkGfm from 'remark-gfm'
import rehypeRaw from 'rehype-raw'
import { CodeBlock } from '@/components/CodeBlock'
import { MermaidDiagram } from '@/components/MermaidDiagram'
import { cn } from '@/lib/utils'

function getText(node: ReactNode): string {
  switch (typeof node) {
    case 'string':
      return node
    case 'number':
      return String(node)
    default:
      if (Array.isArray(node)) return node.map(getText).join('')
      if (node && typeof node === 'object' && 'props' in node) {
        const el = node as { props?: { children?: ReactNode } }
        return getText(el.props?.children)
      }
      return ''
  }
}

function classNameOf(node: ReactNode): string {
  if (!node || typeof node !== 'object' || !('props' in node)) return ''
  const className = (node as { props?: { className?: string | string[] } })
    .props?.className
  return Array.isArray(className) ? className.join(' ') : (className ?? '')
}

function getLang(node: ReactNode): string | undefined {
  return /language-(\w+)/.exec(classNameOf(node))?.[1]?.toLowerCase()
}

function firstElement(node: ReactNode): ReactNode {
  if (!Array.isArray(node)) return node
  return node.find((child) => child && typeof child === 'object') ?? node[0]
}

function slugify(text: string): string {
  return text
    .toLowerCase()
    .normalize('NFKD')
    .replace(/[^\w\s-]/g, '')
    .trim()
    .replace(/[-\s]+/g, '-')
}

function Heading({
  tag: Tag,
  children,
}: {
  tag: 'h1' | 'h2' | 'h3' | 'h4' | 'h5' | 'h6'
  children?: ReactNode
}) {
  const id = slugify(getText(children))
  return <Tag id={id || undefined}>{children}</Tag>
}

const components: Components = {
  h1: ({ children }) => <Heading tag="h1">{children}</Heading>,
  h2: ({ children }) => <Heading tag="h2">{children}</Heading>,
  h3: ({ children }) => <Heading tag="h3">{children}</Heading>,
  h4: ({ children }) => <Heading tag="h4">{children}</Heading>,
  h5: ({ children }) => <Heading tag="h5">{children}</Heading>,
  h6: ({ children }) => <Heading tag="h6">{children}</Heading>,
  img({ src, alt, className }) {
    if (!src) return null
    return (
      <img
        src={src}
        alt={alt ?? ''}
        className={className}
        loading="lazy"
        referrerPolicy="no-referrer"
      />
    )
  },
  code({ className, children, ...props }) {
    return (
      <code className={className} {...props}>
        {children}
      </code>
    )
  },
  pre({ children }) {
    const child = firstElement(children)
    const lang = getLang(child)
    const text = getText(child).replace(/\n$/, '')
    if (lang === 'mermaid') {
      return <MermaidDiagram chart={text} />
    }
    return <CodeBlock code={text} lang={lang} />
  },
  table({ children }) {
    return (
      <div className="prose-table-wrap">
        <table>{children}</table>
      </div>
    )
  },
  iframe({ src, title, className }) {
    if (!src) return null
    return (
      <iframe
        src={src}
        title={title || 'Embedded content'}
        className={className}
        loading="lazy"
      />
    )
  },
  script({ src }) {
    if (!src || !/gist\.github\.com/i.test(src)) return null
    const iframeSrc = src.replace(/\.js(?=\?|$)/i, '.pibb')
    return (
      <iframe
        src={iframeSrc.includes('.pibb') ? iframeSrc : `${iframeSrc}.pibb`}
        title="GitHub Gist"
        className="gist-embed"
        loading="lazy"
      />
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
