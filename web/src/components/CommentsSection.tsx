import { useCallback, useEffect, useState, type FormEvent, type ReactNode } from 'react'
import { Button } from '@/components/ui/button'
import {
  createComment,
  createReply,
  deleteComment,
  deleteReply,
  listComments,
  type Comment,
} from '@/lib/api'
import { useApp } from '@/lib/app-context'
import { STORAGE_KEYS } from '@/lib/constants'
import { errorMessage } from '@/lib/errors'
import { cn } from '@/lib/utils'
import type { Locale, Messages } from '@/i18n'

function formatWhen(iso: string, locale: Locale): string {
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return iso
  return d.toLocaleString(locale, {
    year: 'numeric',
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  })
}

function CommentForm({
  t,
  submitLabel,
  pending,
  onSubmit,
  onCancel,
  compact,
}: {
  t: Messages
  submitLabel: string
  pending: boolean
  onSubmit: (author: string, body: string) => Promise<void>
  onCancel?: () => void
  compact?: boolean
}) {
  const [author, setAuthor] = useState(
    () => localStorage.getItem(STORAGE_KEYS.commentAuthor) ?? '',
  )
  const [body, setBody] = useState('')
  const [error, setError] = useState<string | null>(null)

  const handleSubmit = async (e: FormEvent) => {
    e.preventDefault()
    const a = author.trim()
    const b = body.trim()
    if (!a || !b) {
      setError(t.comments.required)
      return
    }
    setError(null)
    localStorage.setItem(STORAGE_KEYS.commentAuthor, a)
    let ok = true
    await onSubmit(a, b).catch((err: unknown) => {
      setError(errorMessage(err, t.comments.requestFailed))
      ok = false
    })
    if (ok) setBody('')
  }

  return (
    <form
      onSubmit={(e) => void handleSubmit(e)}
      className={cn('space-y-3', compact && 'mt-3 border-l border-ink/20 pl-4')}
    >
      <div className={cn('grid gap-3', !compact && 'sm:grid-cols-2')}>
        <label className="block">
          <span className="section-label mb-1 block">{t.comments.name}</span>
          <input
            value={author}
            onChange={(e) => setAuthor(e.target.value)}
            className="h-10 w-full border border-ink/25 bg-surface px-3 font-mono text-[13px] outline-none focus:border-ink"
            placeholder={t.comments.namePlaceholder}
            autoComplete="nickname"
            disabled={pending}
          />
        </label>
      </div>
      <label className="block">
        <span className="section-label mb-1 block">
          {compact ? t.comments.reply : t.comments.comment}
        </span>
        <textarea
          value={body}
          onChange={(e) => setBody(e.target.value)}
          rows={compact ? 3 : 4}
          className="w-full resize-y border border-ink/25 bg-surface px-3 py-2 font-mono text-[13px] leading-relaxed outline-none focus:border-ink"
          placeholder={
            compact ? t.comments.replyPlaceholder : t.comments.commentPlaceholder
          }
          disabled={pending}
        />
      </label>
      {error ? (
        <p className="font-mono text-[12px] text-red-700">{error}</p>
      ) : null}
      <div className="flex flex-wrap gap-2">
        <Button type="submit" size="sm" disabled={pending}>
          {pending ? t.comments.sending : submitLabel}
        </Button>
        {onCancel ? (
          <Button
            type="button"
            size="sm"
            variant="ghost"
            disabled={pending}
            onClick={onCancel}
          >
            {t.comments.cancel}
          </Button>
        ) : null}
      </div>
    </form>
  )
}

