'use client'

import { useCallback, useEffect, useMemo, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import {
  Banknote, CheckCircle2, Eye, Loader2, RefreshCcw,
  Search, ShieldCheck, UserRoundCheck, X, XCircle,
} from 'lucide-react'
import { useEscapeClose } from '@/lib/use-escape-close'

type ExceptionStatus =
  | 'OPEN' | 'UNDER_INVESTIGATION' | 'PARTIALLY_RESOLVED'
  | 'RESOLVED' | 'WRITTEN_OFF' | 'CANCELED'
type VarianceException = {
  id: string
  store_id: string
  cash_deposit_document_id: string
  variance_type: 'UNDER_DEPOSIT' | 'OVER_DEPOSIT'
  original_amount: number | string
  resolved_amount: number | string
  remaining_amount: number | string
  status: ExceptionStatus
  responsible_party_id: string | null
  responsible_party_reason: string | null
  responsible_party_assigned_at: string | null
  opened_at: string
  master_version: number | string
}
type ResolutionRequest = {
  id: string
  variance_exception_id: string
  request_no: string
  allocation_amount: number | string
  resolution_type: string
  settlement_account_function: string | null
  reason: string
  evidence_url: string | null
  resolution_reference: string | null
  status: 'SUBMITTED' | 'APPROVED' | 'REJECTED'
  requires_review: boolean
  created_by: string
  reviewed_by: string | null
  created_at: string
  reviewed_at: string | null
  rejection_reason: string | null
  master_version: number | string
}
type Allocation = {
  id: string
  variance_exception_id: string
  allocation_amount: number | string
  resolution_type: string
  reason: string
  evidence_url: string | null
  resolution_reference: string | null
  account_function_snapshot: string
  submitted_by: string
  reviewed_by: string
  created_at: string
}
type Deposit = {
  id: string
  deposit_no: string
  destination_type: string
  destination_name_snapshot: string
  total_expected_deposit: number | string
  actual_deposit_amount: number | string
  deposit_variance: number | string
  deposit_at: string
  evidence_url: string | null
  approved_at: string
}
type Actor = { id: string; name: string; email: string }
type Member = { user_id: string; role_code: string; profile: Actor | null }
type Payload = {
  data?: VarianceException[]
  requests?: ResolutionRequest[]
  allocations?: Allocation[]
  documents?: Deposit[]
  stores?: { id: string; store_name: string }[]
  actors?: Actor[]
  members?: Member[]
  error?: string
}
type Dialog =
  | { type: 'ASSIGN'; exception: VarianceException }
  | { type: 'RESOLVE'; exception: VarianceException }
  | { type: 'REVIEW'; request: ResolutionRequest; action: 'APPROVE' | 'REJECT' }

const resolutionLabels: Record<string, string> = {
  CASHIER_RECEIVABLE: 'Tetapkan sebagai piutang kasir',
  COMPANY_EXPENSE: 'Bebankan ke perusahaan',
  CASH_OVERAGE_INCOME: 'Akui sebagai pendapatan lain',
  REFUND_TO_SOURCE: 'Kembalikan kepada pemilik dana',
  WRITE_OFF: 'Write-off resmi',
  RECOVERED_FUNDS: 'Uang ditemukan / uang pengganti',
  SOURCE_CORRECTION: 'Koreksi sumber transaksi',
}
const statusLabels: Record<ExceptionStatus, string> = {
  OPEN: 'Terbuka', UNDER_INVESTIGATION: 'Dalam investigasi',
  PARTIALLY_RESOLVED: 'Selesai sebagian', RESOLVED: 'Selesai',
  WRITTEN_OFF: 'Write-off', CANCELED: 'Dibatalkan',
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
function friendlyError(code?: string) {
  const messages: Record<string, string> = {
    DEPOSIT_VARIANCE_EXCEPTION_NOT_FOUND: 'Exception selisih tidak ditemukan.',
    DEPOSIT_VARIANCE_EXCEPTION_NOT_RESOLVABLE: 'Selisih ini sudah final.',
    DEPOSIT_VARIANCE_EXCEPTION_NOT_INVESTIGABLE: 'Selisih ini tidak dapat diinvestigasi lagi.',
    DEPOSIT_VARIANCE_FINANCE_ACCESS_DENIED: 'Role Anda tidak boleh mengubah penyelesaian selisih.',
    DEPOSIT_VARIANCE_REVIEW_ACCESS_DENIED: 'Hanya Owner atau Admin Company yang dapat mereview keputusan ini.',
    ACTIVE_RESPONSIBLE_USER_NOT_FOUND: 'User penanggung jawab tidak aktif pada Company ini.',
    RESPONSIBLE_PARTY_REQUIRED: 'Tetapkan penanggung jawab terlebih dahulu.',
    DEPOSIT_VARIANCE_ALLOCATION_EXCEEDS_REMAINING: 'Nominal melebihi sisa selisih.',
    DEPOSIT_VARIANCE_SETTLEMENT_ACCOUNT_INVALID: 'Tujuan dana penyelesaian tidak valid.',
    RESOLUTION_REFERENCE_REQUIRED: 'Referensi penyelesaian wajib diisi.',
    RESOLUTION_EVIDENCE_MUST_USE_HTTPS: 'Link bukti harus memakai HTTPS.',
    MAKER_CANNOT_APPROVE_OWN_RESOLUTION: 'Pembuat pengajuan tidak boleh menyetujuinya sendiri.',
    MASTER_VERSION_CONFLICT: 'Data berubah di perangkat lain. Muat ulang sebelum melanjutkan.',
  }
  return messages[code ?? ''] ?? code ?? 'Operasi selisih setoran gagal.'
}

export function DepositVarianceResolutionView({
  session, companyId, canManage, canReview, notify,
}: {
  session: Session
  companyId: string
  canManage: boolean
  canReview: boolean
  notify: (message: string) => void
}) {
  const [payload, setPayload] = useState<Payload>({})
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [search, setSearch] = useState('')
  const [status, setStatus] = useState<'OPEN' | 'ALL' | ExceptionStatus>('OPEN')
  const [detail, setDetail] = useState<VarianceException | null>(null)
  const [dialog, setDialog] = useState<Dialog | null>(null)

  const load = useCallback(async () => {
    const response = await fetch('/api/finance/deposit-variances', {
      headers: authHeaders(session),
    })
    const result = (await response.json()) as Payload
    if (!response.ok) throw new Error(friendlyError(result.error))
    setPayload(result)
  }, [session])
  const refresh = useCallback(async () => {
    setLoading(true); setError('')
    try { await load() } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Gagal memuat selisih setoran.')
    } finally { setLoading(false) }
  }, [load])
  useEffect(() => {
    let canceled = false
    // Initial tenant-scoped server synchronization.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    load().catch((caught) => {
      if (!canceled) setError(caught instanceof Error ? caught.message : 'Gagal memuat selisih setoran.')
    }).finally(() => { if (!canceled) setLoading(false) })
    return () => { canceled = true }
  }, [companyId, load])
  useEscapeClose(() => {
    if (dialog) setDialog(null)
    else if (detail) setDetail(null)
  })

  const deposits = useMemo(
    () => new Map((payload.documents ?? []).map((row) => [row.id, row])),
    [payload.documents],
  )
  const stores = useMemo(
    () => new Map((payload.stores ?? []).map((row) => [row.id, row.store_name])),
    [payload.stores],
  )
  const actors = useMemo(
    () => new Map((payload.actors ?? []).map((row) => [row.id, row.name])),
    [payload.actors],
  )
  const rows = useMemo(() => (payload.data ?? []).filter((row) => {
    const isOpen = !['RESOLVED', 'WRITTEN_OFF', 'CANCELED'].includes(row.status)
    if (status === 'OPEN' && !isOpen) return false
    if (status !== 'OPEN' && status !== 'ALL' && row.status !== status) return false
    const needle = search.trim().toLowerCase()
    const deposit = deposits.get(row.cash_deposit_document_id)
    return !needle || [
      deposit?.deposit_no ?? '', stores.get(row.store_id) ?? '',
      actors.get(row.responsible_party_id ?? '') ?? '', statusLabels[row.status],
    ].some((value) => value.toLowerCase().includes(needle))
  }), [actors, deposits, payload.data, search, status, stores])
  const summary = useMemo(() => ({
    open: (payload.data ?? []).filter((row) => ![
      'RESOLVED', 'WRITTEN_OFF', 'CANCELED',
    ].includes(row.status)).length,
    pending: (payload.requests ?? []).filter((row) => row.status === 'SUBMITTED').length,
    remaining: (payload.data ?? []).filter((row) => ![
      'RESOLVED', 'WRITTEN_OFF', 'CANCELED',
    ].includes(row.status)).reduce((sum, row) => sum + Number(row.remaining_amount), 0),
  }), [payload.data, payload.requests])

  async function completed(message: string) {
    setDialog(null); setDetail(null); notify(message); await refresh()
  }

  return <div className="space-y-6">
    <div className="flex flex-col gap-4 rounded-3xl bg-slate-950 p-6 text-white md:flex-row md:items-center md:justify-between">
      <div><p className="text-xs font-bold uppercase tracking-[.18em] text-violet-300">Finance · Investigasi kas</p><h1 className="mt-2 text-3xl font-black">Selisih Setoran</h1><p className="mt-2 max-w-2xl text-sm leading-6 text-slate-400">Telusuri setoran kurang/lebih, catat penanggung jawab, dan selesaikan sisa nominal secara bertahap. Jurnal Finance masih berstatus HOLD.</p></div>
      <button type="button" onClick={() => void refresh()} disabled={loading} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-xl bg-white px-4 font-black text-slate-900 disabled:opacity-60"><RefreshCcw className={`h-4 w-4 ${loading ? 'animate-spin' : ''}`} /> Muat ulang</button>
    </div>

    <div className="grid gap-3 sm:grid-cols-3"><Summary label="Exception terbuka" value={String(summary.open)} tone="rose" /><Summary label="Menunggu persetujuan" value={String(summary.pending)} tone="amber" /><Summary label="Sisa belum selesai" value={rupiah(summary.remaining)} tone="violet" /></div>

    <div className="rounded-3xl border border-slate-200 bg-white shadow-sm">
      <div className="flex flex-col gap-3 border-b border-slate-200 p-4 sm:flex-row"><label className="relative flex-1"><Search className="absolute left-3 top-3 h-4 w-4 text-slate-400" /><input value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Cari nomor setoran, Store, penanggung jawab" className="min-h-10 w-full rounded-xl border border-slate-200 pl-9 pr-3 text-sm outline-none focus:border-violet-500" /></label><select value={status} onChange={(event) => setStatus(event.target.value as typeof status)} className="min-h-10 rounded-xl border border-slate-200 bg-white px-3 text-sm font-bold"><option value="OPEN">Masih terbuka</option><option value="UNDER_INVESTIGATION">Dalam investigasi</option><option value="PARTIALLY_RESOLVED">Selesai sebagian</option><option value="RESOLVED">Selesai</option><option value="WRITTEN_OFF">Write-off</option><option value="ALL">Semua status</option></select></div>
      {error && <p className="m-4 rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-700">{error}</p>}
      {loading ? <div className="grid min-h-56 place-items-center"><Loader2 className="h-7 w-7 animate-spin text-violet-600" /></div> : rows.length === 0 ? <div className="p-12 text-center"><ShieldCheck className="mx-auto h-10 w-10 text-emerald-500" /><p className="mt-3 font-black text-slate-900">Tidak ada selisih pada filter ini</p><p className="mt-1 text-sm text-slate-500">Setoran yang sesuai expected tidak membuat exception.</p></div> : <div className="overflow-x-auto"><table className="w-full min-w-[920px] text-left text-sm"><thead className="bg-slate-50 text-xs uppercase tracking-wider text-slate-500"><tr><th className="px-5 py-3">Setoran</th><th className="px-5 py-3">Jenis</th><th className="px-5 py-3">Awal / Sisa</th><th className="px-5 py-3">Penanggung jawab</th><th className="px-5 py-3">Status</th><th className="px-5 py-3 text-right">Detail</th></tr></thead><tbody className="divide-y divide-slate-100">{rows.map((row) => { const deposit = deposits.get(row.cash_deposit_document_id); return <tr key={row.id} className="hover:bg-slate-50"><td className="px-5 py-4"><strong className="block text-slate-900">{deposit?.deposit_no ?? 'Setoran'}</strong><span className="text-xs text-slate-500">{stores.get(row.store_id) ?? '-'} · {dateTime(row.opened_at)}</span></td><td className="px-5 py-4"><span className={`inline-flex rounded-full px-2.5 py-1 text-xs font-black ${row.variance_type === 'UNDER_DEPOSIT' ? 'bg-rose-100 text-rose-800' : 'bg-amber-100 text-amber-800'}`}>{row.variance_type === 'UNDER_DEPOSIT' ? 'Setoran kurang' : 'Setoran lebih'}</span></td><td className="px-5 py-4"><span className="block text-slate-500">{rupiah(row.original_amount)}</span><strong className="text-slate-900">Sisa {rupiah(row.remaining_amount)}</strong></td><td className="px-5 py-4">{row.responsible_party_id ? <><strong className="block">{actors.get(row.responsible_party_id) ?? 'User internal'}</strong><span className="text-xs text-slate-500">{row.responsible_party_reason}</span></> : <span className="text-slate-400">Belum ditetapkan</span>}</td><td className="px-5 py-4"><StatusPill status={row.status} /></td><td className="px-5 py-4 text-right"><button type="button" onClick={() => setDetail(row)} className="inline-flex min-h-9 items-center gap-2 rounded-lg border border-slate-200 px-3 font-bold"><Eye className="h-4 w-4" /> Lihat</button></td></tr> })}</tbody></table></div>}
    </div>

    {detail && <DetailModal exception={detail} deposit={deposits.get(detail.cash_deposit_document_id)} storeName={stores.get(detail.store_id) ?? '-'} actorNames={actors} requests={(payload.requests ?? []).filter((row) => row.variance_exception_id === detail.id)} allocations={(payload.allocations ?? []).filter((row) => row.variance_exception_id === detail.id)} canManage={canManage} canReview={canReview} currentUserId={session.user.id} close={() => setDetail(null)} act={setDialog} />}
    {dialog?.type === 'ASSIGN' && <AssignDialog session={session} exception={dialog.exception} members={payload.members ?? []} close={() => setDialog(null)} completed={completed} />}
    {dialog?.type === 'RESOLVE' && <ResolveDialog session={session} exception={dialog.exception} close={() => setDialog(null)} completed={completed} />}
    {dialog?.type === 'REVIEW' && <ReviewDialog session={session} request={dialog.request} action={dialog.action} close={() => setDialog(null)} completed={completed} />}
  </div>
}

