'use client'

import { useCallback, useEffect, useMemo, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import {
  Archive, Ban, CalendarRange, CheckCircle2, Download, Eye, FileText, Loader2,
  PackageCheck, RefreshCcw, Search, Send, X,
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
  recipientPhone: string | null
  deliveryAddress: string | null
  customerName: string
  storeName: string
  warehouseName: string
  fulfillmentMode: 'PICKUP' | 'DELIVERY'
  reservationId: string | null
  reservationStatus?: string
  dispatchVersion?: number
  totalReservedBaseQty?: number | string
  totalDispatchedBaseQty?: number | string
}
type DispatchLine = {
  id: string
  delivery_document_id: string
  line_no: number
  product_id: string
  product_sku_snapshot: string
  product_name_snapshot: string
  sale_uom_id: string
  sale_uom_name_snapshot: string
  quantity_uom: number | string
  quantity_base: number | string
  remaining_quantity_uom: number | string
}
type BulkStatusAction = 'DISPATCH' | 'DELIVER'
type BulkStatusResult = {
  deliveryDocumentId: string
  deliveryNo: string
  ok: boolean
  message: string
}

const MAX_BULK_DOCUMENTS = 50
const headers = (session: Session, json = false) => ({
  Authorization: `Bearer ${session.access_token}`,
  ...(json ? { 'Content-Type': 'application/json' } : {}),
})
const dateTime = (value?: string | null) => value
  ? new Date(value).toLocaleString('id-ID') : '-'
function statusLabel(status?: string, fulfillmentMode: 'PICKUP' | 'DELIVERY' = 'DELIVERY') {
  if (fulfillmentMode === 'PICKUP') {
    return ({ READY: 'Siap disiapkan', PARTIALLY_DISPATCHED: 'Disiapkan sebagian', DISPATCHED: 'Siap diserahkan', DELIVERED: 'Sudah diserahkan', CANCELED: 'Dibatalkan' } as Record<string, string>)[status ?? ''] ?? status ?? '-'
  }
  return ({ READY: 'Siap dikirim', PARTIALLY_DISPATCHED: 'Dikirim sebagian', DISPATCHED: 'Dalam perjalanan', DELIVERED: 'Terkirim', CANCELED: 'Dibatalkan' } as Record<string, string>)[status ?? ''] ?? status ?? '-'
}
function statusClass(status?: string) {
  if (status === 'DELIVERED') return 'bg-emerald-100 text-emerald-800'
  if (status === 'DISPATCHED') return 'bg-blue-100 text-blue-800'
  if (status === 'PARTIALLY_DISPATCHED') return 'bg-violet-100 text-violet-800'
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
    INVALID_DELIVERY_DATE_RANGE: 'Tanggal awal tidak boleh melewati tanggal akhir.',
    DELIVERY_DATE_FROM_INVALID: 'Tanggal awal tidak valid.',
    DELIVERY_DATE_TO_INVALID: 'Tanggal akhir tidak valid.',
    SALES_DELIVERY_NOT_DISPATCHABLE: 'Surat Jalan tidak berada pada status yang dapat dikirim.',
    SALES_ORDER_NOT_DISPATCHABLE: 'Order tidak berada pada status yang dapat dikirim.',
    DELIVERY_WAREHOUSE_SCOPE_DENIED: 'Akun ini tidak memiliki kewenangan pada gudang pengiriman.',
    DISPATCH_LINES_INVALID: 'Isi minimal satu jumlah pengiriman yang valid.',
    DISPATCH_QUANTITY_EXCEEDS_REMAINING: 'Jumlah kirim melebihi sisa Reservation.',
    RESERVATION_COMMERCIAL_LINEAGE_INVALID: 'Hubungan baris Order dan Reservation tidak konsisten. Hentikan Dispatch dan hubungi administrator.',
    DISPATCH_RESERVATION_QUANTITY_INVALID: 'Jumlah Dispatch tidak sesuai dengan sisa Reservation. Muat ulang dokumen.',
    BUNDLE_COMPONENT_PRICE_REFERENCE_INVALID: 'Referensi harga komponen Bundle belum valid untuk Dispatch.',
    FIFO_STOCK_CHANGED: 'Ketersediaan FIFO berubah setelah Order dikonfirmasi. Muat ulang stok dan periksa izin stok minus.',
    NEGATIVE_STOCK_PERMISSION_SNAPSHOT_MISSING: 'Snapshot izin stok minus tidak ditemukan. Periksa kembali izin user dan gudang.',
    NEGATIVE_STOCK_PROVISIONAL_COST_NOT_FOUND: 'Biaya sementara stok minus belum tersedia untuk salah satu Product.',
    STOCK_MOVEMENT_SNAPSHOT_INCOMPLETE: 'Snapshot UOM Stock Movement belum lengkap. Periksa master Product dan UOM.',
    DISPATCH_EMPTY: 'Tidak ada jumlah tersisa yang dapat dikirim.',
    DISPATCH_FINANCE_SOURCE_NOT_FOUND: 'Sumber Finance untuk Dispatch tidak ditemukan.',
    DISPATCH_FINANCE_ALLOCATION_INCOMPLETE: 'Alokasi stok Dispatch belum lengkap untuk pencatatan Finance.',
    DISPATCH_FINANCE_STOCK_RESULT_MISMATCH: 'Hasil stok dan sumber Finance Dispatch tidak cocok.',
    DISPATCH_FINANCE_COST_RECONCILIATION_FAILED: 'Rekonsiliasi biaya FIFO/stok minus Dispatch gagal.',
    DISPATCH_COMMERCIAL_LINEAGE_INVALID: 'Proporsi nilai komersial Dispatch tidak konsisten dengan Reservation.',
    DISPATCH_COMMERCIAL_AMOUNT_INVALID: 'Nilai komersial Dispatch tidak valid.',
    DISPATCH_SETTLEMENT_AMOUNT_INVALID: 'Nilai settlement Dispatch tidak valid.',
    DISPATCH_TRANSACTION_CATEGORY_MISSING_OR_AMBIGUOUS: 'Mapping kategori Finance SALE_DISPATCHED belum tepat satu.',
    DISPATCH_FINANCIAL_EFFECT_NOT_FOUND: 'Sumber pencatatan Finance Dispatch tidak ditemukan.',
    DISPATCH_EVENT_NOT_HOLD: 'Event Finance Dispatch tidak lagi berada pada status yang dapat diseimbangkan.',
    DISPATCH_SURCHARGE_RECONCILIATION_FAILED: 'Rekonsiliasi surcharge Dispatch gagal.',
    DISPATCH_EVENT_REBALANCE_FAILED: 'Penyeimbangan Event Finance Dispatch gagal.',
    PREDISPATCH_ADVANCE_EVENT_NOT_POSTED: 'Uang muka sebelum Dispatch belum diposting oleh Finance.',
    ODR_AUTOMATIC_POSTING_NOT_READY: 'Posting otomatis Finance belum siap untuk Dispatch ini.',
    IDEMPOTENCY_PAYLOAD_CONFLICT: 'Permintaan yang sama sudah dipakai dengan isi berbeda. Muat ulang.',
    DELIVERY_RECEIVER_REQUIRED: 'Nama penerima wajib diisi.',
    FULL_DISPATCH_REQUIRED: 'Seluruh barang harus selesai dikirim sebelum penerimaan dikonfirmasi.',
    CANCEL_LINKED_ORDER_FROM_POS_REQUIRED: 'Order terkonfirmasi harus dibatalkan dari kanal Order agar Reservation ikut dilepas.',
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
  const [dispatchLines, setDispatchLines] = useState<DispatchLine[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [search, setSearch] = useState('')
  const [status, setStatus] = useState('ALL')
  const [dateFrom, setDateFrom] = useState('')
  const [dateTo, setDateTo] = useState('')
  const [selected, setSelected] = useState<DeliverySummary | null>(null)
  const [detail, setDetail] = useState<JsonMap | null>(null)
  const [action, setAction] = useState<'DISPATCH' | 'DELIVER' | 'CANCEL' | null>(null)
  const [markedIds, setMarkedIds] = useState<string[]>([])
  const [bulkDownloading, setBulkDownloading] = useState(false)
  const [bulkProgress, setBulkProgress] = useState({ done: 0, total: 0 })
  const [bulkStatus, setBulkStatus] = useState<{
    action: BulkStatusAction
    rows: DeliverySummary[]
  } | null>(null)
  const [showLogoOnDocuments, setShowLogoOnDocuments] = useState(true)
  const [showStampOnDocuments, setShowStampOnDocuments] = useState(false)

  const load = useCallback(async () => {
    if (dateFrom && dateTo && dateFrom > dateTo) {
      setError(friendly('INVALID_DELIVERY_DATE_RANGE'))
      setLoading(false)
      return
    }
    setLoading(true)
    setError('')
    try {
      const query = new URLSearchParams()
      if (dateFrom) query.set('dateFrom', dateFrom)
      if (dateTo) query.set('dateTo', dateTo)
      const [response, brandingResponse] = await Promise.all([
        fetch(`/api/inventory/delivery-documents?${query}`, {
          headers: headers(session), cache: 'no-store',
        }),
        fetch('/api/platform/company-branding', {
          headers: headers(session), cache: 'no-store',
        }),
      ])
      const result = await response.json() as {
        data?: DeliverySummary[]
        dispatchLines?: DispatchLine[]
        dispatchWorkspaceVersion?: number
        error?: string
      }
      if (!response.ok) throw new Error(friendly(result.error))
      if (result.dispatchWorkspaceVersion !== 1) {
        throw new Error('DISPATCH_WORKSPACE_CONTRACT_MISMATCH')
      }
      setRows(result.data ?? [])
      setDispatchLines(result.dispatchLines ?? [])
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
  }, [dateFrom, dateTo, session])
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
  const bulkDispatchEligible = markedRows.length > 0 && markedRows.every((row) =>
    row.fulfillmentMode === 'DELIVERY' && row.status === 'READY')
  const bulkDeliverEligible = markedRows.length > 0 && markedRows.every((row) =>
    row.fulfillmentMode === 'DELIVERY' && row.status === 'DISPATCHED')

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
        {canManage && <button type="button" onClick={() => setBulkStatus({ action: 'DISPATCH', rows: markedRows })} disabled={!bulkDispatchEligible || bulkDownloading} title={bulkDispatchEligible ? 'Kirim seluruh sisa barang pada Surat Jalan terpilih' : 'Pilih hanya Surat Jalan Pengiriman berstatus Siap dikirim'} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-xl bg-sky-600 px-4 font-black text-white disabled:cursor-not-allowed disabled:bg-slate-300"><Send className="h-4 w-4"/>Kirim terpilih ({markedRows.length})</button>}
        {canManage && <button type="button" onClick={() => setBulkStatus({ action: 'DELIVER', rows: markedRows })} disabled={!bulkDeliverEligible || bulkDownloading} title={bulkDeliverEligible ? 'Tandai Surat Jalan terpilih sebagai terkirim' : 'Pilih hanya Surat Jalan Pengiriman berstatus Dalam perjalanan'} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-xl bg-emerald-600 px-4 font-black text-white disabled:cursor-not-allowed disabled:bg-slate-300"><PackageCheck className="h-4 w-4"/>Tandai terkirim ({markedRows.length})</button>}
        <button onClick={() => void bulkDownload()} disabled={!markedRows.length || bulkDownloading} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-xl bg-blue-600 px-4 font-black text-white disabled:bg-slate-300"><Archive className="h-4 w-4"/>{bulkDownloading ? `Menyiapkan ${bulkProgress.done}/${bulkProgress.total}` : `Unduh PDF Terpilih (${markedRows.length})`}</button>
        <button onClick={() => void load()} disabled={loading || bulkDownloading} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-xl border border-slate-200 px-4 font-bold"><RefreshCcw className={`h-4 w-4 ${loading ? 'animate-spin' : ''}`}/>Muat ulang</button>
      </div>
    </header>
    <div className="grid gap-3 rounded-2xl border border-slate-200 bg-white p-4 lg:grid-cols-[minmax(260px,1fr)_auto_auto_auto_auto] lg:items-end">
      <label className="relative"><Search className="absolute left-3 top-3.5 h-4 w-4 text-slate-400"/><input value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Cari SJ, Invoice, penerima, toko, atau gudang" className="min-h-11 w-full rounded-xl border border-slate-200 pl-10 pr-3"/></label>
      <select value={status} onChange={(event) => setStatus(event.target.value)} className="min-h-11 rounded-xl border border-slate-200 px-3"><option value="ALL">Semua status</option><option value="READY">Siap dikirim</option><option value="PARTIALLY_DISPATCHED">Dikirim sebagian</option><option value="DISPATCHED">Dalam perjalanan</option><option value="DELIVERED">Terkirim</option><option value="CANCELED">Dibatalkan</option></select>
      <label className="text-xs font-black text-slate-600">Tanggal awal<input type="date" value={dateFrom} max={dateTo || undefined} onChange={(event) => setDateFrom(event.target.value)} className="mt-1 block min-h-11 rounded-xl border border-slate-200 px-3 text-sm font-normal text-slate-900"/></label>
      <label className="text-xs font-black text-slate-600">Tanggal akhir<input type="date" value={dateTo} min={dateFrom || undefined} onChange={(event) => setDateTo(event.target.value)} className="mt-1 block min-h-11 rounded-xl border border-slate-200 px-3 text-sm font-normal text-slate-900"/></label>
      <button type="button" onClick={() => { setDateFrom(''); setDateTo('') }} disabled={!dateFrom && !dateTo} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-xl border border-slate-200 px-4 text-sm font-black text-slate-700 disabled:text-slate-300"><CalendarRange className="h-4 w-4"/>Semua tanggal</button>
    </div>
    <div className="flex flex-wrap items-center justify-between gap-3 rounded-2xl border border-blue-100 bg-blue-50 p-4 text-sm">
      <label className="inline-flex items-center gap-3 font-black text-blue-950"><input type="checkbox" checked={allFilteredMarked} onChange={toggleFiltered} disabled={!selectableFiltered.length || bulkDownloading} className="h-5 w-5 accent-blue-600"/>Pilih semua hasil filter{filtered.length > MAX_BULK_DOCUMENTS ? ` (maksimal ${MAX_BULK_DOCUMENTS})` : ''}</label>
      <span className="font-semibold text-blue-800">{markedRows.length} dokumen dipilih{canManage && markedRows.length > 0 && !bulkDispatchEligible && !bulkDeliverEligible ? ' · untuk bulk status, pilih dokumen Pengiriman dengan satu status yang sama' : ''}</span>
    </div>
    {error && <p className="rounded-2xl bg-rose-50 p-4 font-semibold text-rose-700">{error}</p>}
    <div className="overflow-hidden rounded-2xl border border-slate-200 bg-white"><div className="overflow-x-auto"><table className="w-full min-w-[900px] text-sm">
      <thead className="bg-slate-50 text-left text-xs uppercase text-slate-500"><tr><th className="w-14 p-4">Pilih</th><th className="p-4">Surat Jalan</th><th className="p-4">Penerima</th><th className="p-4">Toko / Gudang</th><th className="p-4">Status</th><th className="p-4"/></tr></thead>
      <tbody>{loading ? <tr><td colSpan={6} className="p-10 text-center"><Loader2 className="mx-auto h-6 w-6 animate-spin"/></td></tr> : filtered.length === 0 ? <tr><td colSpan={6} className="p-10 text-center text-slate-500">Belum ada Surat Jalan yang sesuai.</td></tr> : filtered.map((row) => <tr key={row.deliveryDocumentId} className="border-t">
        <td className="p-4"><input type="checkbox" checked={marked.has(row.deliveryDocumentId)} onChange={() => toggleRow(row.deliveryDocumentId)} disabled={bulkDownloading || (!marked.has(row.deliveryDocumentId) && markedRows.length >= MAX_BULK_DOCUMENTS)} aria-label={`Pilih ${row.deliveryNo}`} className="h-5 w-5 accent-blue-600"/></td>
        <td className="p-4"><strong>{row.deliveryNo}</strong><p className="text-xs text-slate-500">{row.fulfillmentMode === 'PICKUP' ? 'Ambil di toko' : 'Pengiriman'} · Invoice {row.invoiceNo} · {dateTime(row.scheduledAt ?? row.createdAt)}</p></td>
        <td className="p-4"><strong>{row.recipientName}</strong>{row.recipientPhone && <p className="text-xs text-slate-500">{row.recipientPhone}</p>}</td>
        <td className="p-4">{row.storeName}<p className="text-xs text-slate-500">{row.warehouseName}</p></td>
        <td className="p-4"><span className={`rounded-full px-2.5 py-1 text-xs font-black ${statusClass(row.status)}`}>{statusLabel(row.status, row.fulfillmentMode)}</span></td>
        <td className="p-4 text-right"><button onClick={() => void open(row)} className="inline-flex min-h-10 items-center gap-2 rounded-xl bg-slate-900 px-4 font-bold text-white"><Eye className="h-4 w-4"/>Detail</button></td>
      </tr>)}</tbody>
    </table></div></div>
    {selected && <Detail summary={selected} detail={detail} dispatchLines={dispatchLines.filter((line) => line.delivery_document_id === selected.deliveryDocumentId)} canManage={canManage} close={() => { setSelected(null); setDetail(null) }} print={() => void print()} download={() => void download()} act={setAction}/>}
    {selected && detail && action && <ActionDialog session={session} summary={selected} lines={dispatchLines.filter((line) => line.delivery_document_id === selected.deliveryDocumentId)} action={action} close={() => setAction(null)} complete={complete}/>}
    {bulkStatus && <BulkStatusDialog session={session} rows={bulkStatus.rows} dispatchLines={dispatchLines} action={bulkStatus.action} close={() => setBulkStatus(null)} refresh={load} notify={notify}/>}
  </section>
}

function BulkStatusDialog({ session, rows, dispatchLines, action, close, refresh, notify }: {
  session: Session
  rows: DeliverySummary[]
  dispatchLines: DispatchLine[]
  action: BulkStatusAction
  close: () => void
  refresh: () => Promise<void>
  notify: (message: string) => void
}) {
  const [busy, setBusy] = useState(false)
  const [progress, setProgress] = useState({ done: 0, total: rows.length })
  const [results, setResults] = useState<BulkStatusResult[]>([])
  const [idempotencyKeys] = useState(() => new Map(
    rows.map((row) => [row.deliveryDocumentId, crypto.randomUUID()]),
  ))
  const completed = results.length === rows.length
  const successCount = results.filter((result) => result.ok).length
  useEscapeClose(() => { if (!busy) close() })

  async function submit() {
    if (busy || completed) return
    setBusy(true)
    const nextResults: BulkStatusResult[] = []
    try {
      for (const row of rows) {
        try {
          const remainingLines = dispatchLines.filter((line) =>
            line.delivery_document_id === row.deliveryDocumentId &&
            Number(line.remaining_quantity_uom) > 0)
          if (action === 'DISPATCH' && row.reservationId && !remainingLines.length) {
            throw new Error('Tidak ada sisa Reservation yang dapat dikirim.')
          }
          const response = await fetch(`/api/inventory/delivery-documents/${row.salesId}`, {
            method: 'PATCH',
            headers: headers(session, true),
            body: JSON.stringify({
              action,
              deliveryDocumentId: row.deliveryDocumentId,
              masterVersion: row.masterVersion,
              ...(action === 'DISPATCH' && row.reservationId ? {
                idempotencyKey: idempotencyKeys.get(row.deliveryDocumentId),
                lines: remainingLines.map((line) => ({
                  deliveryLineId: line.id,
                  quantityUom: Number(line.remaining_quantity_uom),
                })),
              } : {}),
              ...(action === 'DELIVER' && row.reservationId
                ? { recipientName: row.recipientName.trim() } : {}),
            }),
          })
          const result = await response.json() as { error?: string }
          if (!response.ok) throw new Error(friendly(result.error))
          nextResults.push({
            deliveryDocumentId: row.deliveryDocumentId,
            deliveryNo: row.deliveryNo,
            ok: true,
            message: action === 'DISPATCH' ? 'Dalam perjalanan' : 'Terkirim',
          })
        } catch (caught) {
          nextResults.push({
            deliveryDocumentId: row.deliveryDocumentId,
            deliveryNo: row.deliveryNo,
            ok: false,
            message: caught instanceof Error ? caught.message : 'Operasi gagal.',
          })
        }
        setResults([...nextResults])
        setProgress({ done: nextResults.length, total: rows.length })
      }
      await refresh()
      const succeeded = nextResults.filter((result) => result.ok).length
      const failed = nextResults.length - succeeded
      notify(`${succeeded} Surat Jalan berhasil diperbarui${failed ? `; ${failed} gagal.` : '.'}`)
    } finally {
      setBusy(false)
    }
  }

  const title = action === 'DISPATCH'
    ? 'Kirim semua Surat Jalan terpilih?'
    : 'Tandai semua sebagai terkirim?'
  const description = action === 'DISPATCH'
    ? 'Seluruh sisa quantity akan di-dispatch satu per satu melalui runtime Reservation, FIFO, Movement, dan Finance canonical. Pengiriman sebagian tetap dilakukan dari detail Surat Jalan.'
    : 'Setiap Surat Jalan Dalam perjalanan akan ditandai Terkirim. Langkah ini tidak mengurangi stok untuk kedua kalinya.'

  return <div className="fixed inset-0 z-[90] overflow-y-auto bg-slate-950/70 p-4">
    <section className="mx-auto my-6 w-full max-w-3xl rounded-3xl bg-white p-7">
      <div className="flex justify-between gap-4"><div><h2 className="text-xl font-black">{title}</h2><p className="mt-2 max-w-2xl text-sm leading-6 text-slate-600">{description}</p></div><button type="button" onClick={close} disabled={busy} className="h-10 rounded-xl bg-slate-100 p-2 disabled:opacity-40"><X className="h-5 w-5"/></button></div>
      <div className="mt-5 max-h-80 space-y-2 overflow-y-auto rounded-2xl border border-slate-200 p-3">
        {rows.map((row) => {
          const result = results.find((item) => item.deliveryDocumentId === row.deliveryDocumentId)
          return <div key={row.deliveryDocumentId} className="flex items-start justify-between gap-4 rounded-xl bg-slate-50 p-3 text-sm"><div><strong>{row.deliveryNo}</strong><p className="mt-1 text-xs text-slate-500">{row.recipientName} · {row.warehouseName}</p></div>{result ? <span className={`max-w-xs text-right text-xs font-bold ${result.ok ? 'text-emerald-700' : 'text-rose-700'}`}>{result.ok ? 'Berhasil · ' : 'Gagal · '}{result.message}</span> : <span className="text-xs font-semibold text-slate-400">Menunggu</span>}</div>
        })}
      </div>
      {busy && <p className="mt-4 rounded-xl bg-blue-50 p-3 text-sm font-bold text-blue-800">Memproses {progress.done}/{progress.total}. Jangan tutup halaman.</p>}
      {completed && <p className={`mt-4 rounded-xl p-3 text-sm font-bold ${successCount === rows.length ? 'bg-emerald-50 text-emerald-800' : 'bg-amber-50 text-amber-900'}`}>{successCount} berhasil, {rows.length - successCount} gagal. Dokumen yang gagal tidak diubah; periksa pesannya lalu proses dari detail.</p>}
      <div className="mt-6 flex justify-end gap-3"><button type="button" onClick={close} disabled={busy} className="min-h-11 rounded-xl border px-5 font-black disabled:opacity-40">{completed ? 'Tutup' : 'Kembali'}</button>{!completed && <button type="button" onClick={() => void submit()} disabled={busy || !rows.length} className={`min-h-11 rounded-xl px-5 font-black text-white disabled:bg-slate-300 ${action === 'DISPATCH' ? 'bg-sky-600' : 'bg-emerald-600'}`}>{busy ? `Memproses ${progress.done}/${progress.total}` : `Konfirmasi ${rows.length} dokumen`}</button>}</div>
    </section>
  </div>
}

function Detail({ summary, detail, dispatchLines, canManage, close, print, download, act }: {
  summary: DeliverySummary
  detail: JsonMap | null
  dispatchLines: DispatchLine[]
  canManage: boolean
  close: () => void
  print: () => void
  download: () => void
  act: (value: 'DISPATCH' | 'DELIVER' | 'CANCEL') => void
}) {
  useEscapeClose(close)
  const lines = Array.isArray(detail?.lines) ? detail.lines as JsonMap[] : []
  return <div className="fixed inset-0 z-[75] overflow-y-auto bg-slate-950/65 p-4">
    <article className="mx-auto my-5 max-w-4xl rounded-3xl bg-white p-6">
      <div className="flex justify-between">
        <div>
          <p className="text-xs font-black uppercase text-blue-700">Surat Jalan · {summary.fulfillmentMode === 'PICKUP' ? 'Ambil di toko' : 'Pengiriman'}</p>
          <h2 className="mt-2 text-2xl font-black">{summary.deliveryNo}</h2>
          <p className="text-sm text-slate-500">{summary.recipientName}{summary.deliveryAddress ? ` · ${summary.deliveryAddress}` : ''}</p>
        </div>
        <button onClick={close} className="rounded-xl bg-slate-100 p-2"><X className="h-5 w-5"/></button>
      </div>
      {!detail ? <Loader2 className="mx-auto my-16 h-7 w-7 animate-spin"/> : <>
        {summary.reservationId && <div className="mt-5 grid gap-3 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm sm:grid-cols-3">
          <div><p className="text-xs font-bold uppercase text-amber-700">Reserved</p><p className="mt-1 font-black">{String(summary.totalReservedBaseQty ?? 0)} base qty</p></div>
          <div><p className="text-xs font-bold uppercase text-amber-700">Sudah dispatch</p><p className="mt-1 font-black">{String(summary.totalDispatchedBaseQty ?? 0)} base qty</p></div>
          <div><p className="text-xs font-bold uppercase text-amber-700">Baris tersisa</p><p className="mt-1 font-black">{dispatchLines.filter((line) => Number(line.remaining_quantity_uom) > 0).length}</p></div>
        </div>}
        <div className="mt-5 overflow-x-auto rounded-2xl border">
          <table className="w-full min-w-[560px] text-sm">
            <thead className="bg-slate-50 text-left text-xs uppercase text-slate-500"><tr><th className="p-4">Produk</th><th className="p-4">UOM</th><th className="p-4 text-right">Qty</th></tr></thead>
            <tbody>{lines.map((line, index) => <tr key={index} className="border-t"><td className="p-4"><strong>{String(line.productName ?? '-')}</strong><p className="text-xs text-slate-500">{String(line.sku ?? '')}</p></td><td className="p-4">{String(line.uomName ?? '-')}</td><td className="p-4 text-right">{String(line.quantity ?? 0)}</td></tr>)}</tbody>
          </table>
        </div>
        <div className="mt-6 flex flex-wrap justify-end gap-3">
          <button onClick={download} className="inline-flex min-h-11 items-center gap-2 rounded-xl border border-blue-200 px-4 font-black text-blue-700"><Download className="h-4 w-4"/>Unduh PDF</button>
          <button onClick={print} className="inline-flex min-h-11 items-center gap-2 rounded-xl border px-4 font-black"><FileText className="h-4 w-4"/>Print Surat Jalan</button>
          {canManage && summary.status === 'READY' && !summary.reservationId && <>
            <button onClick={() => act('CANCEL')} className="inline-flex min-h-11 items-center gap-2 rounded-xl border border-rose-200 px-4 font-black text-rose-700"><Ban className="h-4 w-4"/>Batalkan</button>
            {summary.fulfillmentMode === 'PICKUP'
              ? <button onClick={() => act('DELIVER')} className="inline-flex min-h-11 items-center gap-2 rounded-xl bg-emerald-600 px-4 font-black text-white"><CheckCircle2 className="h-4 w-4"/>Sudah diserahkan</button>
              : <button onClick={() => act('DISPATCH')} className="inline-flex min-h-11 items-center gap-2 rounded-xl bg-blue-600 px-4 font-black text-white"><Send className="h-4 w-4"/>Kirim</button>}
          </>}
          {canManage && summary.reservationId && ['READY', 'PARTIALLY_DISPATCHED'].includes(summary.status) && <button onClick={() => act('DISPATCH')} disabled={!dispatchLines.some((line) => Number(line.remaining_quantity_uom) > 0)} className="inline-flex min-h-11 items-center gap-2 rounded-xl bg-blue-600 px-4 font-black text-white disabled:bg-slate-300"><Send className="h-4 w-4"/>{summary.fulfillmentMode === 'PICKUP' ? 'Keluarkan barang' : summary.status === 'PARTIALLY_DISPATCHED' ? 'Lanjut kirim' : 'Kirim barang'}</button>}
          {canManage && summary.status === 'DISPATCHED' && <button onClick={() => act('DELIVER')} className="inline-flex min-h-11 items-center gap-2 rounded-xl bg-emerald-600 px-4 font-black text-white"><CheckCircle2 className="h-4 w-4"/>{summary.fulfillmentMode === 'PICKUP' ? 'Sudah diserahkan' : 'Tandai diterima'}</button>}
        </div>
      </>}
    </article>
  </div>
}

function ActionDialog({ session, summary, lines, action, close, complete }: {
  session: Session
  summary: DeliverySummary
  lines: DispatchLine[]
  action: 'DISPATCH' | 'DELIVER' | 'CANCEL'
  close: () => void
  complete: () => Promise<void>
}) {
  useEscapeClose(close)
  const [reason, setReason] = useState('')
  const [recipientName, setRecipientName] = useState(summary.recipientName ?? '')
  const [idempotencyKey] = useState(() => crypto.randomUUID())
  const [quantities, setQuantities] = useState<Record<string, string>>(() =>
    Object.fromEntries(lines.map((line) => [
      line.id, String(line.remaining_quantity_uom),
    ])),
  )
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const activeLines = lines.filter((line) => Number(line.remaining_quantity_uom) > 0)
  const dispatchInvalid = action === 'DISPATCH' && Boolean(summary.reservationId) && (
    !activeLines.some((line) => Number(quantities[line.id]) > 0) ||
    activeLines.some((line) => {
      const quantity = Number(quantities[line.id])
      return !Number.isFinite(quantity) || quantity < 0 ||
        quantity > Number(line.remaining_quantity_uom) + 0.000001
    })
  )
  async function submit() {
    setBusy(true)
    setError('')
    try {
      const response = await fetch(`/api/inventory/delivery-documents/${summary.salesId}`, {
        method: 'PATCH', headers: headers(session, true),
        body: JSON.stringify({
          action,
          deliveryDocumentId: summary.deliveryDocumentId,
          masterVersion: summary.masterVersion,
          ...(reason.trim() ? { reason: reason.trim() } : {}),
          ...(action === 'DISPATCH' ? {
            idempotencyKey,
            lines: activeLines
              .map((line) => ({
                deliveryLineId: line.id,
                quantityUom: Number(quantities[line.id]),
              }))
              .filter((line) => line.quantityUom > 0),
          } : {}),
          ...(action === 'DELIVER' && summary.reservationId
            ? { recipientName: recipientName.trim() } : {}),
        }),
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
  const title = action === 'DISPATCH' ? 'Kirim pesanan sekarang?'
    : action === 'DELIVER' && summary.fulfillmentMode === 'PICKUP'
      ? 'Barang sudah diserahkan?'
      : action === 'DELIVER' ? 'Pesanan sudah diterima?' : 'Batalkan Surat Jalan?'
  return <div className="fixed inset-0 z-[90] overflow-y-auto bg-slate-950/70 p-4"><section className="mx-auto my-6 w-full max-w-3xl rounded-3xl bg-white p-7"><div className="flex justify-between gap-4"><div><h2 className="text-xl font-black">{title}</h2><p className="mt-1 text-sm text-slate-500">{summary.deliveryNo} · versi {summary.masterVersion}</p></div><button onClick={close}><X className="h-5 w-5"/></button></div>
    {action === 'DISPATCH' && summary.reservationId && <div className="mt-5 space-y-3"><p className="text-sm font-bold text-slate-700">Isi jumlah yang dikirim sekarang. Isi 0 untuk Product yang belum ikut dikirim.</p>{activeLines.map((line) => <label key={line.id} className="grid gap-3 rounded-2xl border border-slate-200 p-4 sm:grid-cols-[1fr_180px] sm:items-center"><span><strong>{line.product_name_snapshot}</strong><span className="mt-1 block text-xs text-slate-500">{line.product_sku_snapshot} · sisa {String(line.remaining_quantity_uom)} {line.sale_uom_name_snapshot}</span></span><input type="number" min="0" max={Number(line.remaining_quantity_uom)} step="any" value={quantities[line.id] ?? ''} onChange={(event) => setQuantities((current) => ({ ...current, [line.id]: event.target.value }))} className="min-h-11 rounded-xl border border-slate-300 px-3 text-right font-black"/></label>)}</div>}
    {action === 'DELIVER' && summary.reservationId && <label className="mt-5 block text-sm font-bold">Nama penerima<input value={recipientName} onChange={(event) => setRecipientName(event.target.value)} maxLength={200} className="mt-2 min-h-11 w-full rounded-xl border border-slate-300 px-3"/></label>}
    <label className="mt-5 block text-sm font-bold">{action === 'CANCEL' ? 'Alasan pembatalan' : 'Catatan (opsional)'}<textarea rows={3} value={reason} onChange={(event) => setReason(event.target.value)} maxLength={500} className="mt-2 w-full rounded-xl border border-slate-300 p-3"/></label>
    {error && <p className="mt-4 rounded-xl bg-rose-50 p-3 text-rose-700">{error}</p>}<div className="mt-6 flex justify-end gap-3"><button onClick={close} className="min-h-11 rounded-xl border px-5 font-black">Kembali</button><button onClick={() => void submit()} disabled={busy || dispatchInvalid || (action === 'CANCEL' && reason.trim().length < 3) || (action === 'DELIVER' && Boolean(summary.reservationId) && !recipientName.trim())} className="min-h-11 rounded-xl bg-blue-600 px-5 font-black text-white disabled:bg-slate-300">{busy ? 'Memproses...' : 'Konfirmasi'}</button></div></section></div>
}
