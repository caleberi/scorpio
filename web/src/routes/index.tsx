import { useEffect, useMemo, useRef } from 'react'
import { createFileRoute } from '@tanstack/react-router'
import { ArticleCard } from '@/components/ArticleCard'
import { PageFrame } from '@/components/PageFrame'
import { Pagination } from '@/components/Pagination'
import { ShreddedPaperField } from '@/components/ShreddedPaperField'
import { SponsorWheel } from '@/components/SponsorWheel'
import { useDocumentCards } from '@/hooks/useDocumentCards'
import { useApp } from '@/lib/app-context'
import { LIST_PAGE_SIZE } from '@/lib/constants'

export const Route = createFileRoute('/')({
  validateSearch: (search: Record<string, unknown>): { page?: number } => {
    const page = parsePage(search.page)
    return page <= 1 ? {} : { page }
  },
  component: BlogIndex,
})

function parsePage(value: unknown): number {
  const n =
    typeof value === 'number'
      ? value
      : typeof value === 'string'
        ? Number.parseInt(value, 10)
        : 1
  if (!Number.isFinite(n) || n < 1) return 1
  return Math.floor(n)
}

function BlogIndex() {
  const { page: pageParam } = Route.useSearch()
  const navigate = Route.useNavigate()
  const { documents, documentsLoading, documentsError, t } = useApp()

  const page = pageParam ?? 1
  const totalPages = Math.max(1, Math.ceil(documents.length / LIST_PAGE_SIZE))
  const currentPage = documentsLoading ? page : Math.min(page, totalPages)

  useEffect(() => {
    if (documentsLoading) return
    if (page === currentPage) return
    void navigate({
      search: currentPage <= 1 ? {} : { page: currentPage },
      replace: true,
    })
  }, [documentsLoading, page, currentPage, navigate])

  const skipScroll = useRef(true)
  useEffect(() => {
    if (skipScroll.current) {
      skipScroll.current = false
      return
    }
    window.scrollTo({ top: 0, behavior: 'smooth' })
  }, [currentPage])

  const pageDocs = useMemo(() => {
    const start = (currentPage - 1) * LIST_PAGE_SIZE
    return documents.slice(start, start + LIST_PAGE_SIZE)
  }, [documents, currentPage])

  const cards = useDocumentCards(pageDocs)
  const pageReady =
    cards.length === pageDocs.length &&
    cards.every((card, i) => card.slug === pageDocs[i]?.slug)

  return (
    <PageFrame>
      <div className="relative isolate">
        <ShreddedPaperField />
        <div className="relative z-10">
          <div className="section-label grid-plus border-b border-ink/30 pb-2">
            {t.index.related}
          </div>

          {documentsLoading && (
            <p className="mt-6 font-mono text-sm text-muted">{t.index.loadingPosts}</p>
          )}
          {documentsError && (
            <p className="mt-6 font-mono text-sm text-red-700">{documentsError}</p>
          )}

          {!documentsLoading && !documentsError && documents.length > 0 && !pageReady && (
            <p className="mt-6 font-mono text-sm text-muted">{t.index.loadingPosts}</p>
          )}

          {pageReady && !documentsLoading && !documentsError && (
            <div className="mt-8 grid gap-10 lg:grid-cols-2 lg:gap-x-10 lg:divide-x lg:divide-dashed lg:divide-ink/30">
              {cards.map((card, i) => (
                <div key={card.slug} className={i % 2 === 1 ? 'lg:pl-10' : ''}>
                  <ArticleCard
                    slug={card.slug}
                    title={card.title}
                    excerpt={card.excerpt}
                    tags={card.tags}
                    figure={(currentPage - 1) * LIST_PAGE_SIZE + i + 1}
                    cover={card.cover}
                  />
                </div>
              ))}
            </div>
          )}

          {!documentsLoading && !documentsError && cards.length === 0 && pageReady && (
            <p className="mt-6 font-mono text-sm text-muted">{t.index.empty}</p>
          )}

          {!documentsLoading && !documentsError && documents.length > 0 && (
            <Pagination
              page={currentPage}
              totalPages={totalPages}
              prevLabel={t.index.prevPage}
              nextLabel={t.index.nextPage}
              pageOf={t.index.pageOf}
              ariaLabel={t.index.pagination}
            />
          )}
        </div>
        <SponsorWheel />
      </div>
    </PageFrame>
  )
}
