import { cn } from '@/lib/utils'

function Plus({ className }: { className: string }) {
  return (
    <span
      aria-hidden
      className={cn(
        'pointer-events-none absolute font-mono text-[13px] leading-none text-muted',
        className,
      )}
    >
      +
    </span>
  )
}

export function PostTitle({
  title,
  className,
  ref,
}: {
  title: string
  className?: string
  ref?: React.Ref<HTMLElement>
}) {
  return (
    <header
      ref={ref}
      className={cn(
        'relative border-b border-ink/30 px-4 pb-10 pt-8 md:px-8',
        className,
      )}
    >
      <Plus className="-top-2 left-0" />
      <Plus className="-top-2 right-0" />
      <Plus className="-bottom-2 left-0" />
      <Plus className="-bottom-2 right-0" />
      <h1 className="post-title text-ink">{title}</h1>
    </header>
  )
}
