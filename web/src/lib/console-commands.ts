import { isThemeName, THEME_NAMES } from '@/lib/highlight'
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
  '  theme list        List themes / highlight colors',
  '  theme set <name>  Set theme (light|alt|paper|amber|mint|violet|coral|sky)',
  '  music list        List background tracks',
  '  music play [name] Play ambient music (default: ambient)',
  '  music pause|resume|stop',
  '  music volume <0-100>',
  '  music status',
  '  clear             Clear scrollback',
  '  close             Close the console',
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
          return { lines: [ctx.listThemes()] }
        case 'set': {
          const name = rest[1]
          if (!name) return { lines: ['Usage: theme set <name>'] }
          if (!isThemeName(name.toLowerCase())) {
            return {
              lines: [
                `Error: unknown theme "${name}"`,
                `Themes: ${THEME_NAMES.join(', ')}`,
              ],
            }
          }
          return { lines: [ctx.setTheme(name.toLowerCase())] }
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
