'use client'

import { useCallback, useEffect, useMemo, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import { ArrowRight, Ban, Clock3, Download, Eye, History, Loader2, Printer, RefreshCcw, Search, TriangleAlert, X } from 'lucide-react'
import { useEscapeClose } from '@/lib/use-escape-close'
import { downloadSalesInvoicePdf, printSalesInvoiceDocument } from '@/lib/sales-document-print'

type JsonMap = Record<string, unknown>
type RevisionLink = {
  status: 'PENDING' | 'APPLIED' | 'ABANDONED'
  reason: string
  sourceSalesId: string
  sourceOrderNo: string
  sourceInvoiceNo: string
  replacementSalesId: string
  replacementOrderNo: string
  replacementInvoiceNo: string
  startedByName?: string | null
  startedAt?: string | null
  appliedByName?: string | null
  appliedAt?: string | null
  abandonedByName?: string | null
  abandonedAt?: string | null
  abandonedReason?: string | null
  updatedAt?: string | null
}
type DocumentActivity = {
  salesId: string
  createdAt?: string | null
  createdByName?: string | null
  updatedAt?: string | null
  confirmedAt?: string | null
  confirmedByName?: string | null
  canceledAt?: string | null
  canceledByName?: string | null
}
type InvoiceSummary = {
  salesId: string; invoiceSnapshotId: string; invoiceNo: string
  snapshotProvenance: string; postedAt: string; total: number
  fulfillmentMode: 'PICKUP' | 'DELIVERY'; sourceChannel: string
  customerName: string; storeName: string
  invoiceStatus: 'ACTIVE' | 'CANCELED'; orderRuntimeStatus: string
  masterVersion: number; canceledAt?: string | null
  cancelReason?: string | null; canceledByName?: string | null; canCancel?: boolean
  revision?: RevisionLink | null
  activity?: DocumentActivity | null
}
type DetailPayload = { invoice?: JsonMap; error?: string }

function headers(session: Session, json = false) { return { Authorization: `Bearer ${session.access_token}`, ...(json ? { 'Content-Type': 'application/json' } : {}) } }
function money(value: number) { return new Intl.NumberFormat('id-ID', { style: 'currency', currency: 'IDR', maximumFractionDigits: 0 }).format(value || 0) }
function dateTime(value?: string | null) { return value ? new Date(value).toLocaleString('id-ID') : '-' }
function friendly(code?: string) { return ({
  SALES_DOCUMENT_NOT_FOUND: 'Invoice tidak ditemukan atau tidak dapat diakses.',
  SALES_INVOICE_NOT_FOUND: 'Invoice final belum tersedia.',
  SALES_ORDER_FINAL: 'Order sudah final atau sudah tidak dapat dibatalkan.',
  SALES_ORDER_DISPATCH_STARTED: 'Barang sudah mulai dikirim. Gunakan alur koreksi/return.',
  SALES_ORDER_VERIFIED_PAYMENT_REVERSAL_REQUIRED: 'Pembayaran sudah diverifikasi. Finance wajib menyelesaikan reversal sebelum Order dapat dibatalkan.',
  SALES_ORDER_CASH_REFUND_REQUIRES_OPEN_SESSION: 'Kas sudah masuk ke sesi yang ditutup. Pembatalan memerlukan proses refund/reversal kas.',
  SALES_ORDER_CASH_REFUND_REQUIRES_CURRENT_OPEN_SESSION: 'Buka sesi kas pada toko Order ini untuk mencatat pengembalian Cash, lalu coba batalkan lagi.',
  SALES_ORDER_REVISION_PENDING: 'Order memiliki Draft revisi aktif. Batalkan Draft revisi terlebih dahulu.',
  MASTER_VERSION_CONFLICT: 'Data Order sudah berubah. Muat ulang lalu coba kembali.',
  CUSTOM_PERMISSION_DENIED: 'Anda tidak diizinkan membatalkan Order ini.',
  FORBIDDEN: 'Anda tidak diizinkan mengakses Invoice.',
  INVALID_API_RESPONSE: 'Layanan Invoice mengembalikan respons yang tidak valid. Muat ulang aplikasi lalu coba lagi.',
} as Record<string, string>)[code ?? ''] ?? code ?? 'Operasi Invoice gagal.' }
async function readApiJson<T extends { error?: string }>(response: Response): Promise<T> {
  if (!(response.headers.get('content-type') ?? '').toLowerCase().includes('application/json')) throw new Error(friendly('INVALID_API_RESPONSE'))
  return await response.json() as T
}

export function SalesDocumentView({ session, companyId, notify }: { session: Session; companyId: string; notify: (message: string) => void }) {
  const [documents, setDocuments] = useState<InvoiceSummary[]>([])
  const [loading, setLoading] = useState(true); const [error, setError] = useState('')
  const [search, setSearch] = useState(''); const [statusFilter, setStatusFilter] = useState<'ALL' | 'ACTIVE' | 'CANCELED'>('ALL')
  const [selected, setSelected] = useState<InvoiceSummary | null>(null)
  const [detail, setDetail] = useState<DetailPayload | null>(null); const [detailLoading, setDetailLoading] = useState(false)
  const [cancelBusy, setCancelBusy] = useState(false)
  const [showLogoOnDocuments, setShowLogoOnDocuments] = useState(true)
  const [showStampOnDocuments, setShowStampOnDocuments] = useState(false)
  const [showBankAccountOnInvoice, setShowBankAccountOnInvoice] = useState(false)

  const load = useCallback(async () => {
    setLoading(true); setError('')
    try {
      const [response, brandingResponse] = await Promise.all([
        fetch('/api/sales/documents', { headers: headers(session), cache: 'no-store' }),
        fetch('/api/platform/company-branding', { headers: headers(session), cache: 'no-store' }),
      ])
      const result = await readApiJson<{ data?: InvoiceSummary[]; error?: string }>(response)
      if (!response.ok) throw new Error(friendly(result.error)); setDocuments(result.data ?? [])
      if (brandingResponse.ok) {
        const branding = await brandingResponse.json() as { data?: { showLogoOnDocuments?: boolean; showStampOnDocuments?: boolean; showBankAccountOnInvoice?: boolean } }
        setShowLogoOnDocuments(branding.data?.showLogoOnDocuments ?? true); setShowStampOnDocuments(branding.data?.showStampOnDocuments ?? false); setShowBankAccountOnInvoice(branding.data?.showBankAccountOnInvoice ?? false)
      }
    } catch (caught) { setError(caught instanceof Error ? caught.message : 'Invoice gagal dimuat.') }
    finally { setLoading(false) }
  }, [session])
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- active Company owns rows
    void load()
  }, [load, companyId])

  const filtered = useMemo(() => documents.filter((document) => {
    const keyword = search.trim().toLowerCase()
    return (statusFilter === 'ALL' || document.invoiceStatus === statusFilter) && (!keyword || [document.invoiceNo, document.customerName, document.storeName].some((value) => value?.toLowerCase().includes(keyword)))
  }), [documents, search, statusFilter])

  async function openDetail(document: InvoiceSummary) {
    setSelected(document); setDetail(null); setDetailLoading(true); setError('')
    try {
      const response = await fetch(`/api/sales/documents?salesId=${encodeURIComponent(document.salesId)}`, { headers: headers(session), cache: 'no-store' })
      const result = await readApiJson<DetailPayload>(response)
      if (!response.ok) throw new Error(friendly(result.error)); setDetail(result)
    } catch (caught) { setError(caught instanceof Error ? caught.message : 'Detail Invoice gagal dimuat.'); setSelected(null) }
    finally { setDetailLoading(false) }
  }
  async function recordPrint() {
    if (!selected || !detail?.invoice) return
    const response = await fetch('/api/sales/documents', { method: 'POST', headers: headers(session, true), body: JSON.stringify({ salesId: selected.salesId, documentType: 'SALES_INVOICE', documentId: detail.invoice.invoiceSnapshotId }) })
    const result = await readApiJson<{ error?: string }>(response); if (!response.ok) throw new Error(friendly(result.error))
  }
  async function printInvoice() {
    if (!detail?.invoice) return
    try { printSalesInvoiceDocument(detail.invoice, showLogoOnDocuments, showStampOnDocuments, showBankAccountOnInvoice); await recordPrint(); notify('Invoice dibuka di tab baru.') }
    catch (caught) { setError(caught instanceof Error ? caught.message : 'Invoice gagal dicetak.') }
  }
  async function downloadInvoice() {
    if (!selected || !detail?.invoice) return
    try { await downloadSalesInvoicePdf(detail.invoice, selected.customerName, showLogoOnDocuments, showStampOnDocuments, showBankAccountOnInvoice); await recordPrint(); notify('Invoice berhasil diunduh.') }
    catch (caught) { setError(caught instanceof Error ? caught.message : 'Invoice gagal diunduh.') }
  }
  async function cancelOrder(reason: string) {
    if (!selected) return; setCancelBusy(true); setError('')
    try {
      const response = await fetch('/api/sales/documents', { method: 'POST', headers: headers(session, true), body: JSON.stringify({ action: 'CANCEL', salesId: selected.salesId, masterVersion: Number(detail?.invoice?.masterVersion ?? selected.masterVersion), idempotencyKey: crypto.randomUUID(), reason }) })
      const result = await readApiJson<{ error?: string }>(response); if (!response.ok) throw new Error(friendly(result.error))
      setSelected(null); setDetail(null); await load(); notify('Order dibatalkan. Reservasi, Surat Jalan, dan status Invoice sudah disinkronkan.')
    } catch (caught) { setError(caught instanceof Error ? caught.message : 'Order gagal dibatalkan.') }
    finally { setCancelBusy(false) }
  }
  function openRelatedInvoice(salesId: string) {
    const related = documents.find((document) => document.salesId === salesId)
    if (!related) {
      setError('Nomor Invoice terkait tersedia, tetapi dokumennya berada di luar daftar terbaru. Gunakan kolom pencarian untuk membukanya.')
      return
    }
    void openDetail(related)
  }

  return <section className="space-y-5">
    <header className="flex flex-col gap-4 rounded-3xl border border-slate-200 bg-white p-6 shadow-sm lg:flex-row lg:items-center lg:justify-between"><div><p className="text-xs font-black uppercase tracking-[.2em] text-emerald-700">Sales</p><h1 className="mt-2 text-2xl font-black text-slate-950">Invoice Penjualan</h1><p className="mt-1 text-sm text-slate-500">Snapshot transaksi dan status Order yang dapat dicetak ulang.</p></div><button onClick={() => void load()} disabled={loading} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-xl border border-slate-200 px-4 font-bold text-slate-700"><RefreshCcw className={`h-4 w-4 ${loading ? 'animate-spin' : ''}`}/>Muat ulang</button></header>
    <div className="grid gap-3 rounded-2xl border border-slate-200 bg-white p-4 md:grid-cols-[1fr_210px]"><label className="relative block"><Search className="absolute left-3 top-3.5 h-4 w-4 text-slate-400"/><input value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Cari nomor Invoice, customer, atau toko" className="min-h-11 w-full rounded-xl border border-slate-200 pl-10 pr-3 outline-none focus:border-emerald-500"/></label><select value={statusFilter} onChange={(event) => setStatusFilter(event.target.value as typeof statusFilter)} className="min-h-11 rounded-xl border border-slate-200 bg-white px-3 font-semibold"><option value="ALL">Semua status</option><option value="ACTIVE">Aktif</option><option value="CANCELED">Dibatalkan</option></select></div>
    {error && <p className="rounded-2xl bg-rose-50 p-4 font-semibold text-rose-700">{error}</p>}
    <div className="overflow-hidden rounded-2xl border border-slate-200 bg-white"><div className="overflow-x-auto"><table className="w-full min-w-[820px] text-sm"><thead className="bg-slate-50 text-left text-xs uppercase text-slate-500"><tr><th className="p-4">Invoice</th><th className="p-4">Status</th><th className="p-4">Customer / Toko</th><th className="p-4">Pemenuhan</th><th className="p-4 text-right">Total</th><th className="p-4"/></tr></thead><tbody>{loading ? <tr><td colSpan={6} className="p-10 text-center text-slate-500"><Loader2 className="mx-auto mb-2 h-6 w-6 animate-spin"/>Memuat Invoice...</td></tr> : filtered.length === 0 ? <tr><td colSpan={6} className="p-10 text-center text-slate-500">Belum ada Invoice yang sesuai.</td></tr> : filtered.map((document) => <tr key={document.salesId} className={`border-t border-slate-100 ${document.invoiceStatus === 'CANCELED' ? 'bg-rose-50/40' : ''}`}><td className="p-4"><strong>{document.invoiceNo}</strong><p className="mt-1 text-xs text-slate-500">{dateTime(document.postedAt)} · {document.sourceChannel}</p><p className="mt-1 inline-flex items-center gap-1 text-xs text-slate-500"><Clock3 className="h-3.5 w-3.5"/>Terakhir diperbarui {dateTime(document.activity?.updatedAt ?? document.postedAt)}</p></td><td className="p-4"><span className={`inline-flex rounded-full px-3 py-1 text-xs font-black ${document.invoiceStatus === 'CANCELED' ? 'bg-rose-100 text-rose-700' : 'bg-emerald-100 text-emerald-700'}`}>{document.invoiceStatus === 'CANCELED' ? 'Dibatalkan' : 'Aktif'}</span></td><td className="p-4"><strong>{document.customerName}</strong><p className="text-xs text-slate-500">{document.storeName}</p></td><td className="p-4">{document.fulfillmentMode === 'DELIVERY' ? 'Dikirim' : 'Ambil sendiri'}</td><td className="p-4 text-right font-black">{money(document.total)}</td><td className="p-4 text-right"><button onClick={() => void openDetail(document)} className="inline-flex min-h-10 items-center gap-2 rounded-xl bg-slate-900 px-4 font-bold text-white"><Eye className="h-4 w-4"/>Detail</button></td></tr>)}</tbody></table></div></div>
    {selected && <InvoiceDetail summary={selected} payload={detail}
      loading={detailLoading} close={() => { setSelected(null); setDetail(null) }}
      print={() => void printInvoice()} download={() => void downloadInvoice()}
      cancel={(reason) => void cancelOrder(reason)} cancelBusy={cancelBusy}
      openRelated={openRelatedInvoice}
      relatedSalesIds={new Set(documents.map((document) => document.salesId))}/>}
  </section>
}

