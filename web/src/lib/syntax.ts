import {
  createHighlighter,
  type BundledLanguage,
  type BundledTheme,
  type Highlighter,
} from 'shiki'
import { isThemeName, type ThemeName } from '@/lib/highlight'

const LANGS = [
  'c',
  'cpp',
  'zig',
  'bash',
  'shellscript',
  'javascript',
  'typescript',
  'tsx',
  'jsx',
  'json',
  'markdown',
  'sql',
  'python',
  'go',
  'rust',
  'yaml',
  'html',
  'css',
  'toml',
  'diff',
  'xml',
  'java',
] as const satisfies readonly BundledLanguage[]

const LANG_ALIASES: Record<string, BundledLanguage> = {
  js: 'javascript',
  ts: 'typescript',
  sh: 'bash',
  shell: 'bash',
  zsh: 'bash',
  py: 'python',
  rs: 'rust',
  yml: 'yaml',
  md: 'markdown',
  'c++': 'cpp',
  h: 'c',
}

/** App paper themes → Shiki palettes. */
export const THEME_SYNTAX: Record<ThemeName, BundledTheme> = {
  light: 'ayu-light',
  alt: 'one-light',
  paper: 'rose-pine-dawn',
  amber: 'solarized-light',
  mint: 'everforest-light',
  violet: 'catppuccin-latte',
  coral: 'snazzy-light',
  sky: 'github-light',
  dark: 'ayu-dark',
  'dark-alt': 'rose-pine',
  'dark-paper': 'kanagawa-dragon',
  'dark-amber': 'solarized-dark',
  'dark-mint': 'everforest-dark',
  'dark-violet': 'catppuccin-mocha',
  'dark-coral': 'dracula',
  'dark-sky': 'github-dark',
}

const DEFAULT_SYNTAX: BundledTheme = 'ayu-light'

const SYNTAX_THEMES = [
  ...new Set(Object.values(THEME_SYNTAX)),
] as BundledTheme[]

let highlighter: Highlighter | null = null
let loading: Promise<Highlighter> | null = null

function getHighlighter(): Promise<Highlighter> {
  if (highlighter) return Promise.resolve(highlighter)
  if (!loading) {
    loading = createHighlighter({
      langs: [...LANGS],
      themes: SYNTAX_THEMES,
    }).then((hl) => {
      highlighter = hl
      return hl
    })
  }
  return loading
}

function syntaxTheme(appTheme?: string): BundledTheme {
  if (appTheme && isThemeName(appTheme)) return THEME_SYNTAX[appTheme]
  return DEFAULT_SYNTAX
}

function resolveLang(lang?: string): BundledLanguage | 'text' {
  if (!lang) return 'text'
  const key = lang.toLowerCase()
  return LANG_ALIASES[key] ?? (key as BundledLanguage)
}

export async function highlightCode(
  code: string,
  lang?: string,
  appTheme?: string,
): Promise<string> {
  const hl = await getHighlighter()
  const resolved = resolveLang(lang)
  const loaded = hl.getLoadedLanguages()
  if (resolved !== 'text' && !loaded.includes(resolved)) {
    await hl.loadLanguage(resolved).catch(() => undefined)
  }
  const langId = hl.getLoadedLanguages().includes(resolved) ? resolved : 'text'
  const theme = syntaxTheme(appTheme)
  if (!hl.getLoadedThemes().includes(theme)) {
    await hl.loadTheme(theme).catch(() => undefined)
  }
  return hl.codeToHtml(code, {
    lang: langId,
    theme: hl.getLoadedThemes().includes(theme) ? theme : DEFAULT_SYNTAX,
  })
}
