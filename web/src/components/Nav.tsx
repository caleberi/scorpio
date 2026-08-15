import { Link } from '@tanstack/react-router'
import { useApp } from '@/lib/app-context'
import { SOCIAL } from '@/lib/socials'
import { cn } from '@/lib/utils'

type NavItem =
  | { key: string; kind: 'route'; label: string; to: '/' }
  | { key: string; kind: 'external'; label: string; href: string }

export function Nav() {
  const { toggleConsole, t } = useApp()

  const links: NavItem[] = [
    { key: 'B', kind: 'route', label: t.nav.blog, to: '/' },
    { key: 'G', kind: 'external', label: t.nav.github, href: SOCIAL.github },
    {
      key: 'U',
      kind: 'external',
      label: t.nav.community,
      href: SOCIAL.community,
    },
  ]

  return (
    <header className="border-b border-ink/40 bg-ground">
      <div className="mx-auto flex max-w-[1400px] items-center justify-between gap-4 px-4 py-3 md:px-6">
        <nav className="flex flex-wrap items-center gap-x-4 gap-y-2 font-mono text-[13px] uppercase tracking-wide">
          <span
            aria-hidden
            className="inline-block h-3.5 w-3.5 bg-ink"
            title="Scorpio"
          />
          {links.map((item) => {
            switch (item.kind) {
              case 'route':
                return (
                  <Link
                    key={item.key}
                    to={item.to}
                    className="hover:underline underline-offset-4"
                  >
                    <span className="text-muted">[{item.key}]</span> {item.label}
                  </Link>
                )
              case 'external':
                return (
                  <a
                    key={item.key}
                    href={item.href}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="hover:underline underline-offset-4"
                  >
                    <span className="text-muted">[{item.key}]</span> {item.label}
                  </a>
                )
            }
          })}
        </nav>
        <button
          type="button"
          onClick={toggleConsole}
          className={cn(
            'shrink-0 border border-ink/50 bg-surface px-2.5 py-1.5 font-mono text-[13px] uppercase tracking-wide',
            'hover:bg-black/[0.03]',
          )}
        >
          <span className="text-muted">[C]</span> {t.nav.console}
        </button>
      </div>
    </header>
  )
}