function DetailModal({ exception, deposit, storeName, actorNames, requests, allocations, canManage, canReview, currentUserId, close, act }: { exception: VarianceException; deposit?: Deposit; storeName: string; actorNames: Map<string, string>; requests: ResolutionRequest[]; allocations: Allocation[]; canManage: boolean; canReview: boolean; currentUserId: string; close: () => void; act: (dialog: Dialog) => void }) {
  const final = ['RESOLVED', 'WRITTEN_OFF', 'CANCELED'].includes(exception.status)
  return <div className="fixed inset-0 z-50 grid place-items-center bg-slate-950/60 p-4 backdrop-blur-sm"><section role="dialog" aria-modal="true" aria-labelledby="variance-detail-title" className="flex max-h-[94vh] w-full max-w-5xl flex-col overflow-hidden rounded-3xl bg-white shadow-2xl"><header className="flex items-start justify-between border-b border-slate-200 p-5"><div><p className="text-xs font-bold uppercase tracking-wider text-violet-600">{storeName} · {exception.variance_type === 'UNDER_DEPOSIT' ? 'Setoran kurang' : 'Setoran lebih'}</p><h2 id="variance-detail-title" className="mt-1 text-2xl font-black">{deposit?.deposit_no ?? 'Selisih Setoran'}</h2><p className="mt-1 text-sm text-slate-500">Dibuka {dateTime(exception.opened_at)} · <StatusPill status={exception.status} /></p></div><button type="button" onClick={close} aria-label="Tutup detail" className="grid h-10 w-10 place-items-center rounded-xl bg-slate-100 text-slate-600"><X className="h-5 w-5" /></button></header><div className="flex-1 space-y-5 overflow-y-auto p-5">
    <div className="grid gap-3 sm:grid-cols-3"><Info label="Selisih awal" value={rupiah(exception.original_amount)} /><Info label="Sudah diselesaikan" value={rupiah(exception.resolved_amount)} /><Info label="Sisa" value={rupiah(exception.remaining_amount)} /></div>
    {deposit && <div className="grid gap-3 rounded-2xl border border-slate-200 p-4 sm:grid-cols-3"><Info label="Expected setoran" value={rupiah(deposit.total_expected_deposit)} /><Info label="Aktual disetor" value={rupiah(deposit.actual_deposit_amount)} /><Info label="Tujuan" value={deposit.destination_name_snapshot} />{deposit.evidence_url && <a href={deposit.evidence_url} target="_blank" rel="noreferrer" className="text-sm font-black text-violet-700">Buka bukti setoran ↗</a>}</div>}
    <section><h3 className="font-black text-slate-900">Penanggung jawab</h3><p className="mt-2 rounded-xl bg-slate-50 p-3 text-sm">{exception.responsible_party_id ? <><b>{actorNames.get(exception.responsible_party_id) ?? 'User internal'}</b><br />{exception.responsible_party_reason}<br /><span className="text-xs text-slate-500">Ditetapkan {dateTime(exception.responsible_party_assigned_at)}</span></> : 'Belum ditetapkan. Penanggung jawab hanya berlaku untuk setoran kurang.'}</p></section>
    <History title="Riwayat penyelesaian" empty="Belum ada nominal yang diselesaikan.">{allocations.map((row) => <HistoryRow key={row.id} title={resolutionLabels[row.resolution_type] ?? row.resolution_type} amount={rupiah(row.allocation_amount)} meta={`${actorNames.get(row.reviewed_by) ?? 'Reviewer'} · ${dateTime(row.created_at)}`} note={row.reason} url={row.evidence_url} />)}</History>
    <History title="Pengajuan menunggu keputusan" empty="Tidak ada pengajuan maker-checker.">{requests.filter((row) => row.requires_review).map((row) => <div key={row.id} className="rounded-xl border border-slate-200 p-3"><div className="flex flex-wrap items-start justify-between gap-2"><div><strong className="block">{row.request_no} · {resolutionLabels[row.resolution_type] ?? row.resolution_type}</strong><span className="text-xs text-slate-500">{actorNames.get(row.created_by) ?? 'Pembuat'} · {dateTime(row.created_at)}</span></div><span className={`rounded-full px-2.5 py-1 text-xs font-black ${row.status === 'SUBMITTED' ? 'bg-amber-100 text-amber-800' : row.status === 'APPROVED' ? 'bg-emerald-100 text-emerald-800' : 'bg-rose-100 text-rose-800'}`}>{row.status === 'SUBMITTED' ? 'Menunggu review' : row.status === 'APPROVED' ? 'Disetujui' : 'Ditolak'}</span></div><p className="mt-2 text-sm">{rupiah(row.allocation_amount)} · {row.reason}</p>{row.rejection_reason && <p className="mt-2 text-sm font-semibold text-rose-700">Alasan ditolak: {row.rejection_reason}</p>}{canReview && row.status === 'SUBMITTED' && row.created_by !== currentUserId && <div className="mt-3 flex justify-end gap-2"><button type="button" onClick={() => act({ type: 'REVIEW', request: row, action: 'REJECT' })} className="min-h-9 rounded-lg border border-rose-200 px-3 font-bold text-rose-700">Tolak</button><button type="button" onClick={() => act({ type: 'REVIEW', request: row, action: 'APPROVE' })} className="min-h-9 rounded-lg bg-emerald-600 px-3 font-bold text-white">Setujui</button></div>}</div>)}</History>
  </div><footer className="flex flex-wrap items-center justify-between gap-3 border-t border-slate-200 p-5"><p className="max-w-xl text-xs text-slate-500">Penyelesaian mencatat Financial Event HOLD. Rekonsiliasi bank dan jurnal final belum dijalankan pada fase ini.</p><div className="flex flex-wrap gap-2"><button type="button" onClick={close} className="min-h-10 rounded-xl border border-slate-200 px-4 font-bold">Tutup</button>{canManage && !final && exception.variance_type === 'UNDER_DEPOSIT' && <button type="button" onClick={() => act({ type: 'ASSIGN', exception })} className="inline-flex min-h-10 items-center gap-2 rounded-xl border border-violet-200 px-4 font-black text-violet-700"><UserRoundCheck className="h-4 w-4" /> Penanggung jawab</button>}{canManage && !final && <button type="button" onClick={() => act({ type: 'RESOLVE', exception })} className="inline-flex min-h-10 items-center gap-2 rounded-xl bg-violet-600 px-4 font-black text-white"><Banknote className="h-4 w-4" /> Catat penyelesaian</button>}</div></footer></section></div>
}

