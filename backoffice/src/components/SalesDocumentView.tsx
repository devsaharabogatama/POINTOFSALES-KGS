'use client'

import { useCallback, useEffect, useMemo, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import { Download, Eye, Loader2, Printer, RefreshCcw, Search, X } from 'lucide-react'
import { useEscapeClose } from '@/lib/use-escape-close'
import { downloadSalesInvoicePdf, printSalesInvoiceDocument } from '@/lib/sales-document-print'

type JsonMap = Record<string, unknown>
type InvoiceSummary = { salesId: string; invoiceSnapshotId: string; invoiceNo: string; snapshotProvenance: string; postedAt: string; total: number; fulfillmentMode: 'PICKUP' | 'DELIVERY'; sourceChannel: string; customerName: string; storeName: string }
type DetailPayload = { invoice?: JsonMap; error?: string }

function headers(session: Session, json = false) { return { Authorization: `Bearer ${session.access_token}`, ...(json ? { 'Content-Type': 'application/json' } : {}) } }
function money(value: number) { return new Intl.NumberFormat('id-ID', { style: 'currency', currency: 'IDR', maximumFractionDigits: 0 }).format(value || 0) }
function dateTime(value?: string | null) { return value ? new Date(value).toLocaleString('id-ID') : '-' }
function friendly(code?: string) { return ({ SALES_DOCUMENT_NOT_FOUND: 'Invoice tidak ditemukan atau tidak dapat diakses.', SALES_INVOICE_NOT_FOUND: 'Invoice final belum tersedia.', CUSTOM_PERMISSION_DENIED: 'Anda tidak diizinkan mengakses Invoice.', FORBIDDEN: 'Anda tidak diizinkan mengakses Invoice.', INVALID_API_RESPONSE: 'Layanan Invoice mengembalikan respons yang tidak valid. Muat ulang aplikasi lalu coba lagi.' } as Record<string, string>)[code ?? ''] ?? code ?? 'Operasi Invoice gagal.' }
async function readApiJson<T extends { error?: string }>(response: Response): Promise<T> {
  const contentType = response.headers.get('content-type') ?? ''
  if (!contentType.toLowerCase().includes('application/json')) {
    throw new Error(friendly('INVALID_API_RESPONSE'))
  }
  return await response.json() as T
}

export function SalesDocumentView({ session, companyId, notify }: { session: Session; companyId: string; notify: (message: string) => void }) {
  const [documents, setDocuments] = useState<InvoiceSummary[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [search, setSearch] = useState('')
  const [selected, setSelected] = useState<InvoiceSummary | null>(null)
  const [detail, setDetail] = useState<DetailPayload | null>(null)
  const [detailLoading, setDetailLoading] = useState(false)
  const [showLogoOnDocuments, setShowLogoOnDocuments] = useState(true)
  const [showStampOnDocuments, setShowStampOnDocuments] = useState(false)
  const [showBankAccountOnInvoice, setShowBankAccountOnInvoice] = useState(false)

  const load = useCallback(async () => {
    setLoading(true); setError('')
    try {
      const [response, brandingResponse] = await Promise.all([
        fetch('/api/sales/documents', { headers: headers(session) }),
        fetch('/api/platform/company-branding', {
          headers: headers(session), cache: 'no-store',
        }),
      ])
      const result = await readApiJson<{ data?: InvoiceSummary[]; error?: string }>(response)
      if (!response.ok) throw new Error(friendly(result.error))
      setDocuments(result.data ?? [])
      if (brandingResponse.ok) {
        const branding = await brandingResponse.json() as {
          data?: { showLogoOnDocuments?: boolean; showStampOnDocuments?: boolean; showBankAccountOnInvoice?: boolean }
        }
        setShowLogoOnDocuments(branding.data?.showLogoOnDocuments ?? true)
        setShowStampOnDocuments(branding.data?.showStampOnDocuments ?? false)
        setShowBankAccountOnInvoice(branding.data?.showBankAccountOnInvoice ?? false)
      }
    } catch (caught) { setError(caught instanceof Error ? caught.message : 'Invoice gagal dimuat.') }
    finally { setLoading(false) }
  }, [session])
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- rows follow active Company context
    void load()
  }, [load, companyId])
  const filtered = useMemo(() => documents.filter((document) => {
    const keyword = search.trim().toLowerCase()
    return !keyword || [document.invoiceNo, document.customerName, document.storeName].some((value) => value?.toLowerCase().includes(keyword))
  }), [documents, search])

  async function openDetail(document: InvoiceSummary) {
    setSelected(document); setDetail(null); setDetailLoading(true); setError('')
    try {
      const response = await fetch(`/api/sales/documents?salesId=${encodeURIComponent(document.salesId)}`, {
        headers: headers(session), cache: 'no-store',
      })
      const result = await readApiJson<DetailPayload>(response)
      if (!response.ok) throw new Error(friendly(result.error))
      setDetail(result)
    } catch (caught) { setError(caught instanceof Error ? caught.message : 'Detail Invoice gagal dimuat.'); setSelected(null) }
    finally { setDetailLoading(false) }
  }
  async function printInvoice() {
    if (!selected || !detail?.invoice) return
    try {
      printSalesInvoiceDocument(
        detail.invoice, showLogoOnDocuments, showStampOnDocuments,
        showBankAccountOnInvoice,
      )
      const response = await fetch('/api/sales/documents', { method: 'POST', headers: headers(session, true), body: JSON.stringify({ salesId: selected.salesId, documentType: 'SALES_INVOICE', documentId: detail.invoice.invoiceSnapshotId }) })
      const result = await readApiJson<{ error?: string }>(response)
      if (!response.ok) throw new Error(friendly(result.error))
      notify('Invoice dibuka di tab baru.')
    } catch (caught) { setError(caught instanceof Error ? caught.message : 'Invoice gagal dicetak.') }
  }
  async function downloadInvoice() {
    if (!selected || !detail?.invoice) return
    try {
      await downloadSalesInvoicePdf(
        detail.invoice, selected.customerName, showLogoOnDocuments,
        showStampOnDocuments,
        showBankAccountOnInvoice,
      )
      const response = await fetch('/api/sales/documents', { method: 'POST', headers: headers(session, true), body: JSON.stringify({ salesId: selected.salesId, documentType: 'SALES_INVOICE', documentId: detail.invoice.invoiceSnapshotId }) })
      const result = await readApiJson<{ error?: string }>(response)
      if (!response.ok) throw new Error(friendly(result.error))
      notify('Invoice berhasil diunduh.')
    } catch (caught) { setError(caught instanceof Error ? caught.message : 'Invoice gagal diunduh.') }
  }

  return <section className="space-y-5">
    <header className="flex flex-col gap-4 rounded-3xl border border-slate-200 bg-white p-6 shadow-sm lg:flex-row lg:items-center lg:justify-between"><div><p className="text-xs font-black uppercase tracking-[.2em] text-emerald-700">Sales</p><h1 className="mt-2 text-2xl font-black text-slate-950">Invoice Penjualan</h1><p className="mt-1 text-sm text-slate-500">Snapshot nilai final transaksi yang dapat dicetak ulang.</p></div><button onClick={() => void load()} disabled={loading} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-xl border border-slate-200 px-4 font-bold text-slate-700"><RefreshCcw className={`h-4 w-4 ${loading ? 'animate-spin' : ''}`}/>Muat ulang</button></header>
    <label className="relative block rounded-2xl border border-slate-200 bg-white p-4"><Search className="absolute left-7 top-7 h-4 w-4 text-slate-400"/><input value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Cari nomor Invoice, customer, atau toko" className="min-h-11 w-full rounded-xl border border-slate-200 pl-10 pr-3 outline-none focus:border-emerald-500"/></label>
    {error && <p className="rounded-2xl bg-rose-50 p-4 font-semibold text-rose-700">{error}</p>}
    <div className="overflow-hidden rounded-2xl border border-slate-200 bg-white"><div className="overflow-x-auto"><table className="w-full min-w-[760px] text-sm"><thead className="bg-slate-50 text-left text-xs uppercase text-slate-500"><tr><th className="p-4">Invoice</th><th className="p-4">Customer / Toko</th><th className="p-4">Pemenuhan</th><th className="p-4 text-right">Total</th><th className="p-4"/></tr></thead><tbody>{loading ? <tr><td colSpan={5} className="p-10 text-center text-slate-500"><Loader2 className="mx-auto mb-2 h-6 w-6 animate-spin"/>Memuat Invoice...</td></tr> : filtered.length === 0 ? <tr><td colSpan={5} className="p-10 text-center text-slate-500">Belum ada Invoice yang sesuai.</td></tr> : filtered.map((document) => <tr key={document.salesId} className="border-t border-slate-100"><td className="p-4"><strong>{document.invoiceNo}</strong><p className="mt-1 text-xs text-slate-500">{dateTime(document.postedAt)} · {document.sourceChannel}</p></td><td className="p-4"><strong>{document.customerName}</strong><p className="text-xs text-slate-500">{document.storeName}</p></td><td className="p-4">{document.fulfillmentMode === 'DELIVERY' ? 'Dikirim' : 'Ambil sendiri'}</td><td className="p-4 text-right font-black">{money(document.total)}</td><td className="p-4 text-right"><button onClick={() => void openDetail(document)} className="inline-flex min-h-10 items-center gap-2 rounded-xl bg-slate-900 px-4 font-bold text-white"><Eye className="h-4 w-4"/>Detail</button></td></tr>)}</tbody></table></div></div>
    {selected && <InvoiceDetail
      summary={selected}
      payload={detail}
      loading={detailLoading}
      close={() => { setSelected(null); setDetail(null) }}
      print={() => void printInvoice()}
      download={() => void downloadInvoice()}
    />}
  </section>
}

