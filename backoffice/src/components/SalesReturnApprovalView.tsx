'use client'

import { useCallback, useEffect, useMemo, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import {
  Ban,
  CheckCircle2,
  Eye,
  Loader2,
  RefreshCcw,
  RotateCcw,
  Search,
  X,
} from 'lucide-react'
import { useEscapeClose } from '@/lib/use-escape-close'

type ReturnStatus = 'DRAFT' | 'POSTED' | 'CANCELED'
type ReturnDocument = {
  id: string
  return_no: string
  source_invoice_no_snapshot: string
  store_id: string
  source_session_id: string
  executing_session_id: string
  customer_id: string
  status: ReturnStatus
  approval_mode_snapshot: string
  notes: string | null
  refund_before_rounding: number | string
  rounding_direction: string | null
  rounding_adjustment: number | string
  refund_total: number | string
  master_version: number | string
  created_by: string
  created_at: string
  updated_at: string
  posted_by: string | null
  posted_at: string | null
  canceled_by: string | null
  canceled_at: string | null
  cancel_reason: string | null
  financial_event_id: string | null
  source_delivery_fee_amount_snapshot: number | string
  delivery_fee_refund_requested: boolean
  delivery_fee_refund_amount: number | string
  delivery_fee_refund_decided_by: string | null
  delivery_fee_refund_decided_at: string | null
}
type ReturnLine = {
  id: string
  document_id: string
  product_sku_snapshot: string
  product_name_snapshot: string
  sale_uom_name_snapshot: string
  quantity_uom: number | string
  quantity_base: number | string
  return_condition: string
  destination_warehouse_id: string | null
  refund_before_rounding: number | string
  tax_refund_amount: number | string
  fifo_cost_restored: number | string
}
type ReturnRefund = {
  id: string
  document_id: string
  payment_method_name_snapshot: string
  payment_method_type_snapshot: string
  amount: number | string
  transfer_destination: string | null
  transfer_reference: string | null
  proof_url: string | null
}
type Lookup = { id: string; name?: string; store_name?: string; session_code?: string; status?: string }
type Warehouse = Lookup & { warehouse_type?: string | null }
type Payload = {
  data?: ReturnDocument[]
  lines?: ReturnLine[]
  refunds?: ReturnRefund[]
  customers?: Lookup[]
  stores?: Lookup[]
  sessions?: Lookup[]
  actors?: Lookup[]
  warehouses?: Warehouse[]
  error?: string
}

function authHeaders(session: Session) {
  return { Authorization: `Bearer ${session.access_token}` }
}
function rupiah(value: number | string) {
  return new Intl.NumberFormat('id-ID', {
    style: 'currency', currency: 'IDR', maximumFractionDigits: 0,
  }).format(Number(value) || 0)
}
function qty(value: number | string) {
  return new Intl.NumberFormat('id-ID', { maximumFractionDigits: 6 }).format(Number(value) || 0)
}
function dateTime(value: string | null) {
  return value ? new Date(value).toLocaleString('id-ID') : '-'
}
function statusLabel(status: ReturnStatus) {
  return status === 'DRAFT' ? 'Menunggu approval' : status === 'POSTED' ? 'Sudah diposting' : 'Dibatalkan'
}
function conditionLabel(condition: string) {
  const labels: Record<string, string> = {
    SELLABLE: 'Layak dijual kembali', DAMAGED: 'Rusak', DISPOSAL: 'Dimusnahkan',
  }
  return labels[condition] ?? condition
}
function friendlyError(code?: string) {
  const messages: Record<string, string> = {
    SALES_RETURN_NOT_FOUND: 'Draft Return tidak ditemukan.',
    SALES_RETURN_ALREADY_POSTED: 'Return ini sudah diposting.',
    SALES_RETURN_NOT_POSTABLE: 'Status Return tidak dapat diposting.',
    SALES_RETURN_APPROVER_REQUIRED: 'Role atau cakupan Store Anda tidak diizinkan menyetujui Return ini.',
    SALES_RETURN_DRAFT_INCOMPLETE: 'Data barang atau refund pada draft belum lengkap.',
    POSTED_SOURCE_SALE_NOT_FOUND: 'Transaksi penjualan asal tidak ditemukan atau belum final.',
    OPEN_RETURN_SESSION_REQUIRED: 'Sesi kasir pelaksana sudah ditutup. Return ini belum dapat diposting.',
    RETURN_WAREHOUSE_CHANGED_DURING_POST: 'Gudang tujuan berubah. Muat ulang sebelum posting.',
    REFUND_METHOD_CHANGED_DURING_POST: 'Metode refund berubah. Muat ulang sebelum posting.',
    RETURN_QUANTITY_CHANGED_DURING_POST: 'Jumlah Return berubah. Muat ulang sebelum posting.',
    SOURCE_SALE_FIFO_RESTORATION_EXHAUSTED: 'Sumber FIFO penjualan tidak cukup untuk direstorasi.',
    SALES_RETURN_TRANSACTION_CATEGORY_NOT_FOUND: 'Kategori transaksi Return Penjualan belum siap.',
    ONLY_DRAFT_RETURN_CANCELABLE: 'Hanya Return berstatus Draft yang dapat dibatalkan.',
    SALES_RETURN_CANCEL_NOT_ALLOWED: 'Role atau cakupan Store Anda tidak diizinkan membatalkan Return ini.',
    CANCEL_REASON_REQUIRED: 'Alasan pembatalan wajib diisi.',
    MASTER_VERSION_CONFLICT: 'Draft berubah di perangkat lain. Muat ulang sebelum mengulangi tindakan.',
    CUSTOM_PERMISSION_DENIED: 'Pembatasan akses user tidak mengizinkan tindakan Return ini.',
    FORBIDDEN: 'Anda tidak diizinkan mengakses approval Return.',
  }
  return messages[code ?? ''] ?? code ?? 'Operasi Return gagal.'
}

export function SalesReturnApprovalView({
  session, companyId, canApprove, canCancel, notify,
}: {
  session: Session
  companyId: string
  canApprove: boolean
  canCancel: boolean
  notify: (message: string) => void
}) {
  const [payload, setPayload] = useState<Payload>({})
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [status, setStatus] = useState<'ALL' | ReturnStatus>('DRAFT')
  const [search, setSearch] = useState('')
  const [detail, setDetail] = useState<ReturnDocument | null>(null)
  const [action, setAction] = useState<{ type: 'post' | 'cancel'; document: ReturnDocument } | null>(null)

  const load = useCallback(async () => {
    const response = await fetch('/api/sales/returns', { headers: authHeaders(session) })
    const result = (await response.json()) as Payload
    if (!response.ok) throw new Error(friendlyError(result.error))
    setPayload(result)
  }, [session])
  const refresh = useCallback(async () => {
    setLoading(true); setError('')
    try { await load() } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Gagal memuat Return Penjualan.')
    } finally { setLoading(false) }
  }, [load])
  useEffect(() => {
    let canceled = false
    // eslint-disable-next-line react-hooks/set-state-in-effect -- load is synchronized to the active Company context
    load().catch((caught) => {
      if (!canceled) setError(caught instanceof Error ? caught.message : 'Gagal memuat Return Penjualan.')
    }).finally(() => { if (!canceled) setLoading(false) })
    return () => { canceled = true }
  }, [companyId, load])

  const customerById = useMemo(() => new Map((payload.customers ?? []).map((row) => [row.id, row.name ?? 'Pelanggan'])), [payload.customers])
  const storeById = useMemo(() => new Map((payload.stores ?? []).map((row) => [row.id, row.store_name ?? 'Store'])), [payload.stores])
  const sessionById = useMemo(() => new Map((payload.sessions ?? []).map((row) => [row.id, row])), [payload.sessions])
  const actorById = useMemo(() => new Map((payload.actors ?? []).map((row) => [row.id, row.name ?? 'User'])), [payload.actors])
  const warehouseById = useMemo(() => new Map((payload.warehouses ?? []).map((row) => [row.id, row.name ?? 'Gudang'])), [payload.warehouses])
  const documents = useMemo(() => {
    const term = search.trim().toLowerCase()
    return (payload.data ?? []).filter((row) => {
      if (status !== 'ALL' && row.status !== status) return false
      return !term || [row.return_no, row.source_invoice_no_snapshot, customerById.get(row.customer_id), storeById.get(row.store_id)]
        .some((value) => value?.toLowerCase().includes(term))
    })
  }, [customerById, payload.data, search, status, storeById])
  const counts = useMemo(() => ({
    draft: (payload.data ?? []).filter((row) => row.status === 'DRAFT').length,
    posted: (payload.data ?? []).filter((row) => row.status === 'POSTED').length,
    canceled: (payload.data ?? []).filter((row) => row.status === 'CANCELED').length,
  }), [payload.data])

  return (
    <>
      <section className="space-y-6">
        <div className="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
          <div>
            <p className="text-xs font-black uppercase tracking-[0.18em] text-emerald-600">Sales Control</p>
            <h1 className="mt-2 text-3xl font-black text-slate-950">Approval Return Penjualan</h1>
            <p className="mt-2 max-w-3xl text-sm text-slate-500">Review draft dari kasir sebelum refund, stok, FIFO, dan event Finance menjadi final.</p>
          </div>
          <button onClick={refresh} disabled={loading} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-xl border border-slate-200 bg-white px-4 text-sm font-black text-slate-700 shadow-sm disabled:opacity-50">
            <RefreshCcw className={`h-4 w-4 ${loading ? 'animate-spin' : ''}`} /> Muat ulang
          </button>
        </div>

        <div className="grid gap-3 sm:grid-cols-3">
          <Summary label="Menunggu approval" value={String(counts.draft)} tone="amber" />
          <Summary label="Sudah diposting" value={String(counts.posted)} tone="emerald" />
          <Summary label="Dibatalkan" value={String(counts.canceled)} tone="slate" />
        </div>

        <div className="grid gap-3 rounded-2xl border border-slate-200 bg-white p-4 shadow-sm md:grid-cols-[220px_1fr]">
          <label className="text-sm font-bold text-slate-700">Status
            <select value={status} onChange={(event) => setStatus(event.target.value as typeof status)} className="mt-2 min-h-11 w-full rounded-xl border border-slate-200 bg-white px-3 font-semibold outline-none focus:border-emerald-500">
              <option value="DRAFT">Menunggu approval</option><option value="POSTED">Sudah diposting</option><option value="CANCELED">Dibatalkan</option><option value="ALL">Semua status</option>
            </select>
          </label>
          <label className="text-sm font-bold text-slate-700">Cari Return
            <span className="mt-2 flex min-h-11 items-center gap-2 rounded-xl border border-slate-200 px-3 focus-within:border-emerald-500">
              <Search className="h-4 w-4 text-slate-400" />
              <input value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Nomor Return, invoice, pelanggan, atau Store" className="w-full bg-transparent text-sm outline-none" />
            </span>
          </label>
        </div>

        {error && <div className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-semibold text-rose-700">{error}</div>}
        <div className="overflow-x-auto rounded-2xl border border-slate-200 bg-white shadow-sm">
          <table className="w-full min-w-[920px] text-left text-sm">
            <thead className="bg-slate-50 text-xs uppercase tracking-wider text-slate-500"><tr><th className="px-5 py-4">Return / Penjualan asal</th><th className="px-5 py-4">Pelanggan</th><th className="px-5 py-4">Store</th><th className="px-5 py-4 text-right">Total refund</th><th className="px-5 py-4">Status</th><th className="px-5 py-4 text-right">Aksi</th></tr></thead>
            <tbody className="divide-y divide-slate-100">
              {documents.map((row) => <tr key={row.id} className="hover:bg-slate-50/70">
                <td className="px-5 py-4"><p className="font-black text-slate-900">{row.return_no}</p><p className="mt-1 text-xs text-slate-500">Invoice {row.source_invoice_no_snapshot} · {dateTime(row.created_at)}</p></td>
                <td className="px-5 py-4 font-semibold text-slate-700">{customerById.get(row.customer_id) ?? 'Pelanggan'}</td>
                <td className="px-5 py-4 text-slate-600">{storeById.get(row.store_id) ?? 'Store'}</td>
                <td className="px-5 py-4 text-right font-black text-slate-900">{rupiah(row.refund_total)}</td>
                <td className="px-5 py-4"><StatusBadge status={row.status} /></td>
                <td className="px-5 py-4 text-right"><button onClick={() => setDetail(row)} className="inline-flex min-h-10 items-center gap-2 rounded-xl border border-slate-200 px-3 font-black text-slate-700"><Eye className="h-4 w-4" /> Detail</button></td>
              </tr>)}
              {!loading && documents.length === 0 && <tr><td colSpan={6} className="px-5 py-12 text-center text-slate-400">Tidak ada Return untuk filter ini.</td></tr>}
              {loading && <tr><td colSpan={6} className="px-5 py-12 text-center text-slate-400"><Loader2 className="mx-auto h-5 w-5 animate-spin" /></td></tr>}
            </tbody>
          </table>
        </div>
      </section>

      {detail && <ReturnDetail document={detail} lines={(payload.lines ?? []).filter((row) => row.document_id === detail.id)} refunds={(payload.refunds ?? []).filter((row) => row.document_id === detail.id)} customer={customerById.get(detail.customer_id)} store={storeById.get(detail.store_id)} executingSession={sessionById.get(detail.executing_session_id)} actorById={actorById} warehouseById={warehouseById} canApprove={canApprove} canCancel={canCancel} close={() => setDetail(null)} act={(type) => setAction({ type, document: detail })} />}
      {action && <ReturnActionDialog session={session} action={action} close={() => setAction(null)} complete={async () => { const label = action.type === 'post' ? 'diposting' : 'dibatalkan'; setAction(null); setDetail(null); await refresh(); notify(`Return Penjualan berhasil ${label}.`) }} />}
    </>
  )
}

function Summary({ label, value, tone }: { label: string; value: string; tone: 'amber' | 'emerald' | 'slate' }) {
  const styles = tone === 'amber' ? 'border-amber-200 bg-amber-50 text-amber-900' : tone === 'emerald' ? 'border-emerald-200 bg-emerald-50 text-emerald-900' : 'border-slate-200 bg-white text-slate-900'
  return <div className={`rounded-2xl border p-5 ${styles}`}><p className="text-xs font-black uppercase tracking-wider opacity-70">{label}</p><p className="mt-2 text-3xl font-black">{value}</p></div>
}
function StatusBadge({ status }: { status: ReturnStatus }) {
  const styles = status === 'DRAFT' ? 'bg-amber-100 text-amber-800' : status === 'POSTED' ? 'bg-emerald-100 text-emerald-800' : 'bg-slate-200 text-slate-700'
  return <span className={`inline-flex rounded-full px-3 py-1 text-xs font-black ${styles}`}>{statusLabel(status)}</span>
}

function ReturnDetail({ document, lines, refunds, customer, store, executingSession, actorById, warehouseById, canApprove, canCancel, close, act }: {
  document: ReturnDocument; lines: ReturnLine[]; refunds: ReturnRefund[]; customer?: string; store?: string; executingSession?: Lookup; actorById: Map<string, string>; warehouseById: Map<string, string>; canApprove: boolean; canCancel: boolean; close: () => void; act: (type: 'post' | 'cancel') => void
}) {
  useEscapeClose(close)
  const sessionOpen = executingSession?.status === 'OPEN'
  return <div className="fixed inset-0 z-[70] grid place-items-center bg-slate-950/55 p-4 backdrop-blur-sm">
    <div className="max-h-[94vh] w-full max-w-6xl overflow-y-auto rounded-3xl bg-white p-6 shadow-2xl sm:p-8">
      <div className="flex items-start justify-between gap-4"><div><p className="text-xs font-black uppercase tracking-wider text-emerald-600">Detail Return Penjualan</p><h2 className="mt-2 text-2xl font-black text-slate-950">{document.return_no}</h2><p className="mt-2 text-sm text-slate-500">Invoice asal {document.source_invoice_no_snapshot} · {store ?? 'Store'}</p></div><button onClick={close} className="rounded-xl bg-slate-100 p-2 text-slate-500" aria-label="Tutup"><X className="h-4 w-4" /></button></div>
      <div className="mt-6 grid gap-3 sm:grid-cols-2 lg:grid-cols-4"><Info label="Status" value={statusLabel(document.status)} /><Info label="Pelanggan" value={customer ?? 'Pelanggan'} /><Info label="Dibuat oleh" value={actorById.get(document.created_by) ?? 'User'} /><Info label="Sesi pelaksana" value={`${executingSession?.session_code ?? 'Sesi kasir'} · ${executingSession?.status ?? 'Tidak ditemukan'}`} /></div>
      {document.status === 'DRAFT' && !sessionOpen && <div className="mt-5 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm font-semibold text-amber-900">Sesi kasir pelaksana tidak OPEN. Backend akan menolak posting sampai kondisi sesi diselesaikan.</div>}
      {Number(document.source_delivery_fee_amount_snapshot) > 0 && <div className={`mt-5 rounded-2xl border p-4 text-sm ${document.delivery_fee_refund_requested ? 'border-blue-200 bg-blue-50 text-blue-900' : 'border-slate-200 bg-slate-50 text-slate-700'}`}><p className="font-black">Keputusan refund ongkir</p><p className="mt-1">{document.delivery_fee_refund_requested ? `Kasir meminta refund ongkir ${rupiah(document.delivery_fee_refund_amount)}. Approval ini mengesahkan keputusan tersebut.` : `Ongkir asal ${rupiah(document.source_delivery_fee_amount_snapshot)} tidak direfund. Posting hanya mengembalikan nilai barang.`}</p>{document.delivery_fee_refund_decided_at && <p className="mt-2 text-xs">Diputuskan {dateTime(document.delivery_fee_refund_decided_at)} oleh {document.delivery_fee_refund_decided_by ? actorById.get(document.delivery_fee_refund_decided_by) ?? 'Approver' : 'Approver'}.</p>}</div>}
      <div className="mt-6 overflow-x-auto rounded-2xl border border-slate-200"><table className="w-full min-w-[900px] text-left text-sm"><thead className="bg-slate-50 text-xs uppercase tracking-wider text-slate-500"><tr><th className="px-4 py-3">Barang</th><th className="px-4 py-3 text-right">Jumlah</th><th className="px-4 py-3">Kondisi / tujuan</th><th className="px-4 py-3 text-right">Refund</th><th className="px-4 py-3 text-right">Pajak</th></tr></thead><tbody className="divide-y divide-slate-100">{lines.map((line) => <tr key={line.id}><td className="px-4 py-4"><p className="font-black text-slate-900">{line.product_name_snapshot}</p><p className="mt-1 text-xs text-slate-500">{line.product_sku_snapshot}</p></td><td className="px-4 py-4 text-right font-black">{qty(line.quantity_uom)} {line.sale_uom_name_snapshot}<p className="mt-1 text-xs font-normal text-slate-400">{qty(line.quantity_base)} base</p></td><td className="px-4 py-4"><p className="font-semibold text-slate-700">{conditionLabel(line.return_condition)}</p><p className="mt-1 text-xs text-slate-500">{line.destination_warehouse_id ? warehouseById.get(line.destination_warehouse_id) ?? 'Gudang tujuan' : 'Tidak kembali ke stok'}</p></td><td className="px-4 py-4 text-right font-black">{rupiah(line.refund_before_rounding)}</td><td className="px-4 py-4 text-right text-slate-600">{rupiah(line.tax_refund_amount)}</td></tr>)}</tbody></table></div>
      <div className="mt-6 grid gap-5 lg:grid-cols-[1fr_360px]"><div className="rounded-2xl border border-slate-200 p-5"><h3 className="font-black text-slate-900">Metode refund</h3><div className="mt-4 space-y-3">{refunds.map((refund) => <div key={refund.id} className="rounded-xl bg-slate-50 p-4"><div className="flex justify-between gap-4"><div><p className="font-black text-slate-800">{refund.payment_method_name_snapshot}</p><p className="mt-1 text-xs text-slate-500">{refund.payment_method_type_snapshot}{refund.transfer_destination ? ` · Tujuan ${refund.transfer_destination}` : ''}{refund.transfer_reference ? ` · Ref ${refund.transfer_reference}` : ''}</p></div><p className="font-black text-slate-900">{rupiah(refund.amount)}</p></div>{refund.proof_url && <a href={refund.proof_url} target="_blank" rel="noreferrer" className="mt-3 inline-block text-xs font-black text-emerald-700 underline">Buka bukti transfer</a>}</div>)}</div></div><div className="rounded-2xl bg-slate-950 p-5 text-white"><p className="text-xs font-black uppercase tracking-wider text-slate-400">Ringkasan refund</p><div className="mt-4 space-y-3 text-sm"><div className="flex justify-between"><span>Sebelum pembulatan</span><strong>{rupiah(document.refund_before_rounding)}</strong></div><div className="flex justify-between"><span>Penyesuaian</span><strong>{rupiah(document.rounding_adjustment)}</strong></div><div className="border-t border-slate-700 pt-3 text-lg flex justify-between"><span>Total refund</span><strong>{rupiah(document.refund_total)}</strong></div></div></div></div>
      {document.notes && <div className="mt-5 rounded-2xl bg-slate-50 p-4 text-sm text-slate-600"><strong>Catatan:</strong> {document.notes}</div>}
      {document.status === 'CANCELED' && <div className="mt-5 rounded-2xl border border-slate-200 p-4 text-sm text-slate-600"><strong>Alasan dibatalkan:</strong> {document.cancel_reason ?? '-'}</div>}
      <div className="mt-6 flex flex-wrap justify-end gap-3"><button onClick={close} className="min-h-11 rounded-xl border border-slate-200 px-5 font-black text-slate-600">Tutup</button>{document.status === 'DRAFT' && canCancel && <button onClick={() => act('cancel')} className="inline-flex min-h-11 items-center gap-2 rounded-xl border border-rose-200 px-5 font-black text-rose-700"><Ban className="h-4 w-4" /> Batalkan Return</button>}{document.status === 'DRAFT' && canApprove && <button onClick={() => act('post')} disabled={!sessionOpen} className="inline-flex min-h-11 items-center gap-2 rounded-xl bg-emerald-600 px-5 font-black text-white disabled:cursor-not-allowed disabled:bg-slate-300"><CheckCircle2 className="h-4 w-4" /> Setujui & Posting</button>}</div>
    </div>
  </div>
}
function Info({ label, value }: { label: string; value: string }) { return <div className="rounded-2xl border border-slate-200 p-4"><p className="text-xs font-black uppercase tracking-wider text-slate-400">{label}</p><p className="mt-2 font-black text-slate-800">{value}</p></div> }

function ReturnActionDialog({ session, action, close, complete }: { session: Session; action: { type: 'post' | 'cancel'; document: ReturnDocument }; close: () => void; complete: () => Promise<void> }) {
  useEscapeClose(close)
  const [confirmed, setConfirmed] = useState(false)
  const [reason, setReason] = useState('')
  const [idempotencyKey] = useState(() => crypto.randomUUID())
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')
  const isPost = action.type === 'post'
  async function run() {
    setSaving(true); setError('')
    try {
      const response = await fetch(`/api/sales/returns/${action.document.id}/${action.type}`, { method: 'POST', headers: { 'Content-Type': 'application/json', ...authHeaders(session) }, body: JSON.stringify({ masterVersion: Number(action.document.master_version), ...(isPost ? { idempotencyKey } : { reason }) }) })
      const result = (await response.json()) as { error?: string }
      if (!response.ok) throw new Error(friendlyError(result.error))
      await complete()
    } catch (caught) { setError(caught instanceof Error ? caught.message : 'Tindakan Return gagal.') } finally { setSaving(false) }
  }
  const valid = confirmed && (isPost || reason.trim().length >= 3)
  return <div className="fixed inset-0 z-[80] grid place-items-center bg-slate-950/60 p-4 backdrop-blur-sm"><div className="w-full max-w-xl rounded-3xl bg-white p-7 shadow-2xl"><div className="flex items-start justify-between gap-4"><div><p className="text-xs font-black uppercase tracking-wider text-emerald-600">Konfirmasi Return</p><h2 className="mt-2 text-xl font-black text-slate-950">{isPost ? 'Setujui dan posting Return?' : 'Batalkan draft Return?'}</h2><p className="mt-2 text-sm text-slate-500">{action.document.return_no} · {rupiah(action.document.refund_total)}</p></div><button onClick={close} className="rounded-xl bg-slate-100 p-2 text-slate-500" aria-label="Tutup"><X className="h-4 w-4" /></button></div>{isPost ? <div className="mt-5 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-900"><p className="font-black">Posting adalah tindakan final.</p><p className="mt-1">Refund, restorasi stok/FIFO, dan event Finance akan dicatat dalam satu transaksi. Event Finance masih mengikuti pipeline HOLD yang berlaku.</p></div> : <label className="mt-5 block text-sm font-black text-slate-700">Alasan pembatalan<textarea value={reason} onChange={(event) => setReason(event.target.value)} maxLength={500} rows={4} placeholder="Contoh: Barang dan nominal Return tidak sesuai" className="mt-2 w-full rounded-xl border border-slate-200 p-3 font-normal outline-none focus:border-rose-400" /></label>}<label className="mt-5 flex cursor-pointer items-start gap-3 rounded-2xl border border-slate-200 p-4 text-sm font-semibold text-slate-700"><input type="checkbox" checked={confirmed} onChange={(event) => setConfirmed(event.target.checked)} className="mt-0.5 h-4 w-4 accent-emerald-600" /><span>Saya sudah memeriksa invoice asal, barang, jumlah, kondisi, gudang tujuan, dan metode refund.</span></label>{error && <p className="mt-4 rounded-xl bg-rose-50 p-3 text-sm font-semibold text-rose-700">{error}</p>}<div className="mt-6 flex justify-end gap-3"><button onClick={close} disabled={saving} className="min-h-11 rounded-xl border border-slate-200 px-5 font-black text-slate-600">Kembali</button><button onClick={run} disabled={!valid || saving} className={`inline-flex min-h-11 items-center gap-2 rounded-xl px-5 font-black text-white disabled:cursor-not-allowed disabled:bg-slate-300 ${isPost ? 'bg-emerald-600' : 'bg-rose-600'}`}>{saving ? <Loader2 className="h-4 w-4 animate-spin" /> : isPost ? <CheckCircle2 className="h-4 w-4" /> : <RotateCcw className="h-4 w-4" />}{isPost ? 'Posting Return' : 'Batalkan Return'}</button></div></div></div>
}