function AssignDialog({ session, exception, members, close, completed }: { session: Session; exception: VarianceException; members: Member[]; close: () => void; completed: (message: string) => Promise<void> }) {
  const [userId, setUserId] = useState(exception.responsible_party_id ?? '')
  const [reason, setReason] = useState(exception.responsible_party_reason ?? '')
  const [busy, setBusy] = useState(false); const [error, setError] = useState('')
  async function submit() {
    if (!userId || !reason.trim()) return setError('Pilih user dan isi alasan penetapan.')
    setBusy(true); setError('')
    try { const response = await fetch(`/api/finance/deposit-variances/${exception.id}/assign`, { method: 'POST', headers: { ...authHeaders(session), 'Content-Type': 'application/json' }, body: JSON.stringify({ masterVersion: Number(exception.master_version), responsibleUserId: userId, reason }) }); const result = (await response.json()) as { error?: string }; if (!response.ok) throw new Error(friendlyError(result.error)); await completed('Penanggung jawab selisih berhasil disimpan.') } catch (caught) { setError(caught instanceof Error ? caught.message : 'Gagal menetapkan user.') } finally { setBusy(false) }
  }
  return <DialogShell title="Tetapkan penanggung jawab" subtitle="Setoran kurang" close={close} busy={busy}><label className="block text-sm font-black">User internal<select value={userId} onChange={(event) => setUserId(event.target.value)} className="mt-2 min-h-11 w-full rounded-xl border border-slate-200 bg-white px-3 font-normal"><option value="">Pilih user</option>{members.map((member) => <option key={member.user_id} value={member.user_id}>{member.profile?.name ?? member.profile?.email ?? 'User'} · {member.role_code}</option>)}</select></label><label className="mt-4 block text-sm font-black">Alasan penetapan<textarea value={reason} onChange={(event) => setReason(event.target.value)} rows={3} maxLength={1000} className="mt-2 w-full rounded-xl border border-slate-200 p-3 font-normal" /></label>{error && <ErrorText>{error}</ErrorText>}<DialogActions close={close} busy={busy} submit={() => void submit()} label="Simpan penanggung jawab" /></DialogShell>
}

