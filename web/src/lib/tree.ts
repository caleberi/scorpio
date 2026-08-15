import type { BlogListing } from './api'

export type TreeNode =
  | { kind: 'dir'; name: string; path: string; children: TreeNode[] }
  | { kind: 'file'; name: string; path: string; slug: string; doc: BlogListing }

export function buildTree(docs: BlogListing[]): TreeNode[] {
  const root: TreeNode[] = []

  for (const doc of docs) {
    const parts = doc.path.replace(/\.md$/i, '').split('/').filter(Boolean)
    let level = root
    let acc = ''

    parts.forEach((part, index) => {
      acc = acc ? `${acc}/${part}` : part
      const isFile = index === parts.length - 1

      if (isFile) {
        level.push({
          kind: 'file',
          name: `${part}.md`,
          path: doc.path,
          slug: doc.slug,
          doc,
        })
        return
      }

      let dir = level.find(
        (n): n is Extract<TreeNode, { kind: 'dir' }> =>
          n.kind === 'dir' && n.name === part,
      )
      if (!dir) {
        dir = { kind: 'dir', name: part, path: acc, children: [] }
        level.push(dir)
      }
      level = dir.children
    })
  }

  sortNodes(root)
  return root
}

function sortNodes(nodes: TreeNode[]) {
  nodes.sort((a, b) => {
    if (a.kind !== b.kind) return a.kind === 'dir' ? -1 : 1
    return a.name.localeCompare(b.name)
  })
  for (const n of nodes) {
    switch (n.kind) {
      case 'dir':
        sortNodes(n.children)
        break
      case 'file':
        break
    }
  }
}
