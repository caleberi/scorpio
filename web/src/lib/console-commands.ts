import {
  formatThemeList,
  isThemeName,
  normalizeThemeName,
  THEME_NAMES,
} from '@/lib/highlight'
import { musicPlayer, TRACKS } from '@/lib/music'

export type ConsoleContext = {
  listPaths: () => string[]
  openPath: (target: string) => string
  setTheme: (name: string) => string
  listThemes: () => string
  close: () => void
}

export type ConsoleResult = {
  lines: string[]
  clear?: boolean
  close?: boolean
}

const HELP_LINES = [
  'Subcommands',
  '  help              Show this help',
  '  ls                List packed blog paths',
  '  open <slug|path>  Open a post',
  '  theme list        List light and dark themes',
  '  theme set <name>  Set theme (light, dark, dark mint, …)',
  '  music list        List background tracks',
  '  music play [name] Play ambient music (default: ambient)',
  '  music pause|resume|stop',
  '  music volume <0-100>',
  '  music status',
  '  clear             Clear scrollback',
  '  close             Close the console',
  'Keys',
  '  ↑ / ↓             History and matching completions',
  '  → / tab           Accept ghost completion',
]

export function runConsoleCommand(
  input: string,
  ctx: ConsoleContext,
): ConsoleResult | Promise<ConsoleResult> {
  const trimmed = input.trim()
  if (!trimmed) return { lines: [] }

  const [cmd, ...rest] = trimmed.split(/\s+/)

  switch (cmd.toLowerCase()) {
    case 'help':
      return { lines: HELP_LINES }
    case 'ls': {
      const paths = ctx.listPaths()
      return {
        lines: paths.length ? paths : ['(no documents)'],
      }
    }
    case 'open': {
      const arg = rest.join(' ').trim()
      if (!arg) return { lines: ['Usage: open <slug|path>'] }
      return { lines: [ctx.openPath(arg)] }
    }
    case 'theme': {
      switch (rest[0]) {
        case 'list':
          return { lines: ctx.listThemes().split('\n') }
        case 'set': {
          const name = normalizeThemeName(rest.slice(1).join(' '))
          if (!name) return { lines: ['Usage: theme set <name>'] }
          if (!isThemeName(name)) {
            return {
              lines: [
                `Error: unknown theme "${rest.slice(1).join(' ')}"`,
                ...formatThemeList(),
              ],
            }
          }
          return { lines: [ctx.setTheme(name)] }
        }
        default:
          return { lines: ['Usage: theme list | theme set <name>'] }
      }
    }
    case 'music':
      return handleMusic(rest)
    case 'clear':
      return { lines: [], clear: true }
    case 'close':
      return { lines: ['Bye!'], close: true }
    default:
      return { lines: [`Error: Bad command "${cmd}"`] }
  }
}

async function handleMusic(rest: string[]): Promise<ConsoleResult> {
  const sub = (rest[0] ?? '').toLowerCase()
  switch (sub) {
    case 'list':
      return {
        lines: ['Tracks', ...TRACKS.map((t) => `  ${t.id.padEnd(8)} ${t.description}`)],
      }
    case 'play':
      return { lines: [await musicPlayer.play(rest[1])] }
    case 'pause':
      return { lines: [musicPlayer.pause()] }
    case 'resume':
      return { lines: [musicPlayer.resume()] }
    case 'stop':
      return { lines: [musicPlayer.stop()] }
    case 'volume':
      return { lines: [musicPlayer.setVolume(rest[1] ?? '')] }
    case 'status':
    case '':
      return { lines: [musicPlayer.status()] }
    default:
      return {
        lines: [
          `Error: unknown music command "${sub}"`,
          'Usage: music list|play|pause|resume|stop|volume|status',
        ],
      }
  }
}

export function initialHelp(): string[] {
  return HELP_LINES
}

const STATIC_COMMANDS = [
  'help',
  'ls',
  'open',
  'theme',
  'theme list',
  'theme set',
  ...THEME_NAMES.map((name) => `theme set ${name}`),
  'music',
  'music list',
  'music play',
  ...TRACKS.map((track) => `music play ${track.id}`),
  'music pause',
  'music resume',
  'music stop',
  'music volume',
  'music status',
  'clear',
  'close',
]

function consoleCatalog(openTargets: string[]): string[] {
  return [
    ...STATIC_COMMANDS,
    ...openTargets.map((target) => `open ${target}`),
  ]
}

/** Newest matching history first, then unused catalog completions. */
export function consoleNavItems(
  prefix: string,
  history: string[],
  openTargets: string[],
): string[] {
  const lower = prefix.toLowerCase()
  const seen = new Set<string>()
  const items: string[] = []

  const push = (value: string) => {
    const key = value.toLowerCase()
    if (seen.has(key)) return
    if (prefix && !key.startsWith(lower)) return
    seen.add(key)
    items.push(value)
  }

  for (let i = history.length - 1; i >= 0; i--) {
    push(history[i])
  }

  if (prefix) {
    for (const command of consoleCatalog(openTargets)) {
      push(command)
    }
  }

  return items
}

export function consoleSuggestion(
  input: string,
  history: string[],
  openTargets: string[],
): string | null {
  if (!input) return null
  return (
    consoleNavItems(input, history, openTargets).find(
      (item) => item.length > input.length,
    ) ?? null
  )
}

export function suggestionRemainder(
  input: string,
  suggestion: string | null,
): string {
  if (!suggestion) return ''
  if (suggestion.length <= input.length) return ''
  if (!suggestion.toLowerCase().startsWith(input.toLowerCase())) return ''
  return suggestion.slice(input.length)
}