function ResolveDialog({ session, exception, close, completed }: { session: Session; exception: VarianceException; close: () => void; completed: (message: string) => Promise<void> }) {
  const options = exception.variance_type === 'UNDER_DEPOSIT'
    ? ['RECOVERED_FUNDS', 'CASHIER_RECEIVABLE', 'COMPANY_EXPENSE', 'WRITE_OFF', 'SOURCE_CORRECTION']
    : ['REFUND_TO_SOURCE', 'CASH_OVERAGE_INCOME', 'SOURCE_CORRECTION']
  const [type, setType] = useState(options[0]); const [amount, setAmount] = useState(String(exception.remaining_amount)); const [accountFunction, setAccountFunction] = useState('BANK'); const [reason, setReason] = useState(''); const [evidenceUrl, setEvidenceUrl] = useState(''); const [reference, setReference] = useState(''); const [confirmed, setConfirmed] = useState(false); const [busy, setBusy] = useState(false); const [error, setError] = useState(''); const [idempotencyKey] = useState(() => crypto.randomUUID())
  const settlement = ['RECOVERED_FUNDS', 'REFUND_TO_SOURCE'].includes(type)
  const referenceRequired = ['REFUND_TO_SOURCE', 'SOURCE_CORRECTION'].includes(type)
  const review = ['COMPANY_EXPENSE', 'WRITE_OFF', 'CASH_OVERAGE_INCOME', 'SOURCE_CORRECTION'].includes(type)
  async function submit() {
    const value = Number(amount)
    if (!Number.isFinite(value) || value <= 0 || value > Number(exception.remaining_amount)) return setError('Nominal harus lebih dari nol dan tidak melebihi sisa selisih.')
    if (!reason.trim()) return setError('Alasan penyelesaian wajib diisi.')
    if (referenceRequired && !reference.trim()) return setError('Referensi penyelesaian wajib diisi.')
    if (!confirmed) return setError('Centang konfirmasi untuk melanjutkan.')
    setBusy(true); setError('')
    try { const response = await fetch(`/api/finance/deposit-variances/${exception.id}/resolve`, { method: 'POST', headers: { ...authHeaders(session), 'Content-Type': 'application/json' }, body: JSON.stringify({ masterVersion: Number(exception.master_version), amount: value, resolutionType: type, settlementAccountFunction: settlement ? accountFunction : null, reason, evidenceUrl: evidenceUrl || null, resolutionReference: reference || null, idempotencyKey }) }); const result = (await response.json()) as { data?: { status?: string }; error?: string }; if (!response.ok) throw new Error(friendlyError(result.error)); await completed(result.data?.status === 'SUBMITTED' ? 'Pengajuan penyelesaian menunggu persetujuan Owner/Admin.' : 'Penyelesaian selisih berhasil dicatat.') } catch (caught) { setError(caught instanceof Error ? caught.message : 'Gagal mencatat penyelesaian.') } finally { setBusy(false) }
  }
  return <DialogShell title="Catat penyelesaian" subtitle={exception.variance_type === 'UNDER_DEPOSIT' ? 'Setoran kurang' : 'Setoran lebih'} close={close} busy={busy}><div className="rounded-xl bg-slate-50 p-3 text-sm"><span className="text-slate-500">Sisa saat ini</span><strong className="block text-lg">{rupiah(exception.remaining_amount)}</strong></div><label className="mt-4 block text-sm font-black">Cara penyelesaian<select value={type} onChange={(event) => setType(event.target.value)} className="mt-2 min-h-11 w-full rounded-xl border border-slate-200 bg-white px-3 font-normal">{options.map((option) => <option key={option} value={option}>{resolutionLabels[option]}</option>)}</select></label><label className="mt-4 block text-sm font-black">Nominal yang diselesaikan<input type="number" min="0.01" max={Number(exception.remaining_amount)} step="0.01" value={amount} onChange={(event) => setAmount(event.target.value)} className="mt-2 min-h-11 w-full rounded-xl border border-slate-200 px-3 font-normal" /></label>{settlement && <label className="mt-4 block text-sm font-black">Dana masuk/keluar melalui<select value={accountFunction} onChange={(event) => setAccountFunction(event.target.value)} className="mt-2 min-h-11 w-full rounded-xl border border-slate-200 bg-white px-3 font-normal"><option value="BANK">Bank</option><option value="MAIN_CASH">Kas utama / brankas</option><option value="CASH_IN_TRANSIT">Kas dalam perjalanan</option></select></label>}<label className="mt-4 block text-sm font-black">Alasan<textarea value={reason} onChange={(event) => setReason(event.target.value)} rows={3} maxLength={1000} className="mt-2 w-full rounded-xl border border-slate-200 p-3 font-normal" /></label><label className="mt-4 block text-sm font-black">Referensi {referenceRequired ? '(wajib)' : '(opsional)'}<input value={reference} onChange={(event) => setReference(event.target.value)} maxLength={500} placeholder="Nomor mutasi, refund, atau dokumen koreksi" className="mt-2 min-h-11 w-full rounded-xl border border-slate-200 px-3 font-normal" /></label><label className="mt-4 block text-sm font-black">Link bukti HTTPS (opsional)<input type="url" value={evidenceUrl} onChange={(event) => setEvidenceUrl(event.target.value)} maxLength={2048} placeholder="https://drive.google.com/..." className="mt-2 min-h-11 w-full rounded-xl border border-slate-200 px-3 font-normal" /></label>{review && <p className="mt-4 rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm font-semibold text-amber-800">Keputusan ini memengaruhi biaya/pendapatan atau source. Owner/Admin lain harus menyetujuinya.</p>}<label className="mt-4 flex items-start gap-3 rounded-xl border border-slate-200 p-3 text-sm font-semibold"><input type="checkbox" checked={confirmed} onChange={(event) => setConfirmed(event.target.checked)} className="mt-0.5 h-4 w-4 accent-violet-600" /><span>Saya sudah memeriksa nominal, alasan, referensi, dan bukti. Event Finance masih HOLD sampai proses G6.</span></label>{error && <ErrorText>{error}</ErrorText>}<DialogActions close={close} busy={busy} submit={() => void submit()} label={review ? 'Ajukan untuk disetujui' : 'Catat penyelesaian'} /></DialogShell>
}

