import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from 'react'
import {
  DEFAULT_LOCALE,
  MESSAGES,
  isLocale,
  type Locale,
  type Messages,
} from '@/i18n'
import { listDocuments, type BlogListing } from '@/lib/api'
import {
  DEFAULT_CONSOLE_STATE,
  DEFAULT_THEME,
  STORAGE_KEYS,
  THEME_CLASS_NAMES,
} from '@/lib/constants'
import { errorMessage } from '@/lib/errors'

type ConsoleState = 'open' | 'minimized' | 'closed'

type AppContextValue = {
  documents: BlogListing[]
  documentsLoading: boolean
  documentsError: string | null
  refreshDocuments: () => Promise<void>
  consoleState: ConsoleState
  setConsoleState: (s: ConsoleState) => void
  toggleConsole: () => void
  theme: string
  setTheme: (name: string) => void
  locale: Locale
  setLocale: (locale: Locale) => void
  t: Messages
}

const AppContext = createContext<AppContextValue | null>(null)

function readStoredConsole(): ConsoleState {
  const v = localStorage.getItem(STORAGE_KEYS.consoleState)
  switch (v) {
    case 'open':
    case 'minimized':
    case 'closed':
      return v
    default:
      return DEFAULT_CONSOLE_STATE
  }
}

function readStoredTheme(): string {
  return localStorage.getItem(STORAGE_KEYS.theme) ?? DEFAULT_THEME
}

function readStoredLocale(): Locale {
  const v = localStorage.getItem(STORAGE_KEYS.locale)
  return v && isLocale(v) ? v : DEFAULT_LOCALE
}

export function AppProvider({ children }: { children: ReactNode }) {
  const [documents, setDocuments] = useState<BlogListing[]>([])
  const [documentsLoading, setDocumentsLoading] = useState(true)
  const [documentsError, setDocumentsError] = useState<string | null>(null)
  const [consoleState, setConsoleStateRaw] = useState<ConsoleState>(() =>
    typeof window === 'undefined' ? DEFAULT_CONSOLE_STATE : readStoredConsole(),
  )
  const [theme, setThemeRaw] = useState(() =>
    typeof window === 'undefined' ? DEFAULT_THEME : readStoredTheme(),
  )
  const [locale, setLocaleRaw] = useState<Locale>(() =>
    typeof window === 'undefined' ? DEFAULT_LOCALE : readStoredLocale(),
  )

  const t = MESSAGES[locale]

  const setConsoleState = useCallback((s: ConsoleState) => {
    setConsoleStateRaw(s)
    localStorage.setItem(STORAGE_KEYS.consoleState, s)
  }, [])

  const toggleConsole = useCallback(() => {
    setConsoleStateRaw((prev) => {
      const next = prev === 'open' ? 'closed' : 'open'
      localStorage.setItem(STORAGE_KEYS.consoleState, next)
      return next
    })
  }, [])

  const setTheme = useCallback((name: string) => {
    setThemeRaw(name)
    localStorage.setItem(STORAGE_KEYS.theme, name)
  }, [])

  const setLocale = useCallback((next: Locale) => {
    setLocaleRaw(next)
    localStorage.setItem(STORAGE_KEYS.locale, next)
  }, [])

  const refreshDocuments = useCallback(async () => {
    setDocumentsLoading(true)
    setDocumentsError(null)
    const docs = await listDocuments().catch((err: unknown) => {
      setDocumentsError(errorMessage(err, MESSAGES.en.common.failedToLoad))
      return null
    })
    if (docs) setDocuments(docs)
    setDocumentsLoading(false)
  }, [])

  useEffect(() => {
    void refreshDocuments()
  }, [refreshDocuments])

  useEffect(() => {
    const root = document.documentElement
    for (const name of THEME_CLASS_NAMES) {
      root.classList.remove(name)
    }
    root.classList.add(`theme-${theme}`)
  }, [theme])

  useEffect(() => {
    document.documentElement.lang = locale
  }, [locale])

  const value = useMemo(
    () => ({
      documents,
      documentsLoading,
      documentsError,
      refreshDocuments,
      consoleState,
      setConsoleState,
      toggleConsole,
      theme,
      setTheme,
      locale,
      setLocale,
      t,
    }),
    [
      documents,
      documentsLoading,
      documentsError,
      refreshDocuments,
      consoleState,
      setConsoleState,
      toggleConsole,
      theme,
      setTheme,
      locale,
      setLocale,
      t,
    ],
  )

  return <AppContext.Provider value={value}>{children}</AppContext.Provider>
}

export function useApp() {
  const ctx = useContext(AppContext)
  if (!ctx) throw new Error('useApp must be used within AppProvider')
  return ctx
}
