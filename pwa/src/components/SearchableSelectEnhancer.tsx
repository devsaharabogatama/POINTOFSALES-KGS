import { Check, ChevronDown, Search, X } from 'lucide-react'
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import { createPortal } from 'react-dom'

const SEARCH_THRESHOLD = 10

type SelectOption = { disabled: boolean; label: string; value: string }
type Position = { left: number; top: number; width: number }

function normalized(value: string) {
  return value
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLocaleLowerCase('id-ID')
    .trim()
}

function selectOptions(select: HTMLSelectElement): SelectOption[] {
  return Array.from(select.options).map((option) => ({
    disabled: option.disabled,
    label: option.textContent?.trim() || option.label || option.value,
    value: option.value,
  }))
}

function isLongSelect(select: HTMLSelectElement) {
  return selectOptions(select).filter((option) => !option.disabled && option.value !== '').length >= SEARCH_THRESHOLD
}

function popupPosition(select: HTMLSelectElement): Position {
  const rect = select.getBoundingClientRect()
  const gutter = 8
  const width = Math.min(Math.max(rect.width, 280), window.innerWidth - gutter * 2)
  const left = Math.min(Math.max(gutter, rect.left), window.innerWidth - width - gutter)
  const estimatedHeight = 360
  const below = rect.bottom + gutter
  const top = below + estimatedHeight <= window.innerHeight
    ? below
    : Math.max(gutter, rect.top - estimatedHeight - gutter)
  return { left, top, width }
}

function applyValue(select: HTMLSelectElement, value: string) {
  const setter = Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, 'value')?.set
  setter?.call(select, value)
  select.dispatchEvent(new Event('change', { bubbles: true }))
  select.focus({ preventScroll: true })
}

