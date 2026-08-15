import { Link, createFileRoute } from '@tanstack/react-router'
import { useMemo, useState } from 'react'
import { CommentsSection } from '@/components/CommentsSection'
import { MarkdownBody } from '@/components/MarkdownBody'
import { PostMetadata } from '@/components/PostMetadata'
import { PostTitle } from '@/components/PostTitle'
import { Button } from '@/components/ui/button'
import { getDocument } from '@/lib/api'
import { BLOG_PREFIX } from '@/lib/constants'
import { useApp } from '@/lib/app-context'
import {
  categoriesFromPath,
  firstHeading,
  formatStripeDate,
  parseFrontmatter,
  readingTimeMinutes,
  rewriteContentImages,
} from '@/lib/frontmatter'

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
  )
}

function BlogPost() {
  const { t } = useApp()
  const doc = Route.useLoaderData()
  const [showMarkdown, setShowMarkdown] = useState(false)

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

  return (
    <article>
      <PostTitle title={title} className="mb-10" />

      <div className="grid gap-10 lg:grid-cols-[minmax(200px,26%)_minmax(0,1fr)] lg:gap-14">
        <aside className="lg:sticky lg:top-6 lg:self-start">
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

        <div className="min-w-0">
          <div className="section-label grid-plus border-b border-ink/30 pb-2">
            {t.post.article}
          </div>
          {showMarkdown ? (
            <pre className="mt-6 overflow-x-auto whitespace-pre-wrap border border-ink/20 bg-surface p-4 font-mono text-[13px] leading-relaxed">
              {doc.content}
            </pre>
          ) : (
            <MarkdownBody content={body} className="mt-6" />
          )}

          <CommentsSection slug={doc.slug} />
        </div>
      </div>
    </article>
  )
}
