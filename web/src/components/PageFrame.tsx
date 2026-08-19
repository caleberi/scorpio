import type { ReactNode } from 'react'
import { Sidebar } from '@/components/Sidebar'
import { cn } from '@/lib/utils'

export function PageFrame({
  hero,
  sidebar = true,
  children,
}: {
  hero?: ReactNode
  sidebar?: boolean
  children: ReactNode
}) {
  return (
    <div className="flex flex-1 flex-col">
      {hero}
      <div className="flex flex-1">
        {sidebar ? <Sidebar /> : null}
        <div
          className={cn(
            'min-w-0 flex-1 px-4 md:px-8',
            hero ? 'pb-8 pt-8' : 'py-8',
          )}
        >
          {children}
        </div>
      </div>
    </div>
  )
}
