import { API_BLOG, BLOG_PREFIX, JSON_HEADERS } from '@/lib/constants'
import { recordResponse } from '@/lib/perf'

export type BlogListing = {
  slug: string
  path: string
  modified_at: number
  length: number
}

export type BlogDocument = BlogListing & {
  content: string
  prefetch?: string[]
}

export type Reply = {
  id: string
  comment_id: string
  blog_id: string
  author: string
  body: string
  created_at: string
  updated_at: string
}

export type Comment = {
  id: string
  author: string
  body: string
  created_at: string
  updated_at: string
  replies: Reply[]
}

const PROFILE_SLUG = 'profile'
const BLOG_ROOT_SLUG = 'blog'

function encodeSlug(slug: string): string {
  return slug
    .split('/')
    .map((part) => encodeURIComponent(part))
    .join('/')
}

function blogUrl(slug?: string, ...rest: string[]): string {
  if (!slug) return API_BLOG
  const parts = [API_BLOG, encodeSlug(slug), ...rest.map(encodeURIComponent)]
  return parts.join('/')
}

/** Try common slug variants when pack paths use a blog/ prefix. */
function slugCandidates(slug: string): string[] {
  const trimmed = slug.replace(/^\/+|\/+$/g, '')
  const out = [trimmed]
  switch (trimmed) {
    case PROFILE_SLUG:
    case BLOG_ROOT_SLUG:
      break
    default:
      if (!trimmed.startsWith(BLOG_PREFIX)) out.push(`${BLOG_PREFIX}${trimmed}`)
  }
  if (trimmed.startsWith(BLOG_PREFIX)) {
    out.push(trimmed.slice(BLOG_PREFIX.length))
  }
  return [...new Set(out)]
}

async function readError(res: Response, fallback: string): Promise<string> {
  const data = (await res.json().catch(() => null)) as {
    error_message?: string
  } | null
  return data?.error_message || fallback
}

async function requestJson<T>(
  url: string,
  fallback: string,
  init?: RequestInit,
): Promise<{ ok: true; data: T } | { ok: false; message: string }> {
  const started = performance.now()
  const res = await fetch(url, init).finally(() => {
    recordResponse(performance.now() - started)
  })
  if (!res.ok) {
    return { ok: false, message: await readError(res, fallback) }
  }
  if (res.status === 204 || init?.method === 'DELETE') {
    return { ok: true, data: undefined as T }
  }
  const data = (await res.json().catch(() => null)) as T | null
  if (data == null) return { ok: false, message: fallback }
  return { ok: true, data }
}

async function firstOk<T>(
  slug: string,
  fallback: string,
  run: (candidate: string) => Promise<{ ok: true; data: T } | { ok: false; message: string }>,
): Promise<T> {
  let lastMessage = fallback
  for (const candidate of slugCandidates(slug)) {
    const result = await run(candidate)
    if (result.ok) return result.data
    lastMessage = result.message || lastMessage
  }
  throw new Error(lastMessage)
}

export async function listDocuments(): Promise<BlogListing[]> {
  const result = await requestJson<{ documents: BlogListing[] }>(
    API_BLOG,
    "We couldn't load the article list. Is the API running?",
  )
  if (!result.ok) throw new Error(result.message)
  return result.data.documents ?? []
}

export async function getDocument(slug: string): Promise<BlogDocument> {
  return firstOk(
    slug,
    "We couldn't find that post. It may have moved, or the link is incomplete.",
    (candidate) => requestJson<BlogDocument>(blogUrl(candidate), ''),
  )
}

export async function listComments(slug: string): Promise<Comment[]> {
  return firstOk(slug, "We couldn't load comments for this post.", async (candidate) => {
    const result = await requestJson<{ comments: Comment[] }>(
      blogUrl(candidate, 'comments'),
      '',
    )
    if (!result.ok) return result
    return { ok: true, data: result.data.comments ?? [] }
  })
}

export async function createComment(
  slug: string,
  input: { author: string; body: string },
): Promise<Comment> {
  return firstOk(
    slug,
    "We couldn't post your comment. Please try again.",
    async (candidate) => {
      const result = await requestJson<Comment>(
        blogUrl(candidate, 'comments'),
        '',
        {
          method: 'POST',
          headers: JSON_HEADERS,
          body: JSON.stringify(input),
        },
      )
      if (!result.ok) return result
      return { ok: true, data: { ...result.data, replies: result.data.replies ?? [] } }
    },
  )
}

export async function createReply(
  slug: string,
  commentId: string,
  input: { author: string; body: string },
): Promise<Reply> {
  return firstOk(slug, "We couldn't post your reply. Please try again.", (candidate) =>
    requestJson<Reply>(blogUrl(candidate, 'comments', commentId, 'replies'), '', {
      method: 'POST',
      headers: JSON_HEADERS,
      body: JSON.stringify(input),
    }),
  )
}

export async function deleteComment(slug: string, commentId: string): Promise<void> {
  return firstOk(slug, "We couldn't delete that comment.", (candidate) =>
    requestJson<void>(blogUrl(candidate, 'comments', commentId), '', {
      method: 'DELETE',
    }),
  )
}

export async function deleteReply(
  slug: string,
  commentId: string,
  replyId: string,
): Promise<void> {
  return firstOk(slug, "We couldn't delete that reply.", (candidate) =>
    requestJson<void>(
      blogUrl(candidate, 'comments', commentId, 'replies', replyId),
      '',
      { method: 'DELETE' },
    ),
  )
}
