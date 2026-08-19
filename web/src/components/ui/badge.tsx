import type { CSSProperties, ReactNode } from 'react'
import { cn } from '@/lib/utils'

export function Badge({
  children,
  className,
  style,
}: {
  children: ReactNode
  className?: string
  style?: CSSProperties
}) {
  return (
    <span
      style={style}
      className={cn(
        'inline-flex items-center rounded-sm border border-ink/70 bg-transparent px-2 py-0.5 font-mono text-[11px] uppercase tracking-wide',
        className,
      )}
    >
      {children}
    </span>
  )
}