function ReviewDialog({ session, request, action, close, completed }: { session: Session; request: ResolutionRequest; action: 'APPROVE' | 'REJECT'; close: () => void; completed: (message: string) => Promise<void> }) {
  const [reason, setReason] = useState(''); const [confirmed, setConfirmed] = useState(false); const [busy, setBusy] = useState(false); const [error, setError] = useState(''); const [idempotencyKey] = useState(() => crypto.randomUUID())
  async function submit() {
    if (action === 'REJECT' && !reason.trim()) return setError('Alasan penolakan wajib diisi.')
    if (!confirmed) return setError('Centang konfirmasi untuk melanjutkan.')
    setBusy(true); setError('')
    try { const response = await fetch(`/api/finance/deposit-variance-resolutions/${request.id}/review`, { method: 'POST', headers: { ...authHeaders(session), 'Content-Type': 'application/json' }, body: JSON.stringify({ masterVersion: Number(request.master_version), action, ...(action === 'REJECT' ? { reason } : {}), idempotencyKey }) }); const result = (await response.json()) as { error?: string }; if (!response.ok) throw new Error(friendlyError(result.error)); await completed(action === 'APPROVE' ? 'Penyelesaian selisih disetujui.' : 'Penyelesaian selisih ditolak.') } catch (caught) { setError(caught instanceof Error ? caught.message : 'Review gagal.') } finally { setBusy(false) }
  }
  return <DialogShell title={action === 'APPROVE' ? 'Setujui penyelesaian?' : 'Tolak penyelesaian?'} subtitle={request.request_no} close={close} busy={busy}><div className="rounded-xl bg-slate-50 p-4"><strong className="block">{resolutionLabels[request.resolution_type] ?? request.resolution_type}</strong><span className="mt-1 block text-sm">{rupiah(request.allocation_amount)} · {request.reason}</span></div>{action === 'REJECT' && <label className="mt-4 block text-sm font-black">Alasan penolakan<textarea value={reason} onChange={(event) => setReason(event.target.value)} rows={3} maxLength={1000} className="mt-2 w-full rounded-xl border border-slate-200 p-3 font-normal" /></label>}<label className="mt-4 flex items-start gap-3 rounded-xl border border-slate-200 p-3 text-sm font-semibold"><input type="checkbox" checked={confirmed} onChange={(event) => setConfirmed(event.target.checked)} className="mt-0.5 h-4 w-4 accent-violet-600" /><span>{action === 'APPROVE' ? 'Saya bukan pembuat pengajuan dan sudah memeriksa dampak keputusan ini.' : 'Saya memastikan pengajuan perlu dikembalikan kepada pembuat.'}</span></label>{error && <ErrorText>{error}</ErrorText>}<DialogActions close={close} busy={busy} submit={() => void submit()} label={action === 'APPROVE' ? 'Ya, setujui' : 'Ya, tolak'} danger={action === 'REJECT'} /></DialogShell>
}