export default function SearchableSelectEnhancer() {
  const [target, setTarget] = useState<HTMLSelectElement | null>(null)
  const [options, setOptions] = useState<SelectOption[]>([])
  const [query, setQuery] = useState('')
  const [activeIndex, setActiveIndex] = useState(0)
  const [position, setPosition] = useState<Position | null>(null)
  const searchRef = useRef<HTMLInputElement>(null)

  const close = useCallback(() => {
    setTarget(null)
    setOptions([])
    setQuery('')
    setPosition(null)
  }, [])

  const open = useCallback((select: HTMLSelectElement) => {
    const nextOptions = selectOptions(select)
    const selectedIndex = Math.max(0, nextOptions.findIndex((option) => option.value === select.value))
    setTarget(select)
    setOptions(nextOptions)
    setQuery('')
    setActiveIndex(selectedIndex)
    setPosition(popupPosition(select))
  }, [])

  useEffect(() => {
    const pointerDown = (event: PointerEvent) => {
      const select = event.target instanceof HTMLSelectElement ? event.target : null
      if (!select || select.disabled || !isLongSelect(select)) return
      event.preventDefault()
      event.stopPropagation()
      open(select)
    }
    const keyDown = (event: KeyboardEvent) => {
      const select = event.target instanceof HTMLSelectElement ? event.target : null
      if (!select || select.disabled || !isLongSelect(select)) return
      if (!['Enter', ' ', 'ArrowDown', 'ArrowUp'].includes(event.key)) return
      event.preventDefault()
      open(select)
    }
    document.addEventListener('pointerdown', pointerDown, true)
    document.addEventListener('keydown', keyDown, true)
    return () => {
      document.removeEventListener('pointerdown', pointerDown, true)
      document.removeEventListener('keydown', keyDown, true)
    }
  }, [open])

  useEffect(() => {
    if (!target) return
    const reposition = () => {
      if (!target.isConnected) return close()
      setOptions(selectOptions(target))
      setPosition(popupPosition(target))
    }
    window.addEventListener('resize', reposition)
    window.addEventListener('scroll', reposition, true)
    const observer = new MutationObserver(reposition)
    observer.observe(target, { childList: true, subtree: true })
    return () => {
      window.removeEventListener('resize', reposition)
      window.removeEventListener('scroll', reposition, true)
      observer.disconnect()
    }
  }, [close, target])

  useLayoutEffect(() => {
    if (target) searchRef.current?.focus()
  }, [target])

  const filtered = useMemo(() => {
    const needle = normalized(query)
    return needle ? options.filter((option) => normalized(option.label).includes(needle)) : options
  }, [options, query])

  const focusedIndex = filtered.length
    ? Math.min(Math.max(activeIndex, 0), filtered.length - 1)
    : -1

  if (!target || !position || typeof document === 'undefined') return null

  const choose = (option: SelectOption) => {
    if (option.disabled) return
    applyValue(target, option.value)
    close()
  }

  return createPortal(
    <>
      <button type="button" aria-label="Tutup pilihan" className="fixed inset-0 z-[2147483645] cursor-default bg-transparent" onClick={close} />
      <section
        role="dialog"
        aria-label={target.getAttribute('aria-label') || 'Cari pilihan'}
        className="fixed z-[2147483646] overflow-hidden rounded-2xl border border-slate-200 bg-white text-slate-950 shadow-2xl"
        style={{ left: position.left, top: position.top, width: position.width }}
        onKeyDown={(event) => {
          if (event.key === 'Escape') {
            event.preventDefault()
            close()
          } else if (event.key === 'ArrowDown' && filtered.length) {
            event.preventDefault()
            setActiveIndex((current) => (current + 1 + filtered.length) % filtered.length)
          } else if (event.key === 'ArrowUp' && filtered.length) {
            event.preventDefault()
            setActiveIndex((current) => (current - 1 + filtered.length) % filtered.length)
          } else if (event.key === 'Enter' && focusedIndex >= 0 && filtered[focusedIndex]) {
            event.preventDefault()
            choose(filtered[focusedIndex])
          }
        }}
      >
        <div className="flex items-center gap-2 border-b border-slate-200 p-3">
          <Search className="h-5 w-5 shrink-0 text-slate-400" />
          <input ref={searchRef} value={query} onChange={(event) => { setQuery(event.target.value); setActiveIndex(0) }} placeholder="Ketik untuk mencari..." aria-label="Ketik untuk mencari pilihan" className="min-w-0 flex-1 bg-transparent px-1 py-2 text-sm outline-none" />
          {query && <button type="button" aria-label="Hapus pencarian" onClick={() => setQuery('')} className="rounded-lg p-1 text-slate-500 hover:bg-slate-100"><X className="h-4 w-4" /></button>}
        </div>
        <div role="listbox" className="max-h-72 overflow-y-auto p-2">
          {filtered.map((option, index) => {
            const selected = option.value === target.value
            return <button type="button" role="option" aria-selected={selected} disabled={option.disabled} key={`${option.value}:${index}`} onMouseEnter={() => setActiveIndex(index)} onClick={() => choose(option)} className={`flex w-full items-center justify-between gap-3 rounded-xl px-3 py-2.5 text-left text-sm ${index === focusedIndex ? 'bg-emerald-50 text-emerald-900' : 'hover:bg-slate-50'} disabled:cursor-not-allowed disabled:opacity-40`}><span>{option.label}</span>{selected ? <Check className="h-4 w-4 shrink-0 text-emerald-600" /> : null}</button>
          })}
          {!filtered.length && <p className="px-3 py-8 text-center text-sm text-slate-500">Pilihan tidak ditemukan.</p>}
        </div>
        <div className="flex items-center justify-between border-t border-slate-100 px-3 py-2 text-[11px] text-slate-400"><span>{filtered.length} pilihan</span><span className="inline-flex items-center gap-1">Enter untuk memilih <ChevronDown className="h-3 w-3" /></span></div>
      </section>
    </>,
    document.body,
  )
}
