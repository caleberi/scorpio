import { useMemo } from 'react'
import { useRouterState } from '@tanstack/react-router'
import { ArticleCard } from '@/components/ArticleCard'
import { LocaleSelect } from '@/components/LocaleSelect'
import { useDocumentCards } from '@/hooks/useDocumentCards'
import { useApp } from '@/lib/app-context'
import { POSTS_PREFIX, RELATED_ARTICLE_COUNT } from '@/lib/constants'
import { SOCIAL } from '@/lib/socials'

export function Footer() {
  const { documents, t } = useApp()
  const pathname = useRouterState({ select: (s) => s.location.pathname })
  const currentSlug = pathname.startsWith(POSTS_PREFIX)
    ? decodeURIComponent(pathname.slice(POSTS_PREFIX.length))
    : null

  const cards = useDocumentCards(documents)
  const related = useMemo(
    () => cards.filter((c) => c.slug !== currentSlug).slice(0, RELATED_ARTICLE_COUNT),
    [cards, currentSlug],
  )

  const socialLinks = [
    { label: t.footer.linkedin, href: SOCIAL.linkedin },
    { label: t.footer.twitter, href: SOCIAL.x },
    { label: t.footer.instagram, href: SOCIAL.instagram },
    { label: t.footer.github, href: SOCIAL.github },
  ]

  return (
    <footer className="border-t border-ink/30 bg-ground">
      <div className="mx-auto max-w-[1400px] px-4 py-10 md:px-6">
        <div className="section-label grid-plus border-b border-ink/25 pb-4">
          {t.footer.related}
        </div>

        <div className="mt-8 grid gap-10 lg:grid-cols-2 lg:gap-x-10 lg:divide-x lg:divide-dashed lg:divide-ink/30">
          {related.map((card, i) => (
            <div key={card.slug} className={i === 1 ? 'lg:pl-10' : ''}>
              <ArticleCard
                slug={card.slug}
                title={card.title}
                excerpt={card.excerpt}
                tags={card.tags}
                figure={i + 1}
              />
            </div>
          ))}
          {related.length === 0 && (
            <p className="font-mono text-sm text-muted">{t.footer.empty}</p>
          )}
        </div>

        <div className="mt-12 flex flex-wrap items-end justify-between gap-6 border-t border-ink/25 pt-8">
          <div>
            <div className="section-label mb-2">{t.footer.social}</div>
            <div className="flex flex-wrap gap-4 font-mono text-[13px] uppercase tracking-wide text-ink/80">
              {socialLinks.map((link) => (
                <a
                  key={link.label}
                  href={link.href}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="hover:underline underline-offset-4"
                >
                  {link.label}
                </a>
              ))}
            </div>
          </div>

          <div className="flex items-end gap-6">
            <LocaleSelect className="w-36 md:hidden" />
            <div className="flex items-center gap-2 font-mono text-[13px] uppercase tracking-wide text-ink/80">
              <span>{t.footer.builtWith}</span>
              <ZigLogo className="h-5 w-5" />
            </div>
          </div>
        </div>
      </div>
    </footer>
  )
}

function ZigLogo({ className }: { className?: string }) {
  return (
    <svg
      className={className}
      viewBox="0 0 100 56"
      xmlns="http://www.w3.org/2000/svg"
      aria-label="Zig"
      role="img"
    >
      <rect width="100" height="56" rx="4" fill="#F7A41D" />
      <path fill="#000" d="M18 14h64l-46 28h46v8H18l46-28H18z" />
    </svg>
  )
}
