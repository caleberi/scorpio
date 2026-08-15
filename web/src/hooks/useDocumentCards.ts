import { useEffect, useState } from 'react'
import { getDocument, type BlogListing } from '@/lib/api'
import { listingToCard, type CardData } from '@/lib/cards'

export function useDocumentCards(documents: BlogListing[]): CardData[] {
  const [cards, setCards] = useState<CardData[]>([])

  useEffect(() => {
    let cancelled = false

    async function load() {
      const next = await Promise.all(
        documents.map(async (doc) => {
          const full = await getDocument(doc.slug).catch(() => null)
          return listingToCard(doc, full)
        }),
      )
      if (!cancelled) setCards(next)
    }

    if (documents.length) void load()
    else setCards([])

    return () => {
      cancelled = true
    }
  }, [documents])

  return cards
}
