import { de } from '@/i18n/locales/de'
import { en } from '@/i18n/locales/en'
import { es } from '@/i18n/locales/es'
import { fr } from '@/i18n/locales/fr'
import { ja } from '@/i18n/locales/ja'
import type { Messages } from '@/i18n/types'

export type { Messages }

export const LOCALES = ['en', 'es', 'fr', 'de', 'ja'] as const

export type Locale = (typeof LOCALES)[number]

export const DEFAULT_LOCALE: Locale = 'en'

export const LOCALE_LABELS: Record<Locale, string> = {
  en: 'English',
  es: 'Español',
  fr: 'Français',
  de: 'Deutsch',
  ja: '日本語',
}

export const MESSAGES: Record<Locale, Messages> = {
  en,
  es,
  fr,
  de,
  ja,
}

export function isLocale(value: string): value is Locale {
  return (LOCALES as readonly string[]).includes(value)
}

export function interpolate(
  template: string,
  vars: Record<string, string | number>,
): string {
  return template.replace(/\{(\w+)\}/g, (_, key: string) => String(vars[key] ?? ''))
}