function InvoiceDetail({ summary, payload, loading, close, print, download }: { summary: InvoiceSummary; payload: DetailPayload | null; loading: boolean; close: () => void; print: () => void; download: () => void }) {
  useEscapeClose(close)
  const snapshot = (payload?.invoice?.snapshot ?? {}) as JsonMap
  const lines = Array.isArray(snapshot.lines) ? snapshot.lines as JsonMap[] : []
  return <div className="fixed inset-0 z-[75] overflow-y-auto bg-slate-950/65 p-4"><article className="mx-auto my-5 max-w-5xl rounded-3xl bg-white p-6 shadow-2xl"><div className="flex items-start justify-between gap-4"><div><p className="text-xs font-black uppercase tracking-wider text-emerald-700">Invoice Final</p><h2 className="mt-2 text-2xl font-black">{summary.invoiceNo}</h2><p className="mt-1 text-sm text-slate-500">{summary.customerName} · {summary.storeName} · {dateTime(summary.postedAt)}</p></div><button onClick={close} className="rounded-xl bg-slate-100 p-2" aria-label="Tutup"><X className="h-5 w-5"/></button></div>{loading ? <div className="p-16 text-center"><Loader2 className="mx-auto h-7 w-7 animate-spin"/></div> : payload && <><div className="mt-5 overflow-x-auto rounded-2xl border border-slate-200"><table className="w-full min-w-[680px] text-sm"><thead className="bg-slate-50 text-left text-xs uppercase text-slate-500"><tr><th className="p-4">Produk</th><th className="p-4">UOM</th><th className="p-4 text-right">Qty</th><th className="p-4 text-right">Harga</th><th className="p-4 text-right">Total</th></tr></thead><tbody>{lines.map((line, index) => <tr key={`${String(line.lineKey)}-${index}`} className="border-t"><td className="p-4"><strong>{String(line.productName ?? '-')}</strong><p className="text-xs text-slate-500">{String(line.sku ?? '')}</p></td><td className="p-4">{String(line.uomName ?? '-')}</td><td className="p-4 text-right">{String(line.quantity ?? 0)}</td><td className="p-4 text-right">{money(Number(line.unitPrice))}</td><td className="p-4 text-right font-black">{money(Number(line.lineTotal))}</td></tr>)}</tbody></table></div><div className="mt-6 flex flex-wrap justify-end gap-3"><button onClick={download} className="inline-flex min-h-11 items-center gap-2 rounded-xl border border-emerald-200 px-5 font-black text-emerald-700"><Download className="h-4 w-4"/>Unduh PDF</button><button onClick={print} className="inline-flex min-h-11 items-center gap-2 rounded-xl bg-emerald-600 px-5 font-black text-white"><Printer className="h-4 w-4"/>Print Invoice</button></div></>}</article></div>
}
