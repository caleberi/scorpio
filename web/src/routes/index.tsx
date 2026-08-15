import { createFileRoute } from '@tanstack/react-router'
import { ArticleCard } from '@/components/ArticleCard'
import { useDocumentCards } from '@/hooks/useDocumentCards'
import { useApp } from '@/lib/app-context'

export const Route = createFileRoute('/')({
  component: BlogIndex,
})

function BlogIndex() {
  const { documents, documentsLoading, documentsError, t } = useApp()
  const cards = useDocumentCards(documents)

  return (
    <div>
      <div className="section-label grid-plus border-b border-ink/30 pb-2">
        {t.index.related}
      </div>

      {documentsLoading && (
        <p className="mt-6 font-mono text-sm text-muted">{t.index.loadingPosts}</p>
      )}
      {documentsError && (
        <p className="mt-6 font-mono text-sm text-red-700">{documentsError}</p>
      )}

      <div className="mt-8 grid gap-10 lg:grid-cols-2 lg:gap-x-10 lg:divide-x lg:divide-dashed lg:divide-ink/30">
        {cards.map((card, i) => (
          <div key={card.slug} className={i % 2 === 1 ? 'lg:pl-10' : ''}>
            <ArticleCard
              slug={card.slug}
              title={card.title}
              excerpt={card.excerpt}
              tags={card.tags}
              figure={i + 1}
            />
          </div>
        ))}
      </div>

      {!documentsLoading && !documentsError && cards.length === 0 && (
        <p className="mt-6 font-mono text-sm text-muted">{t.index.empty}</p>
      )}
    </div>
  )
}