export function CommentsSection({ slug }: { slug: string }) {
  const { t, locale } = useApp()
  const [comments, setComments] = useState<Comment[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [pending, setPending] = useState(false)
  const [replyTo, setReplyTo] = useState<string | null>(null)

  const reload = useCallback(async () => {
    setLoading(true)
    setError(null)
    const next = await listComments(slug).catch((err: unknown) => {
      setError(errorMessage(err, t.comments.loadFailed))
      return null
    })
    setComments(next ?? [])
    setLoading(false)
  }, [slug, t.comments.loadFailed])

  useEffect(() => {
    void reload()
  }, [reload])

  const onCreate = async (author: string, body: string) => {
    setPending(true)
    const created = await createComment(slug, { author, body }).catch(
      (err: unknown) => {
        setPending(false)
        throw err
      },
    )
    setComments((prev) => [
      ...prev,
      { ...created, replies: created.replies ?? [] },
    ])
    setPending(false)
  }

  const onReply = async (commentId: string, author: string, body: string) => {
    setPending(true)
    const reply = await createReply(slug, commentId, { author, body }).catch(
      (err: unknown) => {
        setPending(false)
        throw err
      },
    )
    setComments((prev) =>
      prev.map((c) =>
        c.id === commentId ? { ...c, replies: [...(c.replies ?? []), reply] } : c,
      ),
    )
    setReplyTo(null)
    setPending(false)
  }

  const onDeleteComment = async (commentId: string) => {
    if (!window.confirm(t.comments.deleteCommentConfirm)) return
    setPending(true)
    const failed = await deleteComment(slug, commentId).catch((err: unknown) => {
      setError(errorMessage(err, t.comments.deleteFailed))
      return true
    })
    if (!failed) setComments((prev) => prev.filter((c) => c.id !== commentId))
    setPending(false)
  }

  const onDeleteReply = async (commentId: string, replyId: string) => {
    if (!window.confirm(t.comments.deleteReplyConfirm)) return
    setPending(true)
    const failed = await deleteReply(slug, commentId, replyId).catch(
      (err: unknown) => {
        setError(errorMessage(err, t.comments.deleteFailed))
        return true
      },
    )
    if (!failed) {
      setComments((prev) =>
        prev.map((c) =>
          c.id === commentId
            ? { ...c, replies: (c.replies ?? []).filter((r) => r.id !== replyId) }
            : c,
        ),
      )
    }
    setPending(false)
  }

  const status = loading
    ? 'loading'
    : error
      ? 'error'
      : comments.length === 0
        ? 'empty'
        : 'ready'

  let list: ReactNode = null
  switch (status) {
    case 'loading':
      list = (
        <p className="font-mono text-[13px] text-muted">{t.comments.loading}</p>
      )
      break
    case 'error':
      list = (
        <div className="space-y-2">
          <p className="font-mono text-[13px] text-red-700">{error}</p>
          <Button type="button" size="sm" variant="outline" onClick={() => void reload()}>
            {t.comments.retry}
          </Button>
        </div>
      )
      break
    case 'empty':
      list = (
        <p className="font-mono text-[13px] text-muted">{t.comments.empty}</p>
      )
      break
    case 'ready':
      list = comments.map((comment) => (
        <article
          key={comment.id}
          className="border border-ink/20 bg-surface p-4 sm:p-5"
        >
          <header className="flex flex-wrap items-baseline justify-between gap-2">
            <div className="font-mono text-[13px]">
              <span className="font-semibold uppercase">{comment.author}</span>
              <span className="mx-2 text-muted">·</span>
              <time className="text-muted" dateTime={comment.created_at}>
                {formatWhen(comment.created_at, locale)}
              </time>
            </div>
            <div className="flex gap-1">
              <Button
                type="button"
                size="sm"
                variant="ghost"
                disabled={pending}
                onClick={() =>
                  setReplyTo((id) => (id === comment.id ? null : comment.id))
                }
              >
                {t.comments.reply}
              </Button>
              <Button
                type="button"
                size="sm"
                variant="ghost"
                disabled={pending}
                onClick={() => void onDeleteComment(comment.id)}
              >
                {t.comments.delete}
              </Button>
            </div>
          </header>
          <p className="mt-3 whitespace-pre-wrap text-[17px] leading-relaxed">
            {comment.body}
          </p>

          {(comment.replies?.length ?? 0) > 0 ? (
            <ul className="mt-4 space-y-3 border-l border-ink/20 pl-4">
              {comment.replies.map((reply) => (
                <li key={reply.id}>
                  <header className="flex flex-wrap items-baseline justify-between gap-2">
                    <div className="font-mono text-[12px]">
                      <span className="font-semibold uppercase">
                        {reply.author}
                      </span>
                      <span className="mx-2 text-muted">·</span>
                      <time className="text-muted" dateTime={reply.created_at}>
                        {formatWhen(reply.created_at, locale)}
                      </time>
                    </div>
                    <Button
                      type="button"
                      size="sm"
                      variant="ghost"
                      disabled={pending}
                      onClick={() => void onDeleteReply(comment.id, reply.id)}
                    >
                      {t.comments.delete}
                    </Button>
                  </header>
                  <p className="mt-1.5 whitespace-pre-wrap text-[15px] leading-relaxed text-ink/90">
                    {reply.body}
                  </p>
                </li>
              ))}
            </ul>
          ) : null}

          {replyTo === comment.id ? (
            <CommentForm
              t={t}
              compact
              submitLabel={t.comments.postReply}
              pending={pending}
              onCancel={() => setReplyTo(null)}
              onSubmit={(author, body) => onReply(comment.id, author, body)}
            />
          ) : null}
        </article>
      ))
      break
  }

  return (
    <section className="mt-16 border-t border-ink/30 pt-10">
      <div className="section-label grid-plus border-b border-ink/30 pb-2">
        {t.comments.label}
      </div>

      <div className="mt-6">
        <CommentForm
          t={t}
          submitLabel={t.comments.postComment}
          pending={pending}
          onSubmit={onCreate}
        />
      </div>

      <div className="mt-10 space-y-6">{list}</div>
    </section>
  )
}
