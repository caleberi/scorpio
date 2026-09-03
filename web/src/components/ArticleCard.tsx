import type { CSSProperties } from 'react'
import { Link } from '@tanstack/react-router'
import { CoverMediaView } from '@/components/CoverMedia'
import { Badge } from '@/components/ui/badge'
import { interpolate } from '@/i18n'
import { useApp } from '@/lib/app-context'
import type { CoverMedia } from '@/lib/frontmatter'

const TAG_FILLS = [
  'var(--color-highlight)',
  'var(--color-accent)',
  'color-mix(in srgb, var(--color-highlight) 62%, var(--color-accent))',
  'color-mix(in srgb, var(--color-accent) 48%, var(--color-ground))',
] as const

function tagStyle(tag: string, index: number): CSSProperties {
  let hash = 0
  for (let i = 0; i < tag.length; i++) hash = (hash * 33 + tag.charCodeAt(i)) >>> 0
  const tone = hash % TAG_FILLS.length
  const tilt = ((hash % 7) - 3) * 0.55
  return {
    '--tag-fill': TAG_FILLS[tone],
    '--tag-tilt': `${tilt}deg`,
    '--tag-delay': `${index * 90}ms`,
  } as CSSProperties
}

export function ArticleCard({
  slug,
  title,
  excerpt,
  tags,
  figure,
  cover,
}: {
  slug: string
  title: string
  excerpt: string
  tags: string[]
  figure: number
  cover?: CoverMedia
}) {
  const { t } = useApp()

  return (
    <Link
      to="/posts/$"
      params={{ _splat: slug }}
      className="group grid items-start gap-4 sm:grid-cols-[160px_1fr]"
    >
      <div className="w-full border border-ink bg-surface sm:w-[160px]">
        <div className="flex h-7 items-center gap-1.5 border-b border-ink/40 px-2">
          <span className="h-1.5 w-1.5 rounded-full bg-ink/70" />
          <span className="h-1.5 w-1.5 rounded-full bg-ink/70" />
          <span className="h-1.5 w-1.5 rounded-full bg-ink/70" />
          <span className="mx-auto font-mono text-[11px] text-muted">
            {interpolate(t.article.figure, { n: figure })}
          </span>
        </div>
        <div className="article-card-check relative h-28 overflow-hidden">
          {cover ? (
            <CoverMediaView
              media={cover}
              className="absolute inset-0 size-full object-cover"
            />
          ) : (
            <div className="flex h-full items-center justify-center">
              <div className="h-10 w-16 border border-ink/50" />
            </div>
          )}
        </div>
      </div>

      <div className="min-w-0">
        <h3 className="text-2xl font-semibold tracking-tight group-hover:underline underline-offset-4">
          {title}
        </h3>
        <p className="mt-2 text-base leading-relaxed text-ink/80">{excerpt}</p>
        {tags.length > 0 && (
          <div className="mt-3 flex flex-wrap gap-1.5">
            {tags.map((tag, i) => (
              <Badge key={tag} className="article-tag" style={tagStyle(tag, i)}>
                {tag}
              </Badge>
            ))}
          </div>
        )}
      </div>
    </Link>
  )
}
