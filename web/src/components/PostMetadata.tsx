import { FileText } from 'lucide-react'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { interpolate } from '@/i18n'
import { useApp } from '@/lib/app-context'
import type { ShareNetwork } from '@/lib/constants'

function shareUrl(network: ShareNetwork, url: string, text: string): string {
  switch (network) {
    case 'x':
      return `https://twitter.com/intent/tweet?url=${url}&text=${text}`
    case 'linkedin':
      return `https://www.linkedin.com/sharing/share-offsite/?url=${url}`
  }
}

export function PostMetadata({
  title,
  date,
  author,
  readingTime,
  categories,
  markdown,
  onViewMarkdown,
}: {
  title: string
  date: string
  author: string
  readingTime: number
  categories: string[]
  markdown: string
  onViewMarkdown: () => void
}) {
  const { t } = useApp()

  const copyForLlm = async () => {
    await navigator.clipboard.writeText(markdown).catch(() => undefined)
  }

  const share = (network: ShareNetwork) => {
    const url = encodeURIComponent(window.location.href)
    const text = encodeURIComponent(title)
    window.open(shareUrl(network, url, text), '_blank', 'noopener,noreferrer')
  }

  return (
    <div className="space-y-6">
      <div>
        <div className="section-label grid-plus border-b border-ink/30 pb-2">
          {t.metadata.label}
        </div>
        <dl className="mt-3 space-y-3 font-mono text-[13px]">
          <div className="flex gap-3 border-b border-ink/15 pb-2">
            <dt className="w-28 shrink-0 text-muted">{t.metadata.date}</dt>
            <dd>{date}</dd>
          </div>
          <div className="flex gap-3 border-b border-ink/15 pb-2">
            <dt className="w-28 shrink-0 text-muted">{t.metadata.author}</dt>
            <dd className="uppercase">{author}</dd>
          </div>
          <div className="flex gap-3 border-b border-ink/15 pb-2">
            <dt className="w-28 shrink-0 text-muted">{t.metadata.readingTime}</dt>
            <dd>
              {interpolate(t.metadata.readingTimeValue, { n: readingTime })}
            </dd>
          </div>
          <div className="flex gap-3">
            <dt className="w-28 shrink-0 text-muted">{t.metadata.categories}</dt>
            <dd className="flex flex-wrap gap-1.5">
              {categories.map((c) => (
                <Badge key={c}>{c}</Badge>
              ))}
            </dd>
          </div>
        </dl>
      </div>

      <div>
        <div className="section-label mb-2">{t.metadata.agents}</div>
        <div className="flex flex-col gap-2">
          <Button
            type="button"
            variant="pill"
            className="w-full justify-start"
            onClick={() => void copyForLlm()}
          >
            <FileText className="h-4 w-4" />
            {t.metadata.copyForLlm}
          </Button>
          <Button
            type="button"
            variant="pill"
            className="w-full justify-start"
            onClick={onViewMarkdown}
          >
            {t.metadata.viewMarkdown}
          </Button>
        </div>
      </div>

      <div>
        <div className="section-label mb-2">{t.metadata.share}</div>
        <div className="flex flex-wrap gap-2">
          <Button type="button" variant="pill" size="sm" onClick={() => share('x')}>
            {t.metadata.twitter}
          </Button>
          <Button
            type="button"
            variant="pill"
            size="sm"
            onClick={() => share('linkedin')}
          >
            {t.metadata.linkedin}
          </Button>
        </div>
      </div>
    </div>
  )
}
