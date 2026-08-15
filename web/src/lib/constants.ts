import { THEME_NAMES } from '@/lib/highlight'

export const STORAGE_KEYS = {
  consoleState: 'scorpio.consoleState',
  theme: 'scorpio.theme',
  locale: 'scorpio.locale',
  commentAuthor: 'scorpio.comment.author',
} as const

export const DEFAULT_THEME = 'light'
export const DEFAULT_CONSOLE_STATE = 'open' as const

export const THEME_CLASS_NAMES = THEME_NAMES.map((name) => `theme-${name}`)

export const TREE_INDENT_PX = 12

export const WORDS_PER_MINUTE = 220
export const EXCERPT_MAX_CHARS = 160
export const RELATED_ARTICLE_COUNT = 2

export const NS_TO_MS_THRESHOLD = 1e12
export const NS_TO_MS = 1e6

export const BLOG_PREFIX = 'blog/'
export const POSTS_PREFIX = '/posts/'
export const API_BLOG = '/blog'
export const JSON_HEADERS = { 'Content-Type': 'application/json' } as const

export const SHARE_NETWORKS = ['x', 'linkedin'] as const
export type ShareNetwork = (typeof SHARE_NETWORKS)[number]

export const KEYBOARD_SHORTCUTS = {
  blog: 'b',
  console: 'c',
} as const
