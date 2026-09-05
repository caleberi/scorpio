import type { CoverMedia } from '@/lib/frontmatter'
import { cn } from '@/lib/utils'

export function CoverMediaView({
  media,
  className,
  eager,
}: {
  media: CoverMedia
  className?: string
  eager?: boolean
}) {
  switch (media.kind) {
    case 'video':
      return (
        <video
          src={media.src}
          className={cn('cover-media', className)}
          autoPlay={media.autoplay}
          loop={media.loop}
          muted={media.muted ?? true}
          playsInline={media.playsInline ?? true}
          preload="auto"
          aria-hidden
        />
      )
    case 'image':
      return (
        <img
          src={media.src}
          alt=""
          width={860}
          height={460}
          className={cn('cover-media', className)}
          loading={eager ? 'eager' : 'lazy'}
          decoding="async"
          referrerPolicy="no-referrer"
        />
      )
  }
}
