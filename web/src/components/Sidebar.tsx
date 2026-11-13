import { useMemo, useState } from 'react'
import { Link, useRouterState } from '@tanstack/react-router'
import { ChevronRight, FileText, Folder } from 'lucide-react'
import { LocaleSelect } from '@/components/LocaleSelect'
import { useSidebarWidth } from '@/hooks/useSidebarWidth'
import { useApp } from '@/lib/app-context'
import { SIDEBAR_DEFAULT, SIDEBAR_MIN, TREE_INDENT_PX } from '@/lib/constants'
import { buildTree, type TreeNode } from '@/lib/tree'
import { cn } from '@/lib/utils'

export function Sidebar({
  className,
  kind = 'blog',
}: {
  className?: string
  kind?: 'blog' | 'slides'
}) {
  const {
    documents,
    documentsLoading,
    documentsError,
    presentations,
    presentationsLoading,
    presentationsError,
    t,
  } = useApp()
  const listings = kind === 'slides' ? presentations : documents
  const loading = kind === 'slides' ? presentationsLoading : documentsLoading
  const error = kind === 'slides' ? presentationsError : documentsError
  const tree = useMemo(() => buildTree(listings), [listings])
  const pathname = useRouterState({ select: (s) => s.location.pathname })
  const label = kind === 'slides' ? t.sidebar.slides : t.sidebar.pagesBlog
  const linkPrefix = kind === 'slides' ? '/presentations/' : '/posts/'
  const resize = useSidebarWidth()

  return (
    <aside
      className={cn(
        'sidebar-pane relative hidden min-w-0 shrink-0 self-stretch border-r border-ink/25 bg-ground md:flex md:flex-col',
        className,
      )}
    >
      <div className="sticky top-0 flex max-h-[calc(100vh-3rem)] min-w-0 flex-col">
        <div className="min-h-0 min-w-0 flex-1 overflow-x-hidden overflow-y-auto p-3">
          <div className="section-label mb-3">{label}</div>
          {loading && (
            <p className="font-mono text-sm text-muted">{t.sidebar.loading}</p>
          )}
          {error && (
            <p className="font-mono text-sm text-red-700">{error}</p>
          )}
          {!loading && !error && (
            <ul className="min-w-0 space-y-0.5 font-mono text-[15px]">
              {tree.map((node) => (
                <TreeItem
                  key={node.path}
                  node={node}
                  activePath={pathname}
                  linkPrefix={linkPrefix}
                />
              ))}
            </ul>
          )}
        </div>

        <LocaleSelect className="border-t border-ink/20 p-3" />
      </div>
      <div
        ref={resize.handleRef}
        role="separator"
        aria-orientation="vertical"
        aria-label={t.sidebar.resize}
        aria-valuemin={SIDEBAR_MIN}
        aria-valuenow={SIDEBAR_DEFAULT}
        tabIndex={0}
        className="sidebar-resize"
        onPointerDown={resize.onPointerDown}
        onPointerMove={resize.onPointerMove}
        onPointerUp={resize.onPointerUp}
        onPointerCancel={resize.onPointerCancel}
        onKeyDown={resize.onKeyDown}
        onDoubleClick={resize.onDoubleClick}
      />
    </aside>
  )
}

function TreeItem({
  node,
  activePath,
  linkPrefix,
  depth = 0,
}: {
  node: TreeNode
  activePath: string
  linkPrefix: string
  depth?: number
}) {
  const [open, setOpen] = useState(true)
  const indent = { paddingLeft: `${depth * TREE_INDENT_PX + 4}px` }

  switch (node.kind) {
    case 'dir':
      return (
        <li>
          <button
            type="button"
            className="flex w-full min-w-0 items-center gap-1 rounded px-1 py-0.5 text-left hover:bg-ink/[0.06]"
            style={indent}
            onClick={() => setOpen((v) => !v)}
          >
            <ChevronRight
              className={cn('h-3 w-3 shrink-0 transition-transform', open && 'rotate-90')}
            />
            <Folder className="h-3.5 w-3.5 shrink-0" />
            <span className="min-w-0 flex-1 truncate" title={node.name}>
              {node.name}
            </span>
          </button>
          {open && (
            <ul>
              {node.children.map((child) => (
                <TreeItem
                  key={child.path}
                  node={child}
                  activePath={activePath}
                  linkPrefix={linkPrefix}
                  depth={depth + 1}
                />
              ))}
            </ul>
          )}
        </li>
      )
    case 'file': {
      const href = `${linkPrefix}${node.slug}`
      const active = activePath === href || activePath.startsWith(`${href}/`)
      const to = linkPrefix.startsWith('/presentations')
        ? '/presentations/$'
        : '/posts/$'
      return (
        <li>
          <Link
            to={to}
            params={{ _splat: node.slug }}
            className={cn(
              'flex min-w-0 items-center gap-1.5 rounded px-1 py-0.5 hover:bg-ink/[0.06]',
              active && 'bg-accent/40',
            )}
            style={indent}
          >
            <FileText className="h-3.5 w-3.5 shrink-0" />
            <span className="min-w-0 flex-1 truncate" title={node.name}>
              {node.name}
            </span>
          </Link>
        </li>
      )
    }
  }
}