function InvoiceDetail({ summary, payload, loading, close, print, download, cancel, cancelBusy, openRelated, relatedSalesIds }: { summary: InvoiceSummary; payload: DetailPayload | null; loading: boolean; close: () => void; print: () => void; download: () => void; cancel: (reason: string) => void; cancelBusy: boolean; openRelated: (salesId: string) => void; relatedSalesIds: Set<string> }) {
  useEscapeClose(close); const [cancelOpen, setCancelOpen] = useState(false); const [cancelReason, setCancelReason] = useState(''); const [historyOpen, setHistoryOpen] = useState(false)
  const invoice = payload?.invoice ?? {}; const snapshot = (invoice.snapshot ?? {}) as JsonMap
  const lines = Array.isArray(snapshot.lines) ? snapshot.lines as JsonMap[] : []
  const canceled = String(invoice.invoiceStatus ?? summary.invoiceStatus) === 'CANCELED'; const canCancel = Boolean(invoice.canCancel ?? summary.canCancel)
  const revision = (invoice.revision ?? summary.revision ?? null) as RevisionLink | null
  const activity = (invoice.activity ?? summary.activity ?? null) as DocumentActivity | null
  const isRevisionSource = revision?.sourceSalesId === summary.salesId
  const relatedSalesId = isRevisionSource ? revision?.replacementSalesId : revision?.sourceSalesId
  const relatedInvoiceNo = isRevisionSource ? revision?.replacementInvoiceNo : revision?.sourceInvoiceNo
  const timeline = [
    { label: 'Order dibuat', at: activity?.createdAt, actor: activity?.createdByName },
    { label: 'Order dikonfirmasi', at: activity?.confirmedAt, actor: activity?.confirmedByName },
    ...(revision ? [
      { label: 'Revisi dimulai', at: revision.startedAt, actor: revision.startedByName },
      { label: 'Revisi diterapkan', at: revision.appliedAt, actor: revision.appliedByName },
      { label: 'Draft revisi dibatalkan', at: revision.abandonedAt, actor: revision.abandonedByName, detail: revision.abandonedReason },
    ] : []),
    { label: 'Order dibatalkan', at: activity?.canceledAt ?? summary.canceledAt,
      actor: activity?.canceledByName ?? summary.canceledByName,
      detail: summary.cancelReason ?? null },
  ].filter((item) => item.at).sort((left, right) =>
    new Date(String(left.at)).getTime() - new Date(String(right.at)).getTime())
  return <div className="fixed inset-0 z-[75] overflow-y-auto bg-slate-950/65 p-4"><article className="relative mx-auto my-5 max-w-5xl rounded-3xl bg-white p-6 shadow-2xl">
    <div className="flex items-start justify-between gap-4"><div><div className="flex flex-wrap items-center gap-2"><p className="text-xs font-black uppercase tracking-wider text-emerald-700">Invoice</p><span className={`rounded-full px-2.5 py-1 text-[11px] font-black uppercase ${canceled ? 'bg-rose-100 text-rose-700' : 'bg-emerald-100 text-emerald-700'}`}>{canceled ? 'Dibatalkan' : 'Aktif'}</span></div><h2 className="mt-2 text-2xl font-black">{summary.invoiceNo}</h2><p className="mt-1 text-sm text-slate-500">{summary.customerName} · {summary.storeName} · {dateTime(summary.postedAt)}</p></div><div className="flex shrink-0 items-center gap-2">{activity && <button type="button" onClick={() => setHistoryOpen(true)} className="inline-flex min-h-10 items-center gap-2 rounded-xl border border-slate-200 px-3 text-sm font-bold text-slate-700 hover:bg-slate-50"><History className="h-4 w-4"/><span className="hidden sm:inline">Riwayat</span></button>}<button onClick={close} className="rounded-xl bg-slate-100 p-2" aria-label="Tutup"><X className="h-5 w-5"/></button></div></div>
    {revision?.status === 'APPLIED' && <div className="mt-4 flex min-h-11 flex-wrap items-center gap-x-2 gap-y-1 rounded-xl border border-blue-200 bg-blue-50 px-4 py-2.5 text-sm text-blue-900"><span>{isRevisionSource ? 'Digantikan oleh' : 'Revisi dari'}</span>{relatedSalesId && relatedSalesIds.has(relatedSalesId) ? <button type="button" onClick={() => openRelated(relatedSalesId)} className="inline-flex items-center gap-1 font-black underline decoration-blue-300 underline-offset-4 hover:text-blue-700">{relatedInvoiceNo}<ArrowRight className="h-4 w-4"/></button> : <strong>{relatedInvoiceNo}</strong>}</div>}
    {revision?.status === 'PENDING' && <div className="mt-4 rounded-xl border border-amber-200 bg-amber-50 px-4 py-2.5 text-sm text-amber-900"><strong>Draft revisi sedang disiapkan.</strong> Order asli tetap aktif sampai revisi dikonfirmasi.</div>}
    {loading ? <div className="p-16 text-center"><Loader2 className="mx-auto h-7 w-7 animate-spin"/></div> : payload && <><div className="mt-5 overflow-x-auto rounded-2xl border border-slate-200"><table className="w-full min-w-[680px] text-sm"><thead className="bg-slate-50 text-left text-xs uppercase text-slate-500"><tr><th className="p-4">Produk</th><th className="p-4">UOM</th><th className="p-4 text-right">Qty</th><th className="p-4 text-right">Harga</th><th className="p-4 text-right">Total</th></tr></thead><tbody>{lines.map((line, index) => <tr key={`${String(line.lineKey)}-${index}`} className="border-t"><td className="p-4"><strong>{String(line.productName ?? '-')}</strong><p className="text-xs text-slate-500">{String(line.sku ?? '')}</p></td><td className="p-4">{String(line.uomName ?? '-')}</td><td className="p-4 text-right">{String(line.quantity ?? 0)}</td><td className="p-4 text-right">{money(Number(line.unitPrice))}</td><td className="p-4 text-right font-black">{money(Number(line.lineTotal))}</td></tr>)}</tbody></table></div><div className="mt-6 flex flex-wrap justify-end gap-3">{canCancel && <button onClick={() => setCancelOpen(true)} className="inline-flex min-h-11 items-center gap-2 rounded-xl border border-rose-300 px-5 font-black text-rose-700"><Ban className="h-4 w-4"/>Batalkan Order</button>}<button onClick={download} className="inline-flex min-h-11 items-center gap-2 rounded-xl border border-emerald-200 px-5 font-black text-emerald-700"><Download className="h-4 w-4"/>Unduh PDF</button><button onClick={print} className="inline-flex min-h-11 items-center gap-2 rounded-xl bg-emerald-600 px-5 font-black text-white"><Printer className="h-4 w-4"/>Print Invoice</button></div></>}
    {cancelOpen && <div className="absolute inset-0 flex items-center justify-center rounded-3xl bg-slate-950/60 p-5"><section className="w-full max-w-lg rounded-2xl bg-white p-6 shadow-2xl"><div className="flex gap-3"><TriangleAlert className="h-6 w-6 shrink-0 text-rose-600"/><div><h3 className="text-lg font-black">Batalkan Order ini?</h3><p className="mt-1 text-sm text-slate-600">Reservasi dilepas, Surat Jalan dibatalkan, dan Invoice ditandai DIBATALKAN. Histori tidak dihapus.</p></div></div><label className="mt-5 block text-sm font-bold">Alasan pembatalan<textarea value={cancelReason} onChange={(event) => setCancelReason(event.target.value)} maxLength={500} rows={4} className="mt-2 w-full rounded-xl border border-slate-300 p-3 font-normal outline-none focus:border-rose-500" placeholder="Contoh: salah quantity / order ganda"/></label><div className="mt-5 flex justify-end gap-3"><button disabled={cancelBusy} onClick={() => setCancelOpen(false)} className="min-h-11 rounded-xl border border-slate-200 px-5 font-bold">Kembali</button><button disabled={cancelBusy || !cancelReason.trim()} onClick={() => cancel(cancelReason.trim())} className="inline-flex min-h-11 items-center gap-2 rounded-xl bg-rose-600 px-5 font-black text-white disabled:opacity-50">{cancelBusy && <Loader2 className="h-4 w-4 animate-spin"/>}Konfirmasi batal</button></div></section></div>}
    {historyOpen && <div className="absolute inset-0 z-20 flex justify-end overflow-hidden rounded-3xl bg-slate-950/35" onMouseDown={(event) => { if (event.currentTarget === event.target) setHistoryOpen(false) }}><aside className="h-full w-full max-w-md overflow-y-auto bg-white p-6 shadow-2xl"><div className="flex items-start justify-between gap-4"><div><h3 className="inline-flex items-center gap-2 text-xl font-black text-slate-950"><History className="h-5 w-5 text-emerald-700"/>Riwayat aktivitas</h3><p className="mt-1 text-sm text-slate-500">{summary.invoiceNo}</p></div><button type="button" onClick={() => setHistoryOpen(false)} className="rounded-xl bg-slate-100 p-2" aria-label="Tutup riwayat"><X className="h-5 w-5"/></button></div><div className="mt-5 rounded-xl bg-slate-50 p-3 text-sm text-slate-600"><strong className="text-slate-900">Terakhir diperbarui</strong><p className="mt-1">{dateTime(activity?.updatedAt ?? summary.postedAt)}</p></div><ol className="mt-5 space-y-3">{timeline.map((item) => <li key={`${item.label}-${String(item.at)}`} className="rounded-xl border border-slate-200 p-4"><p className="font-bold text-slate-900">{item.label}</p><p className="mt-1 text-sm text-slate-500">{dateTime(item.at)}{item.actor ? ` · ${item.actor}` : ''}</p>{item.detail && <p className="mt-2 rounded-lg bg-slate-50 p-2 text-sm text-slate-700">{item.detail}</p>}</li>)}</ol></aside></div>}
  </article></div>
}
