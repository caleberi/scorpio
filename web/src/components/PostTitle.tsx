import { cn } from '@/lib/utils'

export function PostTitle({
  title,
  className,
}: {
  title: string
  className?: string
}) {
  return (
    <header className={cn('grid-plus border-b border-ink/30 pb-8 pt-2', className)}>
      <h1 className="post-title font-bold tracking-[-0.04em] text-ink">{title}</h1>
    </header>
  )
}
