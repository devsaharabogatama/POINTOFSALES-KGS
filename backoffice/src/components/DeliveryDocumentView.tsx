'use client'

import { useCallback, useEffect, useMemo, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import {
  Archive, Ban, CheckCircle2, Download, Eye, FileText, Loader2,
  RefreshCcw, Search, Send, X,
} from 'lucide-react'
import { useEscapeClose } from '@/lib/use-escape-close'
import {
  createSalesDeliveryPdfFile,
  downloadSalesDeliveryPdf,
  printSalesDeliveryDocument,
} from '@/lib/sales-document-print'

type JsonMap = Record<string, unknown>
type DeliverySummary = {
  salesId: string
  deliveryDocumentId: string
  deliveryNo: string
  invoiceNo: string
  status: string
  masterVersion: number
  createdAt: string
  scheduledAt: string | null
  recipientName: string
  recipientPhone: string
  deliveryAddress: string
  customerName: string
  storeName: string
  warehouseName: string
}

const MAX_BULK_DOCUMENTS = 50
const headers = (session: Session, json = false) => ({
  Authorization: `Bearer ${session.access_token}`,
  ...(json ? { 'Content-Type': 'application/json' } : {}),
})
const dateTime = (value?: string | null) => value
  ? new Date(value).toLocaleString('id-ID') : '-'
function statusLabel(status?: string) {
  return ({ READY: 'Siap dikirim', DISPATCHED: 'Dalam perjalanan', DELIVERED: 'Terkirim', CANCELED: 'Dibatalkan' } as Record<string, string>)[status ?? ''] ?? status ?? '-'
}
function statusClass(status?: string) {
  if (status === 'DELIVERED') return 'bg-emerald-100 text-emerald-800'
  if (status === 'DISPATCHED') return 'bg-blue-100 text-blue-800'
  if (status === 'CANCELED') return 'bg-rose-100 text-rose-800'
  return 'bg-amber-100 text-amber-800'
}
function friendly(code?: string) {
  return ({
    SALES_DELIVERY_NOT_FOUND: 'Surat Jalan tidak ditemukan.',
    CUSTOM_PERMISSION_DENIED: 'Anda tidak diizinkan mengakses Surat Jalan.',
    MASTER_VERSION_CONFLICT: 'Dokumen berubah. Muat ulang lalu coba lagi.',
    INVALID_SALES_DELIVERY_TRANSITION: 'Perubahan status tidak valid.',
    CANCEL_REASON_REQUIRED: 'Alasan pembatalan wajib diisi.',
  } as Record<string, string>)[code ?? ''] ?? code ?? 'Operasi Surat Jalan gagal.'
}
function saveBlob(blob: Blob, fileName: string) {
  const url = URL.createObjectURL(blob)
  const anchor = window.document.createElement('a')
  anchor.href = url
  anchor.download = fileName
  anchor.click()
  window.setTimeout(() => URL.revokeObjectURL(url), 60_000)
}

export function DeliveryDocumentView({
  session, companyId, canManage, notify,
}: {
  session: Session
  companyId: string
  canManage: boolean
  notify: (message: string) => void
}) {
  const [rows, setRows] = useState<DeliverySummary[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [search, setSearch] = useState('')
  const [status, setStatus] = useState('ALL')
  const [selected, setSelected] = useState<DeliverySummary | null>(null)
  const [detail, setDetail] = useState<JsonMap | null>(null)
  const [action, setAction] = useState<'DISPATCH' | 'DELIVER' | 'CANCEL' | null>(null)
  const [markedIds, setMarkedIds] = useState<string[]>([])
  const [bulkDownloading, setBulkDownloading] = useState(false)
  const [bulkProgress, setBulkProgress] = useState({ done: 0, total: 0 })
  const [showLogoOnDocuments, setShowLogoOnDocuments] = useState(true)
  const [showStampOnDocuments, setShowStampOnDocuments] = useState(false)

  const load = useCallback(async () => {
    setLoading(true)
    setError('')
    try {
      const [response, brandingResponse] = await Promise.all([
        fetch('/api/inventory/delivery-documents', { headers: headers(session) }),
        fetch('/api/platform/company-branding', {
          headers: headers(session), cache: 'no-store',
        }),
      ])
      const result = await response.json() as { data?: DeliverySummary[]; error?: string }
      if (!response.ok) throw new Error(friendly(result.error))
      setRows(result.data ?? [])
      setMarkedIds([])
      if (brandingResponse.ok) {
        const branding = await brandingResponse.json() as {
          data?: { showLogoOnDocuments?: boolean; showStampOnDocuments?: boolean }
        }
        setShowLogoOnDocuments(branding.data?.showLogoOnDocuments ?? true)
        setShowStampOnDocuments(branding.data?.showStampOnDocuments ?? false)
      }
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Surat Jalan gagal dimuat.')
    } finally {
      setLoading(false)
    }
  }, [session])
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- rows follow active Company context
    void load()
  }, [load, companyId])

  const filtered = useMemo(() => rows.filter((row) => {
    const keyword = search.trim().toLowerCase()
    return (status === 'ALL' || row.status === status) && (!keyword || [
      row.deliveryNo, row.invoiceNo, row.recipientName, row.storeName,
      row.warehouseName,
    ].some((value) => value?.toLowerCase().includes(keyword)))
  }), [rows, search, status])
  const marked = useMemo(() => new Set(markedIds), [markedIds])
  const markedRows = useMemo(
    () => rows.filter((row) => marked.has(row.deliveryDocumentId)),
    [marked, rows],
  )
  const selectableFiltered = filtered.slice(0, MAX_BULK_DOCUMENTS)
  const allFilteredMarked = selectableFiltered.length > 0 && selectableFiltered.every(
    (row) => marked.has(row.deliveryDocumentId),
  )

  function toggleRow(id: string) {
    setMarkedIds((current) => current.includes(id)
      ? current.filter((value) => value !== id)
      : current.length >= MAX_BULK_DOCUMENTS ? current : [...current, id])
  }
  function toggleFiltered() {
    const ids = selectableFiltered.map((row) => row.deliveryDocumentId)
    setMarkedIds((current) => allFilteredMarked
      ? current.filter((id) => !ids.includes(id))
      : Array.from(new Set([...current, ...ids])).slice(0, MAX_BULK_DOCUMENTS))
  }
  async function open(row: DeliverySummary) {
    setSelected(row)
    setDetail(null)
    setError('')
    try {
      const response = await fetch(`/api/inventory/delivery-documents/${row.salesId}`, {
        headers: headers(session),
      })
      const result = await response.json() as { delivery?: JsonMap; error?: string }
      if (!response.ok) throw new Error(friendly(result.error))
      setDetail(result.delivery ?? null)
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Detail Surat Jalan gagal dimuat.')
      setSelected(null)
    }
  }
  async function recordDownload(row: DeliverySummary) {
    const response = await fetch(`/api/inventory/delivery-documents/${row.salesId}`, {
      method: 'POST', headers: headers(session, true),
      body: JSON.stringify({ deliveryDocumentId: row.deliveryDocumentId }),
    })
    const result = await response.json() as { error?: string }
    if (!response.ok) throw new Error(friendly(result.error))
  }
  async function print() {
    if (!selected || !detail) return
    try {
      printSalesDeliveryDocument(
        detail, showLogoOnDocuments, showStampOnDocuments,
      )
      await recordDownload(selected)
      notify('Surat Jalan dibuka di tab baru.')
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Surat Jalan gagal dicetak.')
    }
  }
  async function download() {
    if (!selected || !detail) return
    try {
      await downloadSalesDeliveryPdf(
        detail, selected.customerName, showLogoOnDocuments,
        showStampOnDocuments,
      )
      await recordDownload(selected)
      notify('Surat Jalan berhasil diunduh.')
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Surat Jalan gagal diunduh.')
    }
  }
  async function bulkDownload() {
    if (!markedRows.length || bulkDownloading) return
    setBulkDownloading(true)
    setError('')
    setBulkProgress({ done: 0, total: markedRows.length })
    try {
      const { strToU8, zipSync } = await import('fflate')
      const files: Record<string, Uint8Array> = {}
      const failures: string[] = []
      let cursor = 0
      let done = 0
      async function worker() {
        while (cursor < markedRows.length) {
          const row = markedRows[cursor++]
          try {
            const response = await fetch(`/api/inventory/delivery-documents/${row.salesId}`, {
              headers: headers(session),
            })
            const result = await response.json() as { delivery?: JsonMap; error?: string }
            if (!response.ok || !result.delivery) throw new Error(friendly(result.error))
            const pdf = await createSalesDeliveryPdfFile(
              result.delivery, row.customerName, showLogoOnDocuments,
              showStampOnDocuments,
            )
            await recordDownload(row)
            files[pdf.fileName] = pdf.data
          } catch (caught) {
            failures.push(`${row.deliveryNo}: ${caught instanceof Error ? caught.message : 'Gagal diproses'}`)
          }
          done += 1
          setBulkProgress({ done, total: markedRows.length })
        }
      }
      await Promise.all(Array.from(
        { length: Math.min(3, markedRows.length) }, () => worker(),
      ))
      if (failures.length) files['GAGAL-DIUNDUH.txt'] = strToU8(failures.join('\r\n'))
      const pdfCount = Object.keys(files).filter((name) => name.endsWith('.pdf')).length
      if (!pdfCount) throw new Error(failures[0] ?? 'Tidak ada Surat Jalan yang dapat diunduh.')
      const archive = zipSync(files, { level: 0 })
      saveBlob(new Blob([archive], { type: 'application/zip' }),
        `SURAT-JALAN_${new Date().toISOString().slice(0, 10)}_${pdfCount}-DOKUMEN.zip`)
      notify(`${pdfCount} Surat Jalan berhasil disiapkan${failures.length
        ? `; ${failures.length} gagal dan dicatat dalam ZIP.` : '.'}`)
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Bulk download Surat Jalan gagal.')
    } finally {
      setBulkDownloading(false)
    }
  }
  async function complete() {
    setAction(null)
    setSelected(null)
    setDetail(null)
    await load()
    notify('Status Surat Jalan berhasil diperbarui.')
  }

  return <section className="space-y-5">
    <header className="flex flex-col gap-4 rounded-3xl border border-slate-200 bg-white p-6 shadow-sm lg:flex-row lg:items-center lg:justify-between">
      <div><p className="text-xs font-black uppercase tracking-[.2em] text-blue-700">Inventory</p><h1 className="mt-2 text-2xl font-black">Surat Jalan</h1><p className="mt-1 text-sm text-slate-500">Siapkan, cetak, dan pantau pengiriman tanpa membuka nilai Invoice.</p></div>
      <div className="flex flex-wrap gap-2">
        <button onClick={() => void bulkDownload()} disabled={!markedRows.length || bulkDownloading} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-xl bg-blue-600 px-4 font-black text-white disabled:bg-slate-300"><Archive className="h-4 w-4"/>{bulkDownloading ? `Menyiapkan ${bulkProgress.done}/${bulkProgress.total}` : `Unduh PDF Terpilih (${markedRows.length})`}</button>
        <button onClick={() => void load()} disabled={loading || bulkDownloading} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-xl border border-slate-200 px-4 font-bold"><RefreshCcw className={`h-4 w-4 ${loading ? 'animate-spin' : ''}`}/>Muat ulang</button>
      </div>
    </header>
    <div className="grid gap-3 rounded-2xl border border-slate-200 bg-white p-4 sm:grid-cols-[1fr_auto]">
      <label className="relative"><Search className="absolute left-3 top-3.5 h-4 w-4 text-slate-400"/><input value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Cari SJ, Invoice, penerima, toko, atau gudang" className="min-h-11 w-full rounded-xl border border-slate-200 pl-10 pr-3"/></label>
      <select value={status} onChange={(event) => setStatus(event.target.value)} className="min-h-11 rounded-xl border border-slate-200 px-3"><option value="ALL">Semua status</option><option value="READY">Siap dikirim</option><option value="DISPATCHED">Dalam perjalanan</option><option value="DELIVERED">Terkirim</option><option value="CANCELED">Dibatalkan</option></select>
    </div>
    <div className="flex flex-wrap items-center justify-between gap-3 rounded-2xl border border-blue-100 bg-blue-50 p-4 text-sm">
      <label className="inline-flex items-center gap-3 font-black text-blue-950"><input type="checkbox" checked={allFilteredMarked} onChange={toggleFiltered} disabled={!selectableFiltered.length || bulkDownloading} className="h-5 w-5 accent-blue-600"/>Pilih semua hasil filter{filtered.length > MAX_BULK_DOCUMENTS ? ` (maksimal ${MAX_BULK_DOCUMENTS})` : ''}</label>
      <span className="font-semibold text-blue-800">{markedRows.length} dokumen dipilih</span>
    </div>
    {error && <p className="rounded-2xl bg-rose-50 p-4 font-semibold text-rose-700">{error}</p>}
    <div className="overflow-hidden rounded-2xl border border-slate-200 bg-white"><div className="overflow-x-auto"><table className="w-full min-w-[900px] text-sm">
      <thead className="bg-slate-50 text-left text-xs uppercase text-slate-500"><tr><th className="w-14 p-4">Pilih</th><th className="p-4">Surat Jalan</th><th className="p-4">Penerima</th><th className="p-4">Toko / Gudang</th><th className="p-4">Status</th><th className="p-4"/></tr></thead>
      <tbody>{loading ? <tr><td colSpan={6} className="p-10 text-center"><Loader2 className="mx-auto h-6 w-6 animate-spin"/></td></tr> : filtered.length === 0 ? <tr><td colSpan={6} className="p-10 text-center text-slate-500">Belum ada Surat Jalan yang sesuai.</td></tr> : filtered.map((row) => <tr key={row.deliveryDocumentId} className="border-t">
        <td className="p-4"><input type="checkbox" checked={marked.has(row.deliveryDocumentId)} onChange={() => toggleRow(row.deliveryDocumentId)} disabled={bulkDownloading || (!marked.has(row.deliveryDocumentId) && markedRows.length >= MAX_BULK_DOCUMENTS)} aria-label={`Pilih ${row.deliveryNo}`} className="h-5 w-5 accent-blue-600"/></td>
        <td className="p-4"><strong>{row.deliveryNo}</strong><p className="text-xs text-slate-500">Invoice {row.invoiceNo} · {dateTime(row.scheduledAt ?? row.createdAt)}</p></td>
        <td className="p-4"><strong>{row.recipientName}</strong><p className="text-xs text-slate-500">{row.recipientPhone}</p></td>
        <td className="p-4">{row.storeName}<p className="text-xs text-slate-500">{row.warehouseName}</p></td>
        <td className="p-4"><span className={`rounded-full px-2.5 py-1 text-xs font-black ${statusClass(row.status)}`}>{statusLabel(row.status)}</span></td>
        <td className="p-4 text-right"><button onClick={() => void open(row)} className="inline-flex min-h-10 items-center gap-2 rounded-xl bg-slate-900 px-4 font-bold text-white"><Eye className="h-4 w-4"/>Detail</button></td>
      </tr>)}</tbody>
    </table></div></div>
    {selected && <Detail summary={selected} detail={detail} canManage={canManage} close={() => { setSelected(null); setDetail(null) }} print={() => void print()} download={() => void download()} act={setAction}/>}
    {selected && detail && action && <ActionDialog session={session} summary={selected} action={action} close={() => setAction(null)} complete={complete}/>}
  </section>
}

