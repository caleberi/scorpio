import {
  NS_TO_MS,
  NS_TO_MS_THRESHOLD,
  WORDS_PER_MINUTE,
} from '@/lib/constants'

export type PostMeta = {
  title?: string
  summary?: string
  authors?: string[]
  date?: string
  topics?: string[]
  type?: string
  /** Cover: a URL, markdown `![alt](url)`, or an HTML `<video src="…">`. */
  image?: string
  /** Highlight name (lime, amber, …) or hex color for the title mark */
  highlight?: string
}

export type ParsedPost = {
  data: PostMeta
  content: string
}

export type CoverMedia = {
  kind: 'image' | 'video'
  src: string
  autoplay?: boolean
  loop?: boolean
  muted?: boolean
  playsInline?: boolean
}

const FRONTMATTER_OPEN = '---'
const LIST_ITEM = /^\s+-\s+/
const KEY_VALUE = /^([A-Za-z0-9_]+):\s*(.*)$/
const HEADING = /^#\s+(.+)$/m
const STRIPE_IMAGE_PREFIX = /(!\[[^\]]*\]\()(\/images\/)/g
const STRIPE_IMAGE_CDN = 'https://stripe.dev/images/'
const GITHUB_BLOB =
  /https:\/\/github\.com\/([^/\s"')]+)\/([^/\s"')]+)\/blob\/([^/\s"')]+)\/([^)"'\s]+)/g
const GITHUB_RAW =
  /https:\/\/github\.com\/([^/\s"')]+)\/([^/\s"')]+)\/raw\/([^/\s"')]+)\/([^)"'\s]+)/g
const GITHUB_RAW_CDN = 'https://raw.githubusercontent.com/$1/$2/$3/$4'
/** Hashnode / MDX-style: `![](https://cdn…/file.png align="center")` */
const ATTR_MARKDOWN_IMAGE =
  /!\[([^\]]*)\]\(\s*(<[^>]+>|https?:\/\/[^\s)]+|[^\s)]+)([^)]*)\)/g

/** Minimal YAML frontmatter parser for the fields we use. */
export function parseFrontmatter(raw: string): ParsedPost {
  if (!raw.startsWith(FRONTMATTER_OPEN)) {
    return { data: {}, content: raw }
  }

  const end = raw.indexOf(`\n${FRONTMATTER_OPEN}`, 3)
  if (end === -1) {
    return { data: {}, content: raw }
  }

  const yaml = raw.slice(4, end).trim()
  const content = raw.slice(end + 4).replace(/^\n+/, '')
  const data = parseSimpleYaml(yaml)
  return { data, content }
}

function parseSimpleYaml(yaml: string): PostMeta {
  const data: PostMeta = {}
  const lines = yaml.split('\n')
  let i = 0

  while (i < lines.length) {
    const line = lines[i]
    const match = line.match(KEY_VALUE)
    if (!match) {
      i += 1
      continue
    }

    const key = match[1]
    let value = match[2].trim()

    switch (value) {
      case '':
      case '|':
      case '>': {
        const items: string[] = []
        i += 1
        while (i < lines.length && LIST_ITEM.test(lines[i])) {
          items.push(unquote(lines[i].replace(LIST_ITEM, '').trim()))
          i += 1
        }
        assignList(data, key, items)
        continue
      }
      default:
        break
    }

    if (value.startsWith('[') && value.endsWith(']')) {
      const inner = value.slice(1, -1).trim()
      const items = inner
        ? inner.split(',').map((s) => unquote(s.trim()))
        : []
      assignList(data, key, items)
      i += 1
      continue
    }

    assignScalar(data, key, unquote(value))
    i += 1
  }

  return data
}

function assignScalar(data: PostMeta, key: string, value: string) {
  switch (key) {
    case 'title':
      data.title = value
      break
    case 'summary':
      data.summary = value
      break
    case 'date':
      data.date = value
      break
    case 'type':
      data.type = value
      break
    case 'image':
      data.image = value
      break
    case 'highlight':
      data.highlight = value
      break
    case 'authors':
      data.authors = [value]
      break
    case 'topics':
      data.topics = [value]
      break
    default:
      break
  }
}

function assignList(data: PostMeta, key: string, items: string[]) {
  switch (key) {
    case 'authors':
      data.authors = items
      break
    case 'topics':
      data.topics = items
      break
    default:
      break
  }
}

function unquote(value: string): string {
  const first = value[0]
  const last = value[value.length - 1]
  switch (first) {
    case "'":
    case '"':
      if (last === first) return value.slice(1, -1)
      return value
    default:
      return value
  }
}

export function firstHeading(content: string): string | undefined {
  const m = content.match(HEADING)
  return m?.[1]?.trim()
}

export function formatStripeDate(iso?: string, fallbackNs?: number): string {
  if (iso) {
    const d = new Date(iso)
    if (!Number.isNaN(d.getTime())) {
      return `${d.getUTCFullYear()}.${d.getUTCMonth() + 1}.${d.getUTCDate()}`
    }
  }
  if (fallbackNs) {
    const ms =
      fallbackNs > NS_TO_MS_THRESHOLD
        ? Math.floor(fallbackNs / NS_TO_MS)
        : fallbackNs
    const d = new Date(ms)
    if (!Number.isNaN(d.getTime())) {
      return `${d.getUTCFullYear()}.${d.getUTCMonth() + 1}.${d.getUTCDate()}`
    }
  }
  return '—'
}

export function readingTimeMinutes(content: string): number {
  const words = content.trim().split(/\s+/).filter(Boolean).length
  return Math.max(1, Math.round(words / WORDS_PER_MINUTE))
}

export function rewriteStripeImages(content: string): string {
  return content.replace(STRIPE_IMAGE_PREFIX, `$1${STRIPE_IMAGE_CDN}`)
}

