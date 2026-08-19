import { useEffect, useRef, useState, type ReactNode } from 'react'
import { cn } from '@/lib/utils'

type LangIcon = {
  id: string
  label: string
  left: string
  top: string
  size: string
  duration: string
  delay: string
  enterDelay: string
  icon: ReactNode
}

const ICONS: LangIcon[] = [
  {
    id: 'js',
    label: 'JavaScript',
    left: '5%',
    top: '14%',
    size: '4.6rem',
    duration: '19s',
    delay: '0s',
    enterDelay: '0ms',
    icon: (
      <svg viewBox="0 0 16 16" aria-hidden>
        <path
          fill="#ffca28"
          d="M2 2v12h12V2zm6 6h1v4a1.003 1.003 0 0 1-1 1H7a1.003 1.003 0 0 1-1-1v-1h1v1h1zm3 0h2v1h-2v1h1a1.003 1.003 0 0 1 1 1v1a1.003 1.003 0 0 1-1 1h-2v-1h2v-1h-1a1.003 1.003 0 0 1-1-1V9a1.003 1.003 0 0 1 1-1"
        />
      </svg>
    ),
  },
  {
    id: 'zig',
    label: 'Zig',
    left: '21%',
    top: '62%',
    size: '5.4rem',
    duration: '22s',
    delay: '-4s',
    enterDelay: '90ms',
    icon: (
      <svg viewBox="0 0 32 32" aria-hidden>
        <path
          fill="#f9a825"
          d="M2 8h6v4H2zm8 0h12v4H10zm0 12h12v4H10zm14 0h2v4h-2zM8 20l-3 4H2V12h4v8zm14-8h-6l-6 8h6z"
        />
        <path
          fill="#f9a825"
          d="M16 20h-6l-6 8m12-16h6l6-8m2 4v16h-4V12h-2l3-4z"
        />
      </svg>
    ),
  },
  {
    id: 'c',
    label: 'C',
    left: '37%',
    top: '22%',
    size: '4.2rem',
    duration: '17s',
    delay: '-8s',
    enterDelay: '160ms',
    icon: (
      <svg viewBox="0 0 32 32" aria-hidden>
        <path
          fill="#0288d1"
          d="M19.563 22A5.57 5.57 0 0 1 14 16.437v-2.873A5.57 5.57 0 0 1 19.563 8H24V2h-4.437A11.563 11.563 0 0 0 8 13.563v2.873A11.564 11.564 0 0 0 19.563 28H24v-6Z"
        />
      </svg>
    ),
  },
  {
    id: 'python',
    label: 'Python',
    left: '52%',
    top: '68%',
    size: '5.7rem',
    duration: '21s',
    delay: '-2s',
    enterDelay: '220ms',
    icon: (
      <svg viewBox="0 0 24 24" aria-hidden>
        <path
          fill="#0288d1"
          d="M9.86 2A2.86 2.86 0 0 0 7 4.86v1.68h4.29c.39 0 .71.57.71.96H4.86A2.86 2.86 0 0 0 2 10.36v3.781a2.86 2.86 0 0 0 2.86 2.86h1.18v-2.68a2.85 2.85 0 0 1 2.85-2.86h5.25c1.58 0 2.86-1.271 2.86-2.851V4.86A2.86 2.86 0 0 0 14.14 2zm-.72 1.61c.4 0 .72.12.72.71s-.32.891-.72.891c-.39 0-.71-.3-.71-.89s.32-.711.71-.711"
        />
        <path
          fill="#fdd835"
          d="M17.959 7v2.68a2.85 2.85 0 0 1-2.85 2.859H9.86A2.85 2.85 0 0 0 7 15.389v3.75a2.86 2.86 0 0 0 2.86 2.86h4.28A2.86 2.86 0 0 0 17 19.14v-1.68h-4.291c-.39 0-.709-.57-.709-.96h7.14A2.86 2.86 0 0 0 22 13.64V9.86A2.86 2.86 0 0 0 19.14 7zM8.32 11.513l-.004.004.038-.004zm6.54 7.276c.39 0 .71.3.71.89a.71.71 0 0 1-.71.71c-.4 0-.72-.12-.72-.71s.32-.89.72-.89"
        />
      </svg>
    ),
  },
  {
    id: 'ts',
    label: 'TypeScript',
    left: '68%',
    top: '18%',
    size: '4.6rem',
    duration: '20s',
    delay: '-11s',
    enterDelay: '280ms',
    icon: (
      <svg viewBox="0 0 16 16" aria-hidden>
        <path
          fill="#0288d1"
          d="M2 2v12h12V2zm4 6h3v1H8v4H7V9H6zm5 0h2v1h-2v1h1a1.003 1.003 0 0 1 1 1v1a1.003 1.003 0 0 1-1 1h-2v-1h2v-1h-1a1.003 1.003 0 0 1-1-1V9a1.003 1.003 0 0 1 1-1"
        />
      </svg>
    ),
  },
  {
    id: 'cpp',
    label: 'C++',
    left: '81%',
    top: '58%',
    size: '5rem',
    duration: '18s',
    delay: '-6s',
    enterDelay: '340ms',
    icon: (
      <svg viewBox="0 0 32 32" aria-hidden>
        <path
          fill="#0288d1"
          d="M28 14v-4h-2v4h-6v-4h-2v4h-4v2h4v4h2v-4h6v4h2v-4h4v-2z"
        />
        <path
          fill="#0288d1"
          d="M13.563 22A5.57 5.57 0 0 1 8 16.437v-2.873A5.57 5.57 0 0 1 13.563 8H18V2h-4.437A11.563 11.563 0 0 0 2 13.563v2.873A11.564 11.564 0 0 0 13.563 28H18v-6Z"
        />
      </svg>
    ),
  },
  {
    id: 'go',
    label: 'Go',
    left: '90%',
    top: '28%',
    size: '5.5rem',
    duration: '23s',
    delay: '-9s',
    enterDelay: '400ms',
    icon: (
      <svg viewBox="0 0 32 32" aria-hidden>
        <path
          fill="#00acc1"
          d="M2 12h4v2H2zm-2 4h6v2H0zm4 4h2v2H4zm16.954-5H14v3h3.239a4.42 4.42 0 0 1-3.531 2 2.65 2.65 0 0 1-2.053-.858 2.86 2.86 0 0 1-.628-2.28A4.515 4.515 0 0 1 15.292 13a2.73 2.73 0 0 1 1.749.584l2.962-1.185A5.6 5.6 0 0 0 15.292 10a7.526 7.526 0 0 0-7.243 6.5 5.614 5.614 0 0 0 5.659 6.5 7.526 7.526 0 0 0 7.243-6.5 6.4 6.4 0 0 0 .003-1.5"
        />
        <path
          fill="#00acc1"
          d="M26.292 10a7.526 7.526 0 0 0-7.243 6.5 5.614 5.614 0 0 0 5.659 6.5 7.526 7.526 0 0 0 7.243-6.5 5.614 5.614 0 0 0-5.659-6.5m2.681 6.137A4.515 4.515 0 0 1 24.708 20a2.65 2.65 0 0 1-2.053-.858 2.86 2.86 0 0 1-.628-2.28A4.515 4.515 0 0 1 26.292 13a2.65 2.65 0 0 1 2.053.858 2.86 2.86 0 0 1 .628 2.28Z"
        />
      </svg>
    ),
  },
]

export function LangIconField() {
  const ref = useRef<HTMLDivElement>(null)
  const [active, setActive] = useState(false)

  useEffect(() => {
    const node = ref.current
    if (!node) return

    const io = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) setActive(true)
      },
      { threshold: 0.18, rootMargin: '0px 0px -10% 0px' },
    )
    io.observe(node)
    return () => io.disconnect()
  }, [])

  return (
    <div
      ref={ref}
      className="lang-icon-field pointer-events-none absolute inset-0 overflow-hidden"
      aria-hidden
    >
      {ICONS.map((item) => (
        <div
          key={item.id}
          className={cn('lang-icon', active && 'is-visible')}
          style={{
            left: item.left,
            top: item.top,
            width: item.size,
            animationDelay: item.enterDelay,
          }}
        >
          <div
            className="lang-icon-drift"
            style={{
              animationDuration: item.duration,
              animationDelay: item.delay,
            }}
          >
            {item.icon}
          </div>
        </div>
      ))}
    </div>
  )
}