function Detail({ summary, detail, canManage, close, print, download, act }: {
  summary: DeliverySummary
  detail: JsonMap | null
  canManage: boolean
  close: () => void
  print: () => void
  download: () => void
  act: (value: 'DISPATCH' | 'DELIVER' | 'CANCEL') => void
}) {
  useEscapeClose(close)
  const lines = Array.isArray(detail?.lines) ? detail.lines as JsonMap[] : []
  return <div className="fixed inset-0 z-[75] overflow-y-auto bg-slate-950/65 p-4"><article className="mx-auto my-5 max-w-4xl rounded-3xl bg-white p-6"><div className="flex justify-between"><div><p className="text-xs font-black uppercase text-blue-700">Surat Jalan</p><h2 className="mt-2 text-2xl font-black">{summary.deliveryNo}</h2><p className="text-sm text-slate-500">{summary.recipientName} · {summary.deliveryAddress}</p></div><button onClick={close} className="rounded-xl bg-slate-100 p-2"><X className="h-5 w-5"/></button></div>{!detail ? <Loader2 className="mx-auto my-16 h-7 w-7 animate-spin"/> : <><div className="mt-5 overflow-x-auto rounded-2xl border"><table className="w-full min-w-[560px] text-sm"><thead className="bg-slate-50 text-left text-xs uppercase text-slate-500"><tr><th className="p-4">Produk</th><th className="p-4">UOM</th><th className="p-4 text-right">Qty</th></tr></thead><tbody>{lines.map((line, index) => <tr key={index} className="border-t"><td className="p-4"><strong>{String(line.productName ?? '-')}</strong><p className="text-xs text-slate-500">{String(line.sku ?? '')}</p></td><td className="p-4">{String(line.uomName ?? '-')}</td><td className="p-4 text-right">{String(line.quantity ?? 0)}</td></tr>)}</tbody></table></div><div className="mt-6 flex flex-wrap justify-end gap-3"><button onClick={download} className="inline-flex min-h-11 items-center gap-2 rounded-xl border border-blue-200 px-4 font-black text-blue-700"><Download className="h-4 w-4"/>Unduh PDF</button><button onClick={print} className="inline-flex min-h-11 items-center gap-2 rounded-xl border px-4 font-black"><FileText className="h-4 w-4"/>Print Surat Jalan</button>{canManage && summary.status === 'READY' && <><button onClick={() => act('CANCEL')} className="inline-flex min-h-11 items-center gap-2 rounded-xl border border-rose-200 px-4 font-black text-rose-700"><Ban className="h-4 w-4"/>Batalkan</button><button onClick={() => act('DISPATCH')} className="inline-flex min-h-11 items-center gap-2 rounded-xl bg-blue-600 px-4 font-black text-white"><Send className="h-4 w-4"/>Kirim</button></>}{canManage && summary.status === 'DISPATCHED' && <button onClick={() => act('DELIVER')} className="inline-flex min-h-11 items-center gap-2 rounded-xl bg-emerald-600 px-4 font-black text-white"><CheckCircle2 className="h-4 w-4"/>Tandai Terkirim</button>}</div></>}</article></div>
}

