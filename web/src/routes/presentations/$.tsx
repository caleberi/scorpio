import { Link, createFileRoute } from '@tanstack/react-router'
import { PageFrame } from '@/components/PageFrame'
import { PresentationPlayer } from '@/components/PresentationPlayer'
import { Button } from '@/components/ui/button'
import { getPresentation } from '@/lib/api'
import { useApp } from '@/lib/app-context'

export const Route = createFileRoute('/presentations/$')({
  loader: async ({ params }) => {
    const slug = params._splat
    if (!slug) throw new Error('Missing presentation slug')
    return getPresentation(slug)
  },
  errorComponent: PresentationError,
  component: PresentationPage,
})

function PresentationError({ error }: { error: Error }) {
  const { t } = useApp()
  const message = error.message || t.slides.missingTitle

  return (
    <PageFrame sidebarKind="slides">
      <div className="mx-auto max-w-xl py-10">
        <div className="section-label grid-plus border-b border-ink/30 pb-2">
          {t.slides.missingLabel}
        </div>
        <h1 className="mt-6 text-3xl font-bold tracking-tight">
          {t.slides.missingTitle}
        </h1>
        <p className="mt-3 text-base leading-relaxed text-ink/80">{message}</p>
        <div className="mt-6">
          <Button asChild variant="outline" size="sm">
            <Link to="/presentations">{t.slides.back}</Link>
          </Button>
        </div>
      </div>
    </PageFrame>
  )
}

function PresentationPage() {
  const { t } = useApp()
  const deck = Route.useLoaderData()

  return (
    <PageFrame sidebarKind="slides">
      <div className="section-label grid-plus border-b border-ink/30 pb-2">
        {t.slides.related}
      </div>
      <div className="mt-6 flex flex-wrap items-end justify-between gap-4">
        <h1 className="text-3xl font-bold tracking-tight">{deck.title}</h1>
        <Button asChild variant="outline" size="sm">
          <Link to="/presentations">{t.slides.back}</Link>
        </Button>
      </div>
      <div className="mt-6">
        <PresentationPlayer deck={deck} />
      </div>
    </PageFrame>
  )
}
