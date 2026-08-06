'use client'

import { useCallback, useEffect, useMemo, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import {
  BanknoteArrowUp, Building2, CheckCircle2, Eye, Landmark,
  Loader2, RefreshCcw, Search, X, XCircle,
} from 'lucide-react'
import { useEscapeClose } from '@/lib/use-escape-close'

type DepositStatus = 'DRAFT' | 'SUBMITTED' | 'APPROVED' | 'REJECTED' | 'CANCELED'
type DepositDocument = {
  id: string
  store_id: string
  deposit_no: string
  destination_type: 'BANK' | 'VAULT'
  destination_name_snapshot: string
  actual_deposit_amount: number | string
  total_expected_deposit: number | string
  deposit_variance: number | string
  variance_type: 'NONE' | 'MATCHED' | 'UNDER_DEPOSIT' | 'OVER_DEPOSIT'
  deposit_at: string
  evidence_url: string | null
  notes: string | null
  status: DepositStatus
  proof_mode_snapshot: string
  master_version: number | string
  created_by: string
  submitted_by: string | null
  approved_by: string | null
  rejected_by: string | null
  created_at: string
  submitted_at: string | null
  approved_at: string | null
  rejected_at: string | null
  rejection_reason: string | null
  financial_event_id: string | null
}
type DepositLine = {
  id: string
  deposit_document_id: string
  session_code_snapshot: string
  cashier_name_snapshot: string
  closing_cash_actual_snapshot: number | string
  next_session_float_reserved: number | string
  posted_deposit_allocations_snapshot: number | string
  expected_deposit_amount: number | string
  allocation_status: string
}
type Lookup = { id: string; name?: string; store_name?: string }
type Payload = {
  data?: DepositDocument[]
  lines?: DepositLine[]
  stores?: Lookup[]
  actors?: Lookup[]
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
function dateTime(value: string | null) {
  return value ? new Date(value).toLocaleString('id-ID') : '-'
}
function statusLabel(status: DepositStatus) {
  const labels: Record<DepositStatus, string> = {
    DRAFT: 'Draft', SUBMITTED: 'Menunggu review', APPROVED: 'Disetujui',
    REJECTED: 'Ditolak', CANCELED: 'Dibatalkan',
  }
  return labels[status]
}
function varianceLabel(type: string) {
  return type === 'UNDER_DEPOSIT' ? 'Kurang' : type === 'OVER_DEPOSIT' ? 'Lebih' : 'Sesuai'
}
function friendlyError(code?: string) {
  const messages: Record<string, string> = {
    CASH_DEPOSIT_NOT_FOUND: 'Dokumen Setor Kas tidak ditemukan.',
    CASH_DEPOSIT_NOT_REVIEWABLE: 'Dokumen ini sudah direview atau statusnya berubah.',
    CASH_DEPOSIT_REVIEW_ACCESS_DENIED: 'Role Anda tidak diizinkan mereview Setor Kas.',
    DEPOSIT_REJECTION_REASON_REQUIRED: 'Alasan penolakan wajib diisi.',
    CASH_DEPOSIT_SESSION_CHANGED: 'Data sesi kasir berubah. Muat ulang sebelum mereview.',
    CASH_DEPOSIT_ALLOCATION_CHANGED: 'Alokasi setoran berubah. Muat ulang sebelum mereview.',
    MASTER_VERSION_CONFLICT: 'Dokumen berubah di perangkat lain. Muat ulang dan coba lagi.',
    FORBIDDEN: 'Anda tidak diizinkan mengakses Setor Kas.',
  }
  return messages[code ?? ''] ?? code ?? 'Operasi Setor Kas gagal.'
}

export function CashDepositApprovalView({
  session, companyId, canApprove, notify,
}: {
  session: Session
  companyId: string
  canApprove: boolean
  notify: (message: string) => void
}) {
  const [payload, setPayload] = useState<Payload>({})
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [status, setStatus] = useState<'ALL' | DepositStatus>('SUBMITTED')
  const [search, setSearch] = useState('')
  const [detail, setDetail] = useState<DepositDocument | null>(null)
  const [action, setAction] = useState<{
    type: 'APPROVE' | 'REJECT'; document: DepositDocument
  } | null>(null)

  const load = useCallback(async () => {
    const response = await fetch('/api/finance/cash-deposits', {
      headers: authHeaders(session),
    })
    const result = (await response.json()) as Payload
    if (!response.ok) throw new Error(friendlyError(result.error))
    setPayload({
      ...result,
      data: result.data?.map((row) => ({
        ...row,
        variance_type: row.variance_type === 'MATCHED' ? 'NONE' : row.variance_type,
      })),
    })
  }, [session])
  const refresh = useCallback(async () => {
    setLoading(true); setError('')
    try { await load() } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Gagal memuat Setor Kas.')
    } finally { setLoading(false) }
  }, [load])
  useEffect(() => {
    let canceled = false
    // eslint-disable-next-line react-hooks/set-state-in-effect -- load follows the active Company context
    load().catch((caught) => {
      if (!canceled) setError(caught instanceof Error ? caught.message : 'Gagal memuat Setor Kas.')
    }).finally(() => { if (!canceled) setLoading(false) })
    return () => { canceled = true }
  }, [companyId, load])
  useEscapeClose(() => {
    if (action) setAction(null)
    else if (detail) setDetail(null)
  })

  const storeNames = useMemo(
    () => new Map((payload.stores ?? []).map((row) => [row.id, row.store_name ?? '-'])),
    [payload.stores],
  )
  const actorNames = useMemo(
    () => new Map((payload.actors ?? []).map((row) => [row.id, row.name ?? '-'])),
    [payload.actors],
  )
  const rows = useMemo(() => (payload.data ?? []).filter((row) => {
    if (status !== 'ALL' && row.status !== status) return false
    const needle = search.trim().toLowerCase()
    return !needle || [
      row.deposit_no, row.destination_name_snapshot,
      storeNames.get(row.store_id) ?? '', actorNames.get(row.created_by) ?? '',
    ].some((value) => value.toLowerCase().includes(needle))
  }), [actorNames, payload.data, search, status, storeNames])
  const summary = useMemo(() => ({
    submitted: (payload.data ?? []).filter((row) => row.status === 'SUBMITTED').length,
    approved: (payload.data ?? []).filter((row) => row.status === 'APPROVED').length,
    variance: (payload.data ?? []).filter((row) => row.status === 'APPROVED' && Number(row.deposit_variance) !== 0).length,
  }), [payload.data])

  return <div className="space-y-6">
    <div className="flex flex-col gap-4 rounded-3xl bg-slate-950 p-6 text-white md:flex-row md:items-center md:justify-between">
      <div><p className="text-xs font-bold uppercase tracking-[.18em] text-emerald-400">Finance · Kontrol Kas</p><h1 className="mt-2 text-3xl font-black">Setor Kas</h1><p className="mt-2 max-w-2xl text-sm text-slate-400">Review setoran dari sesi kasir yang sudah ditutup. Approval memfinalkan alokasi sesi dan mencatat Financial Event HOLD.</p></div>
      <button type="button" onClick={() => void refresh()} disabled={loading} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-xl bg-white px-4 font-black text-slate-900 disabled:opacity-60"><RefreshCcw className={`h-4 w-4 ${loading ? 'animate-spin' : ''}`} /> Muat ulang</button>
    </div>

    <div className="grid gap-3 sm:grid-cols-3"><Summary label="Menunggu review" value={summary.submitted} tone="amber" /><Summary label="Disetujui" value={summary.approved} tone="emerald" /><Summary label="Approved berselisih" value={summary.variance} tone="rose" /></div>

    <div className="rounded-3xl border border-slate-200 bg-white shadow-sm">
      <div className="flex flex-col gap-3 border-b border-slate-200 p-4 sm:flex-row">
        <label className="relative flex-1"><Search className="absolute left-3 top-3 h-4 w-4 text-slate-400" /><input value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Cari nomor, tujuan, Store, atau pembuat" className="min-h-10 w-full rounded-xl border border-slate-200 pl-9 pr-3 text-sm outline-none focus:border-emerald-500" /></label>
        <select value={status} onChange={(event) => setStatus(event.target.value as typeof status)} className="min-h-10 rounded-xl border border-slate-200 bg-white px-3 text-sm font-bold"><option value="SUBMITTED">Menunggu review</option><option value="APPROVED">Disetujui</option><option value="REJECTED">Ditolak</option><option value="DRAFT">Draft</option><option value="CANCELED">Dibatalkan</option><option value="ALL">Semua status</option></select>
      </div>
      {error && <p className="m-4 rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-700">{error}</p>}
      {loading ? <div className="grid min-h-56 place-items-center"><Loader2 className="h-7 w-7 animate-spin text-emerald-600" /></div> : rows.length === 0 ? <div className="p-12 text-center text-sm text-slate-500">Tidak ada dokumen pada filter ini.</div> : <div className="overflow-x-auto"><table className="w-full min-w-[900px] text-left text-sm"><thead className="bg-slate-50 text-xs uppercase tracking-wider text-slate-500"><tr><th className="px-5 py-3">Dokumen</th><th className="px-5 py-3">Tujuan</th><th className="px-5 py-3">Expected / Aktual</th><th className="px-5 py-3">Selisih</th><th className="px-5 py-3">Status</th><th className="px-5 py-3 text-right">Detail</th></tr></thead><tbody className="divide-y divide-slate-100">{rows.map((row) => <tr key={row.id} className="hover:bg-slate-50"><td className="px-5 py-4"><strong className="block text-slate-900">{row.deposit_no}</strong><span className="text-xs text-slate-500">{storeNames.get(row.store_id) ?? '-'} · {dateTime(row.deposit_at)}</span></td><td className="px-5 py-4"><span className="inline-flex items-center gap-2 font-semibold">{row.destination_type === 'BANK' ? <Landmark className="h-4 w-4" /> : <Building2 className="h-4 w-4" />}{row.destination_name_snapshot}</span></td><td className="px-5 py-4"><span className="block">{rupiah(row.total_expected_deposit)}</span><strong className="text-slate-900">{rupiah(row.actual_deposit_amount)}</strong></td><td className="px-5 py-4"><strong className={row.variance_type === 'NONE' ? 'text-emerald-700' : 'text-rose-700'}>{varianceLabel(row.variance_type)} · {rupiah(row.deposit_variance)}</strong></td><td className="px-5 py-4"><StatusPill status={row.status} /></td><td className="px-5 py-4 text-right"><button type="button" onClick={() => setDetail(row)} className="inline-flex min-h-9 items-center gap-2 rounded-lg border border-slate-200 px-3 font-bold"><Eye className="h-4 w-4" /> Lihat</button></td></tr>)}</tbody></table></div>}
    </div>

    {detail && <DetailModal document={detail} lines={(payload.lines ?? []).filter((line) => line.deposit_document_id === detail.id)} storeName={storeNames.get(detail.store_id) ?? '-'} actorName={actorNames.get(detail.created_by) ?? '-'} canApprove={canApprove} close={() => setDetail(null)} act={(type) => setAction({ type, document: detail })} />}
    {action && <ReviewDialog session={session} action={action} close={() => setAction(null)} completed={async (message) => { setAction(null); setDetail(null); notify(message); await refresh() }} />}
  </div>
}

function DetailModal({ document, lines, storeName, actorName, canApprove, close, act }: { document: DepositDocument; lines: DepositLine[]; storeName: string; actorName: string; canApprove: boolean; close: () => void; act: (type: 'APPROVE' | 'REJECT') => void }) {
  return <div className="fixed inset-0 z-50 grid place-items-center bg-slate-950/60 p-4 backdrop-blur-sm"><section role="dialog" aria-modal="true" aria-labelledby="deposit-detail-title" className="flex max-h-[94vh] w-full max-w-5xl flex-col overflow-hidden rounded-3xl bg-white shadow-2xl"><header className="flex items-start justify-between border-b border-slate-200 p-5"><div><p className="text-xs font-bold uppercase tracking-wider text-emerald-600">{storeName}</p><h2 id="deposit-detail-title" className="mt-1 text-2xl font-black">{document.deposit_no}</h2><p className="mt-1 text-sm text-slate-500">Dibuat {actorName} · {dateTime(document.created_at)}</p></div><button type="button" onClick={close} aria-label="Tutup detail" className="rounded-xl bg-slate-100 p-2 text-slate-500"><X className="h-5 w-5" /></button></header><div className="flex-1 space-y-5 overflow-y-auto p-5">
    <div className="grid gap-3 sm:grid-cols-4"><Info label="Tujuan" value={document.destination_name_snapshot} /><Info label="Expected" value={rupiah(document.total_expected_deposit)} /><Info label="Aktual" value={rupiah(document.actual_deposit_amount)} /><Info label={`Selisih · ${varianceLabel(document.variance_type)}`} value={rupiah(document.deposit_variance)} /></div>
    <div className="overflow-x-auto rounded-2xl border border-slate-200"><table className="w-full min-w-[760px] text-left text-sm"><thead className="bg-slate-50 text-xs uppercase text-slate-500"><tr><th className="px-4 py-3">Sesi / Kasir</th><th className="px-4 py-3">Kas tutup</th><th className="px-4 py-3">Alokasi sebelumnya</th><th className="px-4 py-3">Saldo berikutnya</th><th className="px-4 py-3">Expected setor</th></tr></thead><tbody className="divide-y divide-slate-100">{lines.map((line) => <tr key={line.id}><td className="px-4 py-3"><strong className="block">{line.session_code_snapshot}</strong><span className="text-xs text-slate-500">{line.cashier_name_snapshot}</span></td><td className="px-4 py-3">{rupiah(line.closing_cash_actual_snapshot)}</td><td className="px-4 py-3">{rupiah(line.posted_deposit_allocations_snapshot)}</td><td className="px-4 py-3">{rupiah(line.next_session_float_reserved)}</td><td className="px-4 py-3 font-black">{rupiah(line.expected_deposit_amount)}</td></tr>)}</tbody></table></div>
    <div className="grid gap-3 sm:grid-cols-2"><Info label="Waktu setor" value={dateTime(document.deposit_at)} /><Info label="Mode bukti" value={document.proof_mode_snapshot} />{document.evidence_url && <a href={document.evidence_url} target="_blank" rel="noreferrer" className="rounded-xl border border-emerald-200 bg-emerald-50 p-3 text-sm font-black text-emerald-700">Buka bukti setoran ↗</a>}<Info label="Catatan" value={document.notes || '-'} /></div>
    {document.rejection_reason && <p className="rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-700"><b>Alasan ditolak:</b> {document.rejection_reason}</p>}
  </div><footer className="flex flex-wrap items-center justify-between gap-3 border-t border-slate-200 p-5"><p className="text-xs text-slate-500">Approval tidak berarti dana sudah direkonsiliasi dengan rekening bank.</p><div className="flex gap-2"><button type="button" onClick={close} className="min-h-10 rounded-xl border border-slate-200 px-4 font-bold">Tutup</button>{canApprove && document.status === 'SUBMITTED' && <><button type="button" onClick={() => act('REJECT')} className="inline-flex min-h-10 items-center gap-2 rounded-xl border border-rose-200 px-4 font-black text-rose-700"><XCircle className="h-4 w-4" /> Tolak</button><button type="button" onClick={() => act('APPROVE')} className="inline-flex min-h-10 items-center gap-2 rounded-xl bg-emerald-600 px-4 font-black text-white"><CheckCircle2 className="h-4 w-4" /> Setujui</button></>}</div></footer></section></div>
}

function ReviewDialog({ session, action, close, completed }: { session: Session; action: { type: 'APPROVE' | 'REJECT'; document: DepositDocument }; close: () => void; completed: (message: string) => Promise<void> }) {
  const [reason, setReason] = useState('')
  const [confirmed, setConfirmed] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [idempotencyKey] = useState(() => crypto.randomUUID())
  async function submit() {
    if (action.type === 'REJECT' && !reason.trim()) return setError('Alasan penolakan wajib diisi.')
    if (!confirmed) return setError('Centang konfirmasi untuk melanjutkan.')
    setBusy(true); setError('')
    try {
      const response = await fetch(`/api/finance/cash-deposits/${action.document.id}/review`, {
        method: 'POST', headers: { ...authHeaders(session), 'Content-Type': 'application/json' },
        body: JSON.stringify({
          action: action.type,
          ...(action.type === 'REJECT' ? { reason } : {}),
          masterVersion: Number(action.document.master_version),
          idempotencyKey,
        }),
      })
      const result = (await response.json()) as { error?: string }
      if (!response.ok) throw new Error(friendlyError(result.error))
      await completed(action.type === 'APPROVE' ? 'Setor Kas berhasil disetujui.' : 'Setor Kas berhasil ditolak.')
    } catch (caught) { setError(caught instanceof Error ? caught.message : 'Review gagal.') }
    finally { setBusy(false) }
  }
  return <div className="fixed inset-0 z-[60] grid place-items-center bg-slate-950/70 p-4"><section role="dialog" aria-modal="true" className="w-full max-w-lg rounded-3xl bg-white p-6 shadow-2xl"><div className="flex items-start justify-between"><div><p className={`text-xs font-bold uppercase tracking-wider ${action.type === 'APPROVE' ? 'text-emerald-600' : 'text-rose-600'}`}>Konfirmasi review</p><h3 className="mt-1 text-2xl font-black">{action.type === 'APPROVE' ? 'Setujui Setor Kas?' : 'Tolak Setor Kas?'}</h3></div><button type="button" onClick={close} disabled={busy} className="rounded-xl bg-slate-100 p-2"><X className="h-5 w-5" /></button></div><div className="my-5 rounded-2xl bg-slate-50 p-4"><strong className="block">{action.document.deposit_no}</strong><span className="mt-1 block text-sm text-slate-500">Aktual {rupiah(action.document.actual_deposit_amount)} · selisih {rupiah(action.document.deposit_variance)}</span></div>{action.type === 'REJECT' && <label className="block text-sm font-black">Alasan penolakan<textarea value={reason} onChange={(event) => setReason(event.target.value)} rows={3} maxLength={1000} className="mt-2 w-full rounded-xl border border-slate-200 p-3 font-normal outline-none focus:border-rose-500" /></label>}<label className="mt-4 flex cursor-pointer items-start gap-3 rounded-xl border border-slate-200 p-3 text-sm font-semibold"><input type="checkbox" checked={confirmed} onChange={(event) => setConfirmed(event.target.checked)} className="mt-0.5 h-4 w-4 accent-emerald-600" /><span>{action.type === 'APPROVE' ? 'Saya sudah memeriksa sesi, nominal fisik, tujuan, dan bukti setoran.' : 'Saya memastikan dokumen perlu dikembalikan kepada pembuat.'}</span></label>{error && <p className="mt-4 rounded-xl bg-rose-50 p-3 text-sm font-semibold text-rose-700">{error}</p>}<div className="mt-5 flex justify-end gap-2"><button type="button" onClick={close} disabled={busy} className="min-h-10 rounded-xl border border-slate-200 px-4 font-bold">Batal</button><button type="button" onClick={() => void submit()} disabled={busy} className={`inline-flex min-h-10 items-center gap-2 rounded-xl px-4 font-black text-white ${action.type === 'APPROVE' ? 'bg-emerald-600' : 'bg-rose-600'}`}>{busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <BanknoteArrowUp className="h-4 w-4" />}{busy ? 'Memproses...' : action.type === 'APPROVE' ? 'Ya, setujui' : 'Ya, tolak'}</button></div></section></div>
}

function StatusPill({ status }: { status: DepositStatus }) {
  const style = status === 'APPROVED' ? 'bg-emerald-100 text-emerald-800' : status === 'SUBMITTED' ? 'bg-amber-100 text-amber-800' : status === 'REJECTED' ? 'bg-rose-100 text-rose-800' : 'bg-slate-100 text-slate-700'
  return <span className={`inline-flex rounded-full px-2.5 py-1 text-xs font-black ${style}`}>{statusLabel(status)}</span>
}
function Summary({ label, value, tone }: { label: string; value: number; tone: 'amber' | 'emerald' | 'rose' }) {
  const colors = { amber: 'border-amber-200 bg-amber-50 text-amber-800', emerald: 'border-emerald-200 bg-emerald-50 text-emerald-800', rose: 'border-rose-200 bg-rose-50 text-rose-800' }
  return <div className={`rounded-2xl border p-4 ${colors[tone]}`}><p className="text-xs font-bold uppercase tracking-wider">{label}</p><p className="mt-2 text-3xl font-black">{value}</p></div>
}
function Info({ label, value }: { label: string; value: string }) {
  return <div className="rounded-xl border border-slate-200 bg-slate-50 p-3"><p className="text-[10px] font-bold uppercase tracking-wider text-slate-500">{label}</p><p className="mt-1 break-words text-sm font-black text-slate-900">{value}</p></div>
}
