import { Link } from '@tanstack/react-router'
import { Badge } from '@/components/ui/badge'
import { interpolate } from '@/i18n'
import { useApp } from '@/lib/app-context'

export function ArticleCard({
  slug,
  title,
  excerpt,
  tags,
  figure,
}: {
  slug: string
  title: string
  excerpt: string
  tags: string[]
  figure: number
}) {
  const { t } = useApp()

  return (
    <Link
      to="/posts/$"
      params={{ _splat: slug }}
      className="group grid gap-4 sm:grid-cols-[160px_1fr]"
    >
      <div className="border border-ink bg-surface">
        <div className="flex h-7 items-center gap-1.5 border-b border-ink/40 px-2">
          <span className="h-1.5 w-1.5 rounded-full bg-ink/70" />
          <span className="h-1.5 w-1.5 rounded-full bg-ink/70" />
          <span className="h-1.5 w-1.5 rounded-full bg-ink/70" />
          <span className="mx-auto font-mono text-[11px] text-muted">
            {interpolate(t.article.figure, { n: figure })}
          </span>
        </div>
        <div className="flex h-28 items-center justify-center bg-[linear-gradient(135deg,#eee_25%,transparent_25%),linear-gradient(225deg,#eee_25%,transparent_25%),linear-gradient(45deg,#eee_25%,transparent_25%),linear-gradient(315deg,#eee_25%,#f7f7f7_25%)] bg-[length:12px_12px]">
          <div className="h-10 w-16 border border-ink/50" />
        </div>
      </div>

      <div className="min-w-0">
        <h3 className="text-2xl font-bold tracking-tight group-hover:underline underline-offset-4">
          {title}
        </h3>
        <p className="mt-2 text-base leading-relaxed text-ink/80">{excerpt}</p>
        {tags.length > 0 && (
          <div className="mt-3 flex flex-wrap gap-1.5">
            {tags.map((tag) => (
              <Badge key={tag}>{tag}</Badge>
            ))}
          </div>
        )}
      </div>
    </Link>
  )
}
