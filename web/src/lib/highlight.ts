export const HIGHLIGHT_COLORS = {
  lime: '#c8f542',
  amber: '#f6c244',
  orange: '#ff8a3d',
  mint: '#7dffb3',
  violet: '#d4b3ff',
  coral: '#ff7a90',
  sky: '#7ec8ff',
} as const

export type HighlightName = keyof typeof HIGHLIGHT_COLORS

export const THEME_NAMES = [
  'light',
  'alt',
  'paper',
  'amber',
  'mint',
  'violet',
  'coral',
  'sky',
] as const

export type ThemeName = (typeof THEME_NAMES)[number]

/** Theme → default title highlight */
export const THEME_HIGHLIGHT: Record<ThemeName, HighlightName> = {
  light: 'lime',
  alt: 'orange',
  paper: 'amber',
  amber: 'amber',
  mint: 'mint',
  violet: 'violet',
  coral: 'coral',
  sky: 'sky',
}

export function isThemeName(name: string): name is ThemeName {
  return (THEME_NAMES as readonly string[]).includes(name)
}

export function isHighlightName(name: string): name is HighlightName {
  return name in HIGHLIGHT_COLORS
}

export function highlightFromSlug(slug: string): HighlightName {
  const keys = Object.keys(HIGHLIGHT_COLORS) as HighlightName[]
  let hash = 0
  for (let i = 0; i < slug.length; i++) {
    hash = (hash * 31 + slug.charCodeAt(i)) >>> 0
  }
  return keys[hash % keys.length]
}

export function resolveHighlightColor(opts: {
  frontmatter?: string
  slug: string
  theme: string
}): string {
  const raw = opts.frontmatter?.trim().toLowerCase()
  if (raw) {
    if (isHighlightName(raw)) return HIGHLIGHT_COLORS[raw]
    if (/^#([0-9a-f]{3}|[0-9a-f]{6})$/i.test(raw)) return raw
  }

  if (isThemeName(opts.theme)) {
    return HIGHLIGHT_COLORS[THEME_HIGHLIGHT[opts.theme]]
  }

  return HIGHLIGHT_COLORS[highlightFromSlug(opts.slug)]
}

/** Split title so the first token (incl. trailing `:`) can be highlighted. */
export function splitTitleHighlight(title: string): {
  head: string
  rest: string
} {
  const match = title.match(/^(\S+:)(\s*)([\s\S]*)$/)
  if (match) {
    return { head: match[1], rest: `${match[2]}${match[3]}` }
  }
  const space = title.indexOf(' ')
  if (space === -1) return { head: title, rest: '' }
  return { head: title.slice(0, space), rest: title.slice(space) }
}
