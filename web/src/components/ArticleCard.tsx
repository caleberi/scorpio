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
  to = '/posts/$',
}: {
  slug: string
  title: string
  excerpt: string
  tags: string[]
  figure: number
  cover?: CoverMedia
  to?: '/posts/$' | '/presentations/$'
}) {
  const { t } = useApp()

  return (
    <Link
      to={to}
      params={{ _splat: slug }}
      className="article-card group"
    >
      <div className="article-card-layout">
        <div className="article-card-figure">
          <div className="flex h-7 items-center gap-1.5 border-b border-ink/40 px-2">
            <span className="h-1.5 w-1.5 rounded-full bg-ink/70" />
            <span className="h-1.5 w-1.5 rounded-full bg-ink/70" />
            <span className="h-1.5 w-1.5 rounded-full bg-ink/70" />
            <span className="mx-auto font-mono text-[11px] text-muted">
              {interpolate(t.article.figure, { n: figure })}
            </span>
          </div>
          <div className="article-card-check relative overflow-hidden">
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
          <h3 className="article-card-title font-semibold tracking-tight group-hover:underline underline-offset-4">
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
      </div>
    </Link>
  )
}
