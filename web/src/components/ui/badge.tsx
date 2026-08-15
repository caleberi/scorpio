import type { ReactNode } from 'react'
import { cn } from '@/lib/utils'

export function Badge({
  children,
  className,
}: {
  children: ReactNode
  className?: string
}) {
  return (
    <span
      className={cn(
        'inline-flex items-center rounded-sm border border-ink/70 bg-transparent px-2 py-0.5 font-mono text-[11px] uppercase tracking-wide',
        className,
      )}
    >
      {children}
    </span>
  )
}
