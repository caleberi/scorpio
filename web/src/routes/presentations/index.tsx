import { useEffect, useMemo, useRef } from 'react'
import { createFileRoute } from '@tanstack/react-router'
import { ArticleCard } from '@/components/ArticleCard'
import { PageFrame } from '@/components/PageFrame'
import { Pagination } from '@/components/Pagination'
import { useDocumentCards } from '@/hooks/useDocumentCards'
import { useApp } from '@/lib/app-context'
import type { BlogListing } from '@/lib/api'
import { LIST_PAGE_SIZE } from '@/lib/constants'
import { coverMedia } from '@/lib/frontmatter'
import { formatClock, type PresentationListing } from '@/lib/presentation'

export const Route = createFileRoute('/presentations/')({
  validateSearch: (search: Record<string, unknown>): { page?: number } => {
    const page = parsePage(search.page)
    return page <= 1 ? {} : { page }
  },
  component: SlidesIndex,
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

function SlidesIndex() {
  const { page: pageParam } = Route.useSearch()
  const navigate = Route.useNavigate()
  const { presentations, presentationsLoading, presentationsError, t } = useApp()

  const page = pageParam ?? 1
  const totalPages = Math.max(1, Math.ceil(presentations.length / LIST_PAGE_SIZE))
  const currentPage = presentationsLoading ? page : Math.min(page, totalPages)

  useEffect(() => {
    if (presentationsLoading) return
    if (page === currentPage) return
    void navigate({
      search: currentPage <= 1 ? {} : { page: currentPage },
      replace: true,
    })
  }, [presentationsLoading, page, currentPage, navigate])

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
    return presentations.slice(start, start + LIST_PAGE_SIZE)
  }, [presentations, currentPage])

  const listings = useMemo(() => {
    const missingCover = pageDocs.some((deck) => !coverMedia(deck.image))
    return missingCover ? pageDocs.map(deckToListing) : []
  }, [pageDocs])
  const cards = useDocumentCards(listings)

  return (
    <PageFrame sidebarKind="slides">
      <div className="section-label grid-plus border-b border-ink/30 pb-2">
        {t.slides.related}
      </div>

      {presentationsLoading && (
        <p className="mt-6 font-mono text-sm text-muted">{t.slides.loading}</p>
      )}
      {presentationsError && (
        <p className="mt-6 font-mono text-sm text-red-700">{presentationsError}</p>
      )}

      {!presentationsLoading && !presentationsError && pageDocs.length > 0 && (
        <div className="mt-8 grid gap-10 lg:grid-cols-2 lg:gap-x-10 lg:divide-x lg:divide-dashed lg:divide-ink/30">
          {pageDocs.map((deck, i) => (
            <div key={deck.slug} className={i % 2 === 1 ? 'lg:pl-10' : ''}>
              <ArticleCard
                slug={deck.slug}
                title={deck.title}
                excerpt={`${formatClock(deck.duration_ms)} · ${deck.size.w}×${deck.size.h} · ${deck.path}`}
                tags={[]}
                figure={(currentPage - 1) * LIST_PAGE_SIZE + i + 1}
                cover={
                  coverMedia(deck.image) ??
                  (cards[i]?.slug === deck.slug ? cards[i]?.cover : undefined)
                }
                to="/presentations/$"
              />
            </div>
          ))}
        </div>
      )}

      {!presentationsLoading && !presentationsError && presentations.length === 0 && (
        <p className="mt-6 font-mono text-sm text-muted">{t.slides.empty}</p>
      )}

      {!presentationsLoading && !presentationsError && presentations.length > 0 && (
        <Pagination
          page={currentPage}
          totalPages={totalPages}
          prevLabel={t.index.prevPage}
          nextLabel={t.index.nextPage}
          pageOf={t.index.pageOf}
          ariaLabel={t.slides.pagination}
          to="/presentations"
        />
      )}
    </PageFrame>
  )
}

function deckToListing(deck: PresentationListing): BlogListing {
  return {
    slug: deck.slug,
    path: deck.path,
    modified_at: 0,
    length: 0,
  }
}