function DialogShell({ title, subtitle, close, busy, children }: { title: string; subtitle: string; close: () => void; busy: boolean; children: React.ReactNode }) { return <div className="fixed inset-0 z-[60] grid place-items-center bg-slate-950/70 p-4"><section role="dialog" aria-modal="true" className="max-h-[94vh] w-full max-w-xl overflow-y-auto rounded-3xl bg-white p-6 shadow-2xl"><div className="flex items-start justify-between"><div><p className="text-xs font-bold uppercase tracking-wider text-violet-600">{subtitle}</p><h3 className="mt-1 text-2xl font-black">{title}</h3></div><button type="button" onClick={close} disabled={busy} aria-label="Tutup" className="grid h-10 w-10 place-items-center rounded-xl bg-slate-100"><X className="h-5 w-5" /></button></div><div className="mt-5">{children}</div></section></div> }
function DialogActions({ close, busy, submit, label, danger = false }: { close: () => void; busy: boolean; submit: () => void; label: string; danger?: boolean }) { return <div className="mt-5 flex justify-end gap-2"><button type="button" onClick={close} disabled={busy} className="min-h-10 rounded-xl border border-slate-200 px-4 font-bold">Batal</button><button type="button" onClick={submit} disabled={busy} className={`inline-flex min-h-10 items-center gap-2 rounded-xl px-4 font-black text-white ${danger ? 'bg-rose-600' : 'bg-violet-600'}`}>{busy ? <Loader2 className="h-4 w-4 animate-spin" /> : danger ? <XCircle className="h-4 w-4" /> : <CheckCircle2 className="h-4 w-4" />}{busy ? 'Memproses...' : label}</button></div> }
function History({ title, empty, children }: { title: string; empty: string; children: React.ReactNode[] }) { return <section><h3 className="font-black text-slate-900">{title}</h3><div className="mt-2 space-y-2">{children.length ? children : <p className="rounded-xl bg-slate-50 p-3 text-sm text-slate-500">{empty}</p>}</div></section> }
function HistoryRow({ title, amount, meta, note, url }: { title: string; amount: string; meta: string; note: string; url: string | null }) { return <div className="rounded-xl border border-slate-200 p-3"><div className="flex justify-between gap-3"><strong>{title}</strong><strong>{amount}</strong></div><p className="mt-1 text-sm text-slate-600">{note}</p><p className="mt-1 text-xs text-slate-500">{meta}</p>{url && <a href={url} target="_blank" rel="noreferrer" className="mt-2 inline-block text-xs font-black text-violet-700">Buka bukti ↗</a>}</div> }
function StatusPill({ status }: { status: ExceptionStatus }) { const style = status === 'RESOLVED' ? 'bg-emerald-100 text-emerald-800' : status === 'WRITTEN_OFF' ? 'bg-slate-200 text-slate-800' : status === 'PARTIALLY_RESOLVED' ? 'bg-blue-100 text-blue-800' : status === 'UNDER_INVESTIGATION' ? 'bg-violet-100 text-violet-800' : 'bg-amber-100 text-amber-800'; return <span className={`inline-flex rounded-full px-2.5 py-1 text-xs font-black ${style}`}>{statusLabels[status]}</span> }
function Summary({ label, value, tone }: { label: string; value: string; tone: 'rose' | 'amber' | 'violet' }) { const colors = { rose: 'border-rose-200 bg-rose-50 text-rose-800', amber: 'border-amber-200 bg-amber-50 text-amber-800', violet: 'border-violet-200 bg-violet-50 text-violet-800' }; return <div className={`rounded-2xl border p-4 ${colors[tone]}`}><p className="text-xs font-bold uppercase tracking-wider">{label}</p><p className="mt-2 text-2xl font-black">{value}</p></div> }
function Info({ label, value }: { label: string; value: string }) { return <div className="rounded-xl bg-slate-50 p-3"><p className="text-[10px] font-bold uppercase tracking-wider text-slate-500">{label}</p><p className="mt-1 break-words text-sm font-black text-slate-900">{value}</p></div> }
function ErrorText({ children }: { children: React.ReactNode }) { return <p className="mt-4 rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-700">{children}</p> }