function ActionDialog({ session, summary, action, close, complete }: {
  session: Session
  summary: DeliverySummary
  action: 'DISPATCH' | 'DELIVER' | 'CANCEL'
  close: () => void
  complete: () => Promise<void>
}) {
  useEscapeClose(close)
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  async function submit() {
    setBusy(true)
    setError('')
    try {
      const response = await fetch(`/api/inventory/delivery-documents/${summary.salesId}`, {
        method: 'PATCH', headers: headers(session, true),
        body: JSON.stringify({ action, deliveryDocumentId: summary.deliveryDocumentId,
          masterVersion: summary.masterVersion, ...(action === 'CANCEL' ? { reason } : {}) }),
      })
      const result = await response.json() as { error?: string }
      if (!response.ok) throw new Error(friendly(result.error))
      await complete()
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Status gagal diperbarui.')
    } finally {
      setBusy(false)
    }
  }
  return <div className="fixed inset-0 z-[90] grid place-items-center bg-slate-950/70 p-4"><section className="w-full max-w-lg rounded-3xl bg-white p-7"><div className="flex justify-between"><h2 className="text-xl font-black">{action === 'DISPATCH' ? 'Kirim pesanan sekarang?' : action === 'DELIVER' ? 'Pesanan sudah diterima?' : 'Batalkan Surat Jalan?'}</h2><button onClick={close}><X className="h-5 w-5"/></button></div>{action === 'CANCEL' && <textarea rows={4} value={reason} onChange={(event) => setReason(event.target.value)} placeholder="Alasan pembatalan" className="mt-5 w-full rounded-xl border p-3"/>}{error && <p className="mt-4 rounded-xl bg-rose-50 p-3 text-rose-700">{error}</p>}<div className="mt-6 flex justify-end gap-3"><button onClick={close} className="min-h-11 rounded-xl border px-5 font-black">Kembali</button><button onClick={() => void submit()} disabled={busy || (action === 'CANCEL' && reason.trim().length < 3)} className="min-h-11 rounded-xl bg-blue-600 px-5 font-black text-white disabled:bg-slate-300">{busy ? 'Memproses...' : 'Konfirmasi'}</button></div></section></div>
}
