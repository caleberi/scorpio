import { useId, type ChangeEvent } from 'react'
import { LOCALES, LOCALE_LABELS, isLocale } from '@/i18n'
import { useApp } from '@/lib/app-context'
import { cn } from '@/lib/utils'

export function LocaleSelect({ className }: { className?: string }) {
  const { locale, setLocale, t } = useApp()
  const id = useId()

  const onChange = (event: ChangeEvent<HTMLSelectElement>) => {
    if (isLocale(event.target.value)) setLocale(event.target.value)
  }

  return (
    <div className={cn(className)}>
      <label className="section-label mb-2 block" htmlFor={id}>
        {t.sidebar.language}
      </label>
      <select
        id={id}
        value={locale}
        onChange={onChange}
        className="w-full border border-ink/25 bg-surface px-1.5 py-1 font-mono text-[12px] outline-none focus:border-ink"
      >
        {LOCALES.map((code) => (
          <option key={code} value={code}>
            {LOCALE_LABELS[code]}
          </option>
        ))}
      </select>
    </div>
  )
}
