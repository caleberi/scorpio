import type { BlogDocument, BlogListing } from '@/lib/api'
import { EXCERPT_MAX_CHARS } from '@/lib/constants'
import {
  categoriesFromPath,
  coverMedia,
  firstHeading,
  parseFrontmatter,
  type CoverMedia,
} from '@/lib/frontmatter'

export type CardData = {
  slug: string
  title: string
  excerpt: string
  tags: string[]
  cover?: CoverMedia
}

export function listingToCard(
  doc: BlogListing,
  full: BlogDocument | null,
): CardData {
  if (!full) {
    return {
      slug: doc.slug,
      title: doc.slug,
      excerpt: doc.path,
      tags: categoriesFromPath(doc.path),
    }
  }

  const parsed = parseFrontmatter(full.content)
  const excerptSource =
    parsed.data.summary?.trim() ||
    parsed.content.replace(/^#.+$/m, '').trim()

  return {
    slug: doc.slug,
    title: parsed.data.title?.trim() || firstHeading(parsed.content) || doc.slug,
    excerpt:
      excerptSource.length > EXCERPT_MAX_CHARS
        ? `${excerptSource.slice(0, EXCERPT_MAX_CHARS)}…`
        : excerptSource,
    tags:
      parsed.data.topics?.map((t) => t.toUpperCase()) ??
      categoriesFromPath(doc.path),
    cover: coverMedia(parsed.data.image),
  }
}
