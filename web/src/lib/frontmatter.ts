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
  /** Highlight name (lime, amber, …) or hex color for the title mark */
  highlight?: string
}

export type ParsedPost = {
  data: PostMeta
  content: string
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

export function rewriteContentImages(content: string): string {
  return rewriteGithubBlobUrls(rewriteStripeImages(content))
}

export function categoriesFromPath(path: string): string[] {
  const parts = path.split('/').slice(0, -1)
  return parts.map((p) => p.replace(/[-_]/g, ' ').toUpperCase())
}
