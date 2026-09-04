'use client'

import { useEffect, useMemo, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import {
  Boxes,
  ContactRound,
  Download,
  FileSpreadsheet,
  Landmark,
  Loader2,
  RefreshCcw,
  ShoppingCart,
  Tags,
} from 'lucide-react'
import { MasterImportView } from '@/components/MasterImportView'
import { DistributorPricelistImportView } from '@/components/DistributorPricelistImportView'
import { isImportType } from '@/lib/master-import'

type CatalogItem = {
  moduleKey: 'INVENTORY' | 'CONTACTS' | 'PURCHASE' | 'SALES' | 'FINANCE'
  typeKey: string
  label: string
  description: string
  allowedActions: Array<'EXPORT' | 'IMPORT'>
  formats: Array<'CSV' | 'XLSX'>
  scopeKind: 'COMPANY' | 'STORE' | 'WAREHOUSE'
  exportOnly: boolean
  filters: Array<'MONTH' | 'DATE_RANGE'>
}

type Props = {
  session: Session
  companyId: string
  companyName: string
  notify: (message: string) => void
}

const moduleLabels = {
  INVENTORY: 'Inventory',
  CONTACTS: 'Kontak',
  PURCHASE: 'Purchase',
  SALES: 'Sales',
  FINANCE: 'Finance',
} as const

const moduleIcons = {
  INVENTORY: Boxes,
  CONTACTS: ContactRound,
  PURCHASE: ShoppingCart,
  SALES: Tags,
  FINANCE: Landmark,
}

const friendlyErrors: Record<string, string> = {
  DATA_EXCHANGE_ACTION_FORBIDDEN: 'Anda tidak memiliki izin export untuk data ini.',
  DATA_EXCHANGE_TYPE_UNSUPPORTED: 'Jenis data tidak tersedia.',
  COMPANY_ACCESS_DENIED: 'Anda tidak memiliki akses ke Company aktif.',
  ACTIVE_COMPANY_NOT_FOUND: 'Pilih Company aktif terlebih dahulu.',
  INVALID_SESSION: 'Sesi login berakhir. Silakan masuk kembali.',
  FINANCE_EXPORT_LIMIT_EXCEEDED: 'Data bulan ini terlalu besar untuk satu file export.',
  SALES_DOCUMENT_EXPORT_DATE_RANGE_REQUIRED: 'Isi tanggal mulai dan tanggal akhir Invoice.',
  SALES_DOCUMENT_EXPORT_DATE_RANGE_INVALID: 'Tanggal mulai tidak boleh melewati tanggal akhir.',
  CUSTOM_PERMISSION_DENIED: 'Akses export untuk data ini dibatasi oleh Company Admin.',
}

function authHeaders(session: Session) {
  return { Authorization: `Bearer ${session.access_token}` }
}

function currentMonth() {
  const now = new Date()
  return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`
}

function currentDateRange() {
  const now = new Date()
  const year = now.getFullYear()
  const month = String(now.getMonth() + 1).padStart(2, '0')
  const day = String(now.getDate()).padStart(2, '0')
  return { dateFrom: `${year}-${month}-01`, dateTo: `${year}-${month}-${day}` }
}

function friendly(value?: string) {
  return friendlyErrors[value ?? ''] ?? value ?? 'Proses export gagal.'
}

async function responseError(response: Response) {
  const contentType = response.headers.get('content-type') ?? ''
  if (!contentType.includes('application/json')) {
    return 'Server belum memuat route Data Exchange. Restart Backoffice lalu coba lagi.'
  }
  const payload = (await response.json()) as { error?: string }
  return friendly(payload.error)
}

export function DataExchangeView({ session, companyId, companyName, notify }: Props) {
  const [items, setItems] = useState<CatalogItem[]>([])
  const [action, setAction] = useState<'EXPORT' | 'IMPORT'>('EXPORT')
  const [selectedType, setSelectedType] = useState('')
  const [selectedImportType, setSelectedImportType] = useState('')
  const [month, setMonth] = useState(currentMonth())
  const [dateFrom, setDateFrom] = useState(() => currentDateRange().dateFrom)
  const [dateTo, setDateTo] = useState(() => currentDateRange().dateTo)
  const [loading, setLoading] = useState(true)
  const [downloading, setDownloading] = useState(false)
  const [error, setError] = useState('')

  async function loadCatalog() {
    setLoading(true)
    setError('')
    try {
      const response = await fetch('/api/data-exchange/catalog', {
        headers: authHeaders(session),
        cache: 'no-store',
      })
      if (!response.ok) throw new Error(await responseError(response))
      const payload = (await response.json()) as { data?: { items?: CatalogItem[] } }
      const nextItems = payload.data?.items ?? []
      setItems(nextItems)
      setSelectedType((current) =>
        nextItems.some((item) => item.typeKey === current && item.allowedActions.includes('EXPORT'))
          ? current
          : (nextItems.find((item) => item.allowedActions.includes('EXPORT'))?.typeKey ?? ''))
      setSelectedImportType((current) =>
        nextItems.some((item) => item.typeKey === current && item.allowedActions.includes('IMPORT'))
          ? current
          : (nextItems.find((item) => item.allowedActions.includes('IMPORT'))?.typeKey ?? ''))
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Katalog gagal dimuat.')
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => {
    const timer = window.setTimeout(() => void loadCatalog(), 0)
    // Catalog is reloaded when the authenticated Company-scoped component remounts.
    return () => window.clearTimeout(timer)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [session.access_token])

  const exportItems = useMemo(
    () => items.filter((item) => item.allowedActions.includes('EXPORT')),
    [items],
  )
  const importItems = useMemo(
    () => items.filter((item) => item.allowedActions.includes('IMPORT')),
    [items],
  )
  const selected = exportItems.find((item) => item.typeKey === selectedType) ?? null
  const grouped = useMemo(() =>
    Object.entries(moduleLabels).map(([moduleKey, label]) => ({
      moduleKey: moduleKey as CatalogItem['moduleKey'],
      label,
      items: exportItems.filter((item) => item.moduleKey === moduleKey),
    })).filter((module) => module.items.length > 0), [exportItems])

  async function download() {
    if (!selected) return
    setDownloading(true)
    setError('')
    try {
      const query = new URLSearchParams({ type: selected.typeKey })
      const path = selected.typeKey === 'SALES_DOCUMENTS'
        ? (() => {
            query.set('dateFrom', dateFrom)
            query.set('dateTo', dateTo)
            return `/api/sales/documents/export?${query}`
          })()
        : selected.formats.includes('XLSX')
        ? (() => {
            query.set('month', month)
            return `/api/finance/operations/export?${query}`
          })()
        : selected.typeKey === 'STOCK_REAL' || selected.typeKey === 'STOCK_MOVEMENTS'
          ? `/api/inventory/export?${query}`
          : selected.typeKey === 'PRICELISTS'
            ? `/api/sales/pricelists/export?${query}`
          : selected.typeKey === 'PAYMENT_METHODS'
            ? `/api/finance/payment-methods/export?${query}`
          : (() => {
            query.set('kind', 'data')
            return `/api/master/import-export?${query}`
          })()
      const response = await fetch(path, {
        headers: authHeaders(session),
        cache: 'no-store',
      })
      if (!response.ok) throw new Error(await responseError(response))
      const blob = await response.blob()
      const disposition = response.headers.get('content-disposition') ?? ''
      const filename = disposition.match(/filename="([^"]+)"/)?.[1]
        ?? `${selected.typeKey.toLowerCase()}.${selected.formats.includes('XLSX') ? 'xlsx' : 'csv'}`
      const url = URL.createObjectURL(blob)
      const anchor = document.createElement('a')
      anchor.href = url
      anchor.download = filename
      anchor.click()
      URL.revokeObjectURL(url)
      notify(`${selected.label} berhasil diexport.`)
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Export gagal.')
    } finally {
      setDownloading(false)
    }
  }

  return (
    <div className="space-y-6">
      <section className="overflow-hidden rounded-3xl bg-slate-950 text-white shadow-xl shadow-slate-950/10">
        <div className="grid gap-6 p-6 md:grid-cols-[1fr_auto] md:p-8">
          <div>
            <p className="text-xs font-black uppercase tracking-[.18em] text-emerald-400">Global Data Exchange</p>
            <h1 className="mt-3 text-3xl font-black tracking-tight">
              {action === 'IMPORT' ? 'Import' : 'Export'} data {companyName}
            </h1>
            <p className="mt-3 max-w-2xl text-sm leading-6 text-slate-300">
              Hanya modul dan jenis data yang diizinkan server untuk role Anda yang ditampilkan.
              {action === 'IMPORT'
                ? ' Semua perubahan melewati preview, validasi, dan konfirmasi sebelum disimpan.'
                : ' Data Finance memakai laporan canonical dan file Excel bulanan.'}
            </p>
          </div>
          <button
            type="button"
            onClick={() => void loadCatalog()}
            disabled={loading}
            className="inline-flex min-h-11 items-center justify-center gap-2 self-start rounded-xl border border-slate-700 bg-slate-900 px-4 text-sm font-black hover:border-emerald-500 disabled:opacity-60"
          >
            <RefreshCcw className={`h-4 w-4 ${loading ? 'animate-spin' : ''}`} />
            Muat ulang akses
          </button>
        </div>
      </section>

      <div className="inline-flex rounded-2xl border border-slate-200 bg-white p-1.5 shadow-sm">
        <button
          type="button"
          onClick={() => setAction('EXPORT')}
          className={`min-h-10 rounded-xl px-5 text-sm font-black ${action === 'EXPORT' ? 'bg-emerald-600 text-white shadow-sm' : 'text-slate-600 hover:bg-slate-50'}`}
        >
          Export
        </button>
        {importItems.length > 0 && (
          <button
            type="button"
            onClick={() => setAction('IMPORT')}
            className={`min-h-10 rounded-xl px-5 text-sm font-black ${action === 'IMPORT' ? 'bg-emerald-600 text-white shadow-sm' : 'text-slate-600 hover:bg-slate-50'}`}
          >
            Import
          </button>
        )}
      </div>

      {error && <p className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-bold text-rose-700">{error}</p>}

      {loading ? (
        <div className="grid min-h-56 place-items-center rounded-3xl border border-slate-200 bg-white">
          <Loader2 className="h-7 w-7 animate-spin text-emerald-600" />
        </div>
      ) : action === 'IMPORT' && importItems.length > 0 ? (
        <div className="space-y-5">
          <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm md:p-6">
            <p className="text-xs font-black uppercase tracking-[.16em] text-slate-400">Pilih jenis import</p>
            <div className="mt-4 grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
              {importItems.map((item) => <button key={item.typeKey} type="button" onClick={() => setSelectedImportType(item.typeKey)} className={`rounded-2xl border p-4 text-left ${selectedImportType === item.typeKey ? 'border-emerald-500 bg-emerald-50 ring-2 ring-emerald-100' : 'border-slate-200 hover:bg-slate-50'}`}><b className="text-sm text-slate-900">{item.label}</b><span className="mt-1 block text-xs leading-5 text-slate-500">{item.description}</span></button>)}
            </div>
          </section>
          {selectedImportType === 'PRICELISTS' ? (
            <DistributorPricelistImportView session={session} companyName={companyName} notify={notify} />
          ) : isImportType(selectedImportType) ? (
            <MasterImportView
              session={session}
              companyId={companyId}
              notify={notify}
              allowedTypes={[selectedImportType]}
              embedded
            />
          ) : null}
        </div>
      ) : exportItems.length === 0 ? (
        <div className="rounded-3xl border border-dashed border-slate-300 bg-white p-12 text-center">
          <FileSpreadsheet className="mx-auto h-9 w-9 text-slate-300" />
          <h2 className="mt-4 font-black text-slate-800">Tidak ada data yang dapat diexport</h2>
          <p className="mt-2 text-sm text-slate-500">Hubungi Company Admin bila akses kerja Anda perlu ditambahkan.</p>
        </div>
      ) : (
        <div className="grid gap-6 xl:grid-cols-[1.15fr_.85fr]">
          <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm md:p-6">
            <p className="text-xs font-black uppercase tracking-[.16em] text-slate-400">1 · Pilih data</p>
            <div className="mt-5 space-y-6">
              {grouped.map((module) => {
                const Icon = moduleIcons[module.moduleKey]
                return (
                  <div key={module.moduleKey}>
                    <div className="mb-3 flex items-center gap-2">
                      <span className="grid h-8 w-8 place-items-center rounded-lg bg-slate-100 text-slate-600"><Icon className="h-4 w-4" /></span>
                      <h2 className="font-black text-slate-900">{module.label}</h2>
                    </div>
                    <div className="grid gap-2 sm:grid-cols-2">
                      {module.items.map((item) => (
                        <button
                          key={item.typeKey}
                          type="button"
                          onClick={() => setSelectedType(item.typeKey)}
                          className={`rounded-2xl border p-4 text-left transition ${selectedType === item.typeKey ? 'border-emerald-500 bg-emerald-50 ring-2 ring-emerald-100' : 'border-slate-200 hover:border-slate-300 hover:bg-slate-50'}`}
                        >
                          <span className="font-black text-slate-900">{item.label}</span>
                          <span className="mt-1 block text-xs leading-5 text-slate-500">{item.description}</span>
                          <span className="mt-3 inline-flex rounded-md bg-white px-2 py-1 text-[11px] font-black text-slate-500 ring-1 ring-slate-200">{item.formats.join(' / ')}</span>
                        </button>
                      ))}
                    </div>
                  </div>
                )
              })}
            </div>
          </section>

          <section className="h-fit rounded-3xl border border-slate-200 bg-white p-5 shadow-sm md:p-6 xl:sticky xl:top-5">
            <p className="text-xs font-black uppercase tracking-[.16em] text-slate-400">2 · Atur dan export</p>
            {selected && (
              <>
                <h2 className="mt-4 text-2xl font-black text-slate-950">{selected.label}</h2>
                <p className="mt-2 text-sm leading-6 text-slate-500">{selected.description}</p>
                <div className="mt-5 rounded-2xl bg-slate-50 p-4 text-sm">
                  <div className="flex justify-between gap-4"><span className="text-slate-500">Scope</span><b>Company aktif</b></div>
                  <div className="mt-2 flex justify-between gap-4"><span className="text-slate-500">Format</span><b>{selected.formats.join(' / ')}</b></div>
                  <div className="mt-2 flex justify-between gap-4"><span className="text-slate-500">Aksi</span><b>Export only</b></div>
                </div>
                {selected.filters.includes('MONTH') && (
                  <label className="mt-5 block text-sm font-black text-slate-800">
                    Bulan laporan
                    <input
                      type="month"
                      value={month}
                      onChange={(event) => setMonth(event.target.value)}
                      className="mt-2 min-h-12 w-full rounded-xl border border-slate-200 px-3 font-normal outline-none focus:border-emerald-500"
                    />
                  </label>
                )}
                {selected.filters.includes('DATE_RANGE') && (
                  <div className="mt-5 grid gap-3 sm:grid-cols-2">
                    <label className="block text-sm font-black text-slate-800">
                      Tanggal mulai
                      <input type="date" value={dateFrom} max={dateTo || undefined}
                        onChange={(event) => setDateFrom(event.target.value)}
                        className="mt-2 min-h-12 w-full rounded-xl border border-slate-200 px-3 font-normal outline-none focus:border-emerald-500" />
                    </label>
                    <label className="block text-sm font-black text-slate-800">
                      Tanggal akhir
                      <input type="date" value={dateTo} min={dateFrom || undefined}
                        onChange={(event) => setDateTo(event.target.value)}
                        className="mt-2 min-h-12 w-full rounded-xl border border-slate-200 px-3 font-normal outline-none focus:border-emerald-500" />
                    </label>
                    <p className="text-xs leading-5 text-slate-500 sm:col-span-2">
                      Mengikuti tanggal yang tampil pada Invoice sesuai pengaturan Company.
                    </p>
                  </div>
                )}
                <button
                  type="button"
                  onClick={() => void download()}
                  disabled={downloading
                    || (selected.filters.includes('MONTH') && !month)
                    || (selected.filters.includes('DATE_RANGE')
                      && (!dateFrom || !dateTo || dateFrom > dateTo))}
                  className="mt-6 inline-flex min-h-12 w-full items-center justify-center gap-2 rounded-xl bg-emerald-600 px-5 text-sm font-black text-white shadow-lg shadow-emerald-600/20 hover:bg-emerald-700 disabled:bg-slate-300 disabled:shadow-none"
                >
                  {downloading ? <Loader2 className="h-4 w-4 animate-spin" /> : <Download className="h-4 w-4" />}
                  {downloading ? 'Menyiapkan file…' : `Export ${selected.formats[0]}`}
                </button>
                {importItems.length > 0 && <p className="mt-4 text-xs leading-5 text-slate-500">
                  Gunakan tab Import untuk template, upload, preview, konfirmasi, dan riwayat import.
                </p>}
              </>
            )}
          </section>
        </div>
      )}
    </div>
  )
}
