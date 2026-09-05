import { Link, createFileRoute } from '@tanstack/react-router'
import { useMemo, useRef, useState } from 'react'
import { CoverMediaView } from '@/components/CoverMedia'
import { CommentsSection } from '@/components/CommentsSection'
import { MarkdownBody } from '@/components/MarkdownBody'
import { PageFrame } from '@/components/PageFrame'
import { PostMetadata } from '@/components/PostMetadata'
import { PostTitle } from '@/components/PostTitle'
import { Sidebar } from '@/components/Sidebar'
import { Button } from '@/components/ui/button'
import { getDocument } from '@/lib/api'
import { BLOG_PREFIX } from '@/lib/constants'
import { useApp } from '@/lib/app-context'
import { useReadingLayout } from '@/hooks/useReadingLayout'
import {
  categoriesFromPath,
  coverMedia,
  firstHeading,
  formatStripeDate,
  parseFrontmatter,
  readingTimeMinutes,
  rewriteContentImages,
} from '@/lib/frontmatter'
import { cn } from '@/lib/utils'

export const Route = createFileRoute('/posts/$')({
  loader: async ({ params }) => {
    const slug = params._splat
    if (!slug) throw new Error('Missing post slug')
    return getDocument(slug)
  },
  errorComponent: PostError,
  component: BlogPost,
})

function PostError({ error }: { error: Error }) {
  const { t } = useApp()
  const message = error.message || t.post.missingTitle

  return (
    <PageFrame>
      <div className="mx-auto max-w-xl py-10">
        <div className="section-label grid-plus border-b border-ink/30 pb-2">
          {t.post.missingLabel}
        </div>
        <h1 className="mt-6 text-3xl font-bold tracking-tight">
          {t.post.missingTitle}
        </h1>
        <p className="mt-3 text-base leading-relaxed text-ink/80">{message}</p>
        <p className="mt-2 font-mono text-[13px] text-muted">
          {t.post.missingTipBefore}{' '}
          <code className="text-ink">{BLOG_PREFIX.replace(/\/$/, '')}</code>{' '}
          {t.post.missingTipAfter}{' '}
          <code className="text-ink">/posts/blog/sample</code>.
        </p>
        <div className="mt-6">
          <Button asChild variant="outline" size="sm">
            <Link to="/">{t.post.back}</Link>
          </Button>
        </div>
      </div>
    </PageFrame>
  )
}

function BlogPost() {
  const { t } = useApp()
  const doc = Route.useLoaderData()
  const [showMarkdown, setShowMarkdown] = useState(false)
  const titleRef = useRef<HTMLElement>(null)
  const reading = useReadingLayout(titleRef)

  const parsed = useMemo(() => parseFrontmatter(doc.content), [doc.content])
  const body = useMemo(
    () => rewriteContentImages(parsed.content),
    [parsed.content],
  )

  const title =
    parsed.data.title?.trim() || firstHeading(parsed.content) || doc.slug
  const author = parsed.data.authors?.[0] ?? t.post.unknownAuthor
  const date = formatStripeDate(parsed.data.date, doc.modified_at)
  const readingTime = readingTimeMinutes(parsed.content)
  const categories =
    parsed.data.topics?.map((topic) => topic.toUpperCase()) ??
    categoriesFromPath(doc.path)
  const cover = coverMedia(parsed.data.image)

  return (
    <article className={cn('post-shell', reading && 'is-reading')}>
      <div className="post-shell-rail">
        <PostTitle ref={titleRef} title={title} className="post-shell-title" />
        <aside className="post-shell-meta">
          <PostMetadata
            title={title}
            date={date}
            author={author}
            readingTime={readingTime}
            categories={categories}
            markdown={doc.content}
            onViewMarkdown={() => setShowMarkdown((v) => !v)}
          />
        </aside>
      </div>
      <Sidebar className="post-shell-tree" />

      <div className="post-shell-body">
        {reading ? null : (
          <div className="section-label grid-plus border-b border-ink/30 pb-2">
            {t.post.article}
          </div>
        )}
        {showMarkdown ? (
          <pre
            className={cn(
              'overflow-x-auto whitespace-pre-wrap border border-ink/20 bg-surface p-4 font-mono text-[13px] leading-relaxed',
              !reading && 'mt-6',
            )}
          >
            {doc.content}
          </pre>
        ) : (
          <>
            {cover ? (
              <div className="post-cover">
                <CoverMediaView media={cover} eager />
              </div>
            ) : null}
            <MarkdownBody
              content={body}
              className={cover || reading ? undefined : 'mt-6'}
            />
          </>
        )}

        <CommentsSection slug={doc.slug} />
      </div>
    </article>
  )
}
