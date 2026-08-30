import {
  Outlet,
  createRootRoute,
  useNavigate,
} from '@tanstack/react-router'
import { useEffect } from 'react'
import { Nav } from '@/components/Nav'
import { Footer } from '@/components/Footer'
import { Console } from '@/components/Console'
import { usePerfTracker } from '@/hooks/usePerfTracker'
import { AppProvider, useApp } from '@/lib/app-context'
import { KEYBOARD_SHORTCUTS } from '@/lib/constants'

export const Route = createRootRoute({
  component: RootComponent,
})

function RootComponent() {
  return (
    <AppProvider>
      <Shell />
    </AppProvider>
  )
}

function Shell() {
  const { toggleConsole } = useApp()
  const navigate = useNavigate()
  usePerfTracker()

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const target = e.target as HTMLElement | null
      const tag = target?.tagName
      switch (tag) {
        case 'INPUT':
        case 'TEXTAREA':
          return
        default:
          if (target?.isContentEditable) return
      }

      switch (e.key.toLowerCase()) {
        case KEYBOARD_SHORTCUTS.blog:
          e.preventDefault()
          void navigate({ to: '/' })
          break
        case KEYBOARD_SHORTCUTS.console:
          e.preventDefault()
          toggleConsole()
          break
        default:
          break
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [navigate, toggleConsole])

  return (
    <div className="flex min-h-screen flex-col">
      <Nav />
      <div className="mx-auto flex w-full max-w-[1400px] flex-1 flex-col">
        <Outlet />
      </div>
      <Footer />
      <Console />
    </div>
  )
}