/** Fix GitHub blob/HTML page URLs so <img> and markdown images can load. */
export function rewriteGithubBlobUrls(content: string): string {
  return content
    .replace(GITHUB_BLOB, GITHUB_RAW_CDN)
    .replace(GITHUB_RAW, GITHUB_RAW_CDN)
}

function unwrapDest(dest: string): string {
  if (dest.startsWith('<') && dest.endsWith('>')) return dest.slice(1, -1)
  return dest
}

function isQuotedMarkdownTitle(rest: string): boolean {
  const t = rest.trim()
  if (t.length === 0) return true
  const open = t[0]
  const close = open === '(' ? ')' : open
  if (open !== '"' && open !== "'" && open !== '(') return false
  return t.endsWith(close) && t.length >= 2
}

function escapeHtmlAttr(value: string): string {
  return value
    .replaceAll('&', '&amp;')
    .replaceAll('"', '&quot;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
}

/** Turn `![](url align="center")` into an `<img>` CommonMark can render. */
export function rewriteExtendedMarkdownImages(content: string): string {
  return content.replace(
    ATTR_MARKDOWN_IMAGE,
    (match, alt: string, dest: string, rest: string) => {
      if (isQuotedMarkdownTitle(rest)) return match
      const url = unwrapDest(dest)
      const align = /\balign\s*=\s*["']?(\w+)/i.exec(rest)?.[1]?.toLowerCase()
      const centered = align === 'center' ? ' class="md-img-center"' : ''
      return `<img src="${escapeHtmlAttr(url)}" alt="${escapeHtmlAttr(alt)}"${centered} />`
    },
  )
}

const GIST_SCRIPT_TAG =
  /<script\b(?=[^>]*\bsrc=["'](https:\/\/gist\.github\.com\/[\w.-]+\/[a-fA-F0-9]+(?:\.js)?(?:\?[^"'>\s]*)?)["'])[^>]*>\s*<\/script>/gi

function gistPibbUrl(src: string): string {
  if (src.includes('.pibb')) return src
  if (/\.js(?=\?|$)/i.test(src)) return src.replace(/\.js(?=\?|$)/i, '.pibb')
  return `${src}.pibb`
}

/** Hashnode-style gist embeds: `<script src="https://gist.github.com/…/….js">`. */
export function rewriteGistScripts(content: string): string {
  return content.replace(GIST_SCRIPT_TAG, (_, src: string) => {
    const url = gistPibbUrl(src)
    return `<iframe src="${escapeHtmlAttr(url)}" title="GitHub Gist" class="gist-embed" loading="lazy"></iframe>`
  })
}

export function rewriteContentImages(content: string): string {
  return rewriteGistScripts(
    rewriteExtendedMarkdownImages(
      rewriteGithubBlobUrls(rewriteStripeImages(content)),
    ),
  )
}

const MARKDOWN_IMAGE_SRC =
  /^!\[([^\]]*)\]\(\s*(<[^>]+>|https?:\/\/[^\s)]+|[^\s)]+)/
const VIDEO_TAG = /^<video\b([^>]*)>[\s\S]*$/i
const ATTR_QUOTED = (name: string) =>
  new RegExp(`\\b(?:data-)?${name}\\s*=\\s*['"]([^'"]*)['"]`, 'i')
const ATTR_BARE = (name: string) =>
  new RegExp(`\\b(?:data-)?${name}(?![\\w-])(?!\\s*=)`, 'i')

function rewriteCoverSrc(src: string): string {
  if (src.startsWith('/images/')) {
    return `${STRIPE_IMAGE_CDN}${src.slice('/images/'.length)}`
  }
  return rewriteGithubBlobUrls(src)
}

function attrValue(attrs: string, name: string): string | undefined {
  return ATTR_QUOTED(name).exec(attrs)?.[1]
}

function attrFlag(attrs: string, name: string): boolean {
  const quoted = attrValue(attrs, name)?.toLowerCase()
  if (quoted != null) return quoted !== 'false' && quoted !== '0'
  return ATTR_BARE(name).test(attrs)
}

function parseCoverVideo(value: string): CoverMedia | undefined {
  const match = value.match(VIDEO_TAG)
  if (!match) return undefined
  const attrs = match[1] ?? ''
  const raw = attrValue(attrs, 'src')
  if (!raw) return undefined
  return {
    kind: 'video',
    src: rewriteCoverSrc(raw),
    autoplay: attrFlag(attrs, 'autoplay'),
    loop: attrFlag(attrs, 'loop'),
    muted: attrFlag(attrs, 'muted'),
    playsInline: attrFlag(attrs, 'playsinline'),
  }
}

/** Pull a usable `src` from a plain URL or `![alt](url …)` frontmatter value. */
export function coverImageUrl(value?: string): string | undefined {
  if (!value) return undefined
  const trimmed = value.trim()
  if (!trimmed || trimmed.startsWith('<')) return undefined

  const md = trimmed.match(MARKDOWN_IMAGE_SRC)
  const src = md ? unwrapDest(md[2]) : trimmed
  if (!src) return undefined
  return rewriteCoverSrc(src)
}

/** Cover from a URL, markdown image, or HTML `<video>` tag. */
export function coverMedia(value?: string): CoverMedia | undefined {
  if (!value) return undefined
  const trimmed = value.trim()
  if (!trimmed) return undefined
  const video = parseCoverVideo(trimmed)
  if (video) return video
  const src = coverImageUrl(trimmed)
  if (!src) return undefined
  return { kind: 'image', src }
}

export function categoriesFromPath(path: string): string[] {
  const parts = path.split('/').slice(0, -1)
  return parts.map((p) => p.replace(/[-_]/g, ' ').toUpperCase())
}
