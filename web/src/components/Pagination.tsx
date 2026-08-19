import { Link } from '@tanstack/react-router'
import { interpolate } from '@/i18n'
import { cn } from '@/lib/utils'

export function Pagination({
  page,
  totalPages,
  prevLabel,
  nextLabel,
  pageOf,
  ariaLabel,
}: {
  page: number
  totalPages: number
  prevLabel: string
  nextLabel: string
  pageOf: string
  ariaLabel: string
}) {
  if (totalPages <= 1) return null

  const status = interpolate(pageOf, { page, pages: totalPages })

  return (
    <nav
      aria-label={ariaLabel}
      className="mt-12 grid-plus flex items-center justify-between border-t border-ink/30 pt-4"
    >
      <PaginationLink
        page={page - 1}
        enabled={page > 1}
        label={prevLabel}
      />
      <span className="section-label px-3 text-center">{status}</span>
      <PaginationLink
        page={page + 1}
        enabled={page < totalPages}
        label={nextLabel}
        align="right"
      />
    </nav>
  )
}

function PaginationLink({
  page,
  enabled,
  label,
  align = 'left',
}: {
  page: number
  enabled: boolean
  label: string
  align?: 'left' | 'right'
}) {
  const className = cn(
    'flex-1 font-mono text-[13px] uppercase tracking-wide',
    align === 'right' && 'text-right',
    enabled
      ? 'text-ink hover:underline underline-offset-4'
      : 'pointer-events-none text-muted',
  )

  if (!enabled) {
    return (
      <span className={className} aria-disabled="true">
        {label}
      </span>
    )
  }

  return (
    <Link
      to="/"
      search={page <= 1 ? {} : { page }}
      className={className}
    >
      {label}
    </Link>
  )
}
