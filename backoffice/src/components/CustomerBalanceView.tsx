'use client'

import { useCallback, useEffect, useMemo, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import {
  ArrowDownLeft, ArrowUpRight, CheckCircle2, Eye, Loader2,
  Plus, RefreshCcw, Search, X, XCircle,
} from 'lucide-react'
import { useEscapeClose } from '@/lib/use-escape-close'

type Customer = { id: string; name: string; current_balance: number; is_active: boolean }
type Store = { id: string; store_name: string }
type Actor = { id: string; name: string | null; email: string | null }
type Correction = {
  id: string; customer_id: string; store_id: string; request_no: string
  direction: 'CREDIT' | 'DEBIT'; amount: number; source_account_function: string
  reason: string; evidence_url: string | null; status: 'SUBMITTED' | 'APPROVED' | 'REJECTED'
  created_by: string; reviewed_by: string | null; created_at: string
  reviewed_at: string | null; rejection_reason: string | null; master_version: number
}
type Payload = {
  currentUserId: string
  customers: Customer[]
  requests: Correction[]
  stores: Store[]
  actors: Actor[]
  policy: { lifecycle_state: 'ACTIVE' | 'WIND_DOWN' | 'DISABLED' } | null
}
type StatementEntry = {
  ledgerEntryId: string; entryNo: number; direction: 'CREDIT' | 'DEBIT'
  amount: number; balanceBefore: number; balanceAfter: number
  sourceReference: string; reason: string; storeId: string | null
  actorId: string; createdAt: string
}
type Statement = { customerId: string; customerName: string; currentBalance: number; entries: StatementEntry[] }
type Action =
  | { type: 'REQUEST'; customer?: Customer }
  | { type: 'REVIEW'; request: Correction; decision: 'APPROVE' | 'REJECT' }
  | { type: 'STATEMENT'; customer: Customer }
  | null

const rupiah = (value: number) => new Intl.NumberFormat('id-ID', {
  style: 'currency', currency: 'IDR', maximumFractionDigits: 0,
}).format(Number(value) || 0)
const dateTime = (value: string | null) => value
  ? new Date(value).toLocaleString('id-ID', { dateStyle: 'medium', timeStyle: 'short' })
  : '-'
const authHeaders = (session: Session) => ({ Authorization: `Bearer ${session.access_token}` })

const errorLabels: Record<string, string> = {
  CUSTOMER_BALANCE_CREDIT_DISABLED: 'Penambahan saldo sedang dinonaktifkan untuk Company ini.',
  CUSTOMER_BALANCE_DEBIT_DISABLED: 'Pengurangan saldo sedang dinonaktifkan untuk Company ini.',
  INSUFFICIENT_CUSTOMER_BALANCE: 'Saldo Customer tidak cukup untuk pengurangan ini.',
  MAKER_CANNOT_REVIEW_OWN_CUSTOMER_BALANCE_CORRECTION: 'Pembuat pengajuan tidak boleh menyetujui pengajuannya sendiri.',
  CUSTOMER_BALANCE_ACCOUNT_FUNCTION_NOT_CONFIGURED: 'Akun Finance untuk sumber dana ini belum dikonfigurasi.',
  CUSTOMER_BALANCE_TRANSACTION_CATEGORY_NOT_FOUND: 'Kategori transaksi Customer Balance belum tersedia.',
  MASTER_VERSION_CONFLICT: 'Data sudah berubah. Muat ulang sebelum melanjutkan.',
}
const friendlyError = (code?: string) => errorLabels[code ?? ''] ?? code ?? 'Operasi gagal.'

export function CustomerBalanceView({
  session, canRequest, canReview, notify,
}: {
  session: Session
  companyId: string
  canRequest: boolean
  canReview: boolean
  notify: (message: string) => void
}) {
  const [payload, setPayload] = useState<Payload | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [query, setQuery] = useState('')
  const [status, setStatus] = useState('ALL')
  const [action, setAction] = useState<Action>(null)

  const load = useCallback(async () => {
    setLoading(true); setError('')
    try {
      const response = await fetch('/api/finance/customer-balances', {
        headers: authHeaders(session), cache: 'no-store',
      })
      const result = await response.json() as Payload & { error?: string }
      if (!response.ok) throw new Error(friendlyError(result.error))
      setPayload(result)
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Gagal memuat saldo Customer.')
    } finally { setLoading(false) }
  }, [session])
  useEffect(() => {
    const timer = window.setTimeout(() => { void load() }, 0)
    return () => window.clearTimeout(timer)
  }, [load])

  const customerNames = useMemo(() => new Map(
    (payload?.customers ?? []).map((row) => [row.id, row.name]),
  ), [payload])
  const storeNames = useMemo(() => new Map(
    (payload?.stores ?? []).map((row) => [row.id, row.store_name]),
  ), [payload])
  const actorNames = useMemo(() => new Map(
    (payload?.actors ?? []).map((row) => [row.id, row.name ?? row.email ?? 'User internal']),
  ), [payload])
  const requests = useMemo(() => (payload?.requests ?? []).filter((row) => {
    const haystack = `${row.request_no} ${customerNames.get(row.customer_id) ?? ''}`.toLowerCase()
    return haystack.includes(query.trim().toLowerCase()) && (status === 'ALL' || row.status === status)
  }), [payload, customerNames, query, status])
  const totalLiability = (payload?.customers ?? []).reduce(
    (sum, customer) => sum + Number(customer.current_balance), 0,
  )
  const pending = (payload?.requests ?? []).filter((row) => row.status === 'SUBMITTED').length
  const policyLabel = payload?.policy?.lifecycle_state === 'ACTIVE' ? 'Aktif'
    : payload?.policy?.lifecycle_state === 'WIND_DOWN' ? 'Penghentian bertahap' : 'Nonaktif'

  async function completed(message: string) {
    setAction(null); notify(message); await load()
  }

  return <>
    <div className="mb-6 flex flex-wrap items-start justify-between gap-4">
      <div><p className="text-xs font-black uppercase tracking-[0.2em] text-violet-600">Finance</p><h1 className="mt-1 text-3xl font-black">Saldo Customer</h1><p className="mt-2 max-w-3xl text-sm text-slate-600">Liability Company kepada Customer. Perubahan saldo selalu melalui pengajuan dan persetujuan user berbeda.</p></div>
      {canRequest && <button type="button" onClick={() => setAction({ type: 'REQUEST' })} className="inline-flex min-h-11 items-center gap-2 rounded-xl bg-violet-600 px-4 font-black text-white shadow-sm"><Plus className="h-4 w-4" /> Ajukan koreksi</button>}
    </div>
    <div className="grid gap-4 sm:grid-cols-3">
      <Summary label="Total saldo Customer" value={rupiah(totalLiability)} />
      <Summary label="Menunggu persetujuan" value={String(pending)} />
      <Summary label="Status fitur" value={policyLabel} />
    </div>
    <div className="mt-6 rounded-2xl border border-slate-200 bg-white shadow-sm">
      <div className="flex flex-wrap items-center gap-3 border-b border-slate-200 p-4">
        <label className="relative min-w-[240px] flex-1"><Search className="pointer-events-none absolute left-3 top-3.5 h-4 w-4 text-slate-400" /><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Cari Customer atau nomor pengajuan" className="min-h-11 w-full rounded-xl border border-slate-200 pl-10 pr-3 text-sm" /></label>
        <select value={status} onChange={(event) => setStatus(event.target.value)} className="min-h-11 rounded-xl border border-slate-200 bg-white px-3 text-sm font-bold"><option value="ALL">Semua status</option><option value="SUBMITTED">Menunggu</option><option value="APPROVED">Disetujui</option><option value="REJECTED">Ditolak</option></select>
        <button type="button" onClick={() => void load()} disabled={loading} aria-label="Muat ulang" className="grid h-11 w-11 place-items-center rounded-xl border border-slate-200"><RefreshCcw className={`h-4 w-4 ${loading ? 'animate-spin' : ''}`} /></button>
      </div>
      {error && <p className="m-4 rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-700">{error}</p>}
      {loading && !payload ? <div className="grid min-h-48 place-items-center"><Loader2 className="h-7 w-7 animate-spin text-violet-600" /></div> : <div className="overflow-x-auto"><table className="w-full min-w-[980px] text-left text-sm"><thead className="bg-slate-50 text-xs uppercase tracking-wider text-slate-500"><tr><th className="px-5 py-4">Pengajuan</th><th className="px-5 py-4">Customer</th><th className="px-5 py-4">Perubahan</th><th className="px-5 py-4">Toko</th><th className="px-5 py-4">Status</th><th className="px-5 py-4">Aksi</th></tr></thead><tbody className="divide-y divide-slate-100">{requests.map((row) => <tr key={row.id}><td className="px-5 py-4"><strong>{row.request_no}</strong><span className="mt-1 block text-xs text-slate-500">{actorNames.get(row.created_by) ?? 'User'} · {dateTime(row.created_at)}</span></td><td className="px-5 py-4 font-bold">{customerNames.get(row.customer_id) ?? 'Customer'}</td><td className="px-5 py-4"><span className={`inline-flex items-center gap-1 font-black ${row.direction === 'CREDIT' ? 'text-emerald-700' : 'text-rose-700'}`}>{row.direction === 'CREDIT' ? <ArrowUpRight className="h-4 w-4" /> : <ArrowDownLeft className="h-4 w-4" />}{row.direction === 'CREDIT' ? 'Tambah' : 'Kurangi'} {rupiah(row.amount)}</span><span className="mt-1 block max-w-xs truncate text-xs text-slate-500">{row.reason}</span></td><td className="px-5 py-4">{storeNames.get(row.store_id) ?? '-'}</td><td className="px-5 py-4"><Status status={row.status} /></td><td className="px-5 py-4"><div className="flex gap-2"><button type="button" onClick={() => { const customer = payload?.customers.find((item) => item.id === row.customer_id); if (customer) setAction({ type: 'STATEMENT', customer }) }} className="inline-flex min-h-9 items-center gap-1 rounded-lg border border-slate-200 px-3 font-bold"><Eye className="h-4 w-4" /> Riwayat</button>{canReview && row.status === 'SUBMITTED' && row.created_by !== payload?.currentUserId && <><button type="button" onClick={() => setAction({ type: 'REVIEW', request: row, decision: 'REJECT' })} className="min-h-9 rounded-lg border border-rose-200 px-3 font-bold text-rose-700">Tolak</button><button type="button" onClick={() => setAction({ type: 'REVIEW', request: row, decision: 'APPROVE' })} className="min-h-9 rounded-lg bg-emerald-600 px-3 font-bold text-white">Setujui</button></>}</div></td></tr>)}{!requests.length && <tr><td colSpan={6} className="p-10 text-center text-slate-500">Belum ada pengajuan yang sesuai filter.</td></tr>}</tbody></table></div>}
    </div>
    <div className="mt-6 rounded-2xl border border-slate-200 bg-white p-5"><h2 className="font-black">Saldo per Customer</h2><div className="mt-3 grid gap-3 sm:grid-cols-2 xl:grid-cols-3">{(payload?.customers ?? []).map((customer) => <button key={customer.id} type="button" onClick={() => setAction({ type: 'STATEMENT', customer })} className="flex items-center justify-between rounded-xl border border-slate-200 p-4 text-left hover:border-violet-300"><span><strong className="block">{customer.name}</strong><span className="mt-1 block text-xs text-slate-500">{customer.is_active ? 'Aktif' : 'Tidak aktif'}</span></span><strong>{rupiah(customer.current_balance)}</strong></button>)}</div></div>
    {action?.type === 'REQUEST' && payload && <RequestDialog payload={payload} initialCustomer={action.customer} session={session} close={() => setAction(null)} completed={completed} />}
    {action?.type === 'REVIEW' && <ReviewDialog session={session} request={action.request} decision={action.decision} close={() => setAction(null)} completed={completed} />}
    {action?.type === 'STATEMENT' && <StatementDialog session={session} customer={action.customer} stores={storeNames} close={() => setAction(null)} />}
  </>
}

function RequestDialog({ payload, initialCustomer, session, close, completed }: { payload: Payload; initialCustomer?: Customer; session: Session; close: () => void; completed: (message: string) => Promise<void> }) {
  const [customerId, setCustomerId] = useState(initialCustomer?.id ?? '')
  const [storeId, setStoreId] = useState(payload.stores[0]?.id ?? '')
  const [direction, setDirection] = useState<'CREDIT' | 'DEBIT'>('CREDIT')
  const [amount, setAmount] = useState('')
  const [source, setSource] = useState('CASH_DRAWER')
  const [reason, setReason] = useState('')
  const [evidenceUrl, setEvidenceUrl] = useState('')
  const [confirmed, setConfirmed] = useState(false)
  const [busy, setBusy] = useState(false); const [error, setError] = useState('')
  const [idempotencyKey] = useState(() => crypto.randomUUID())
  useEscapeClose(() => { if (!busy) close() })
  const selected = payload.customers.find((row) => row.id === customerId)
  function changeDirection(next: 'CREDIT' | 'DEBIT') { setDirection(next); setSource(next === 'CREDIT' ? 'CASH_DRAWER' : 'CUSTOMER_RECEIVABLE') }
  async function submit() {
    const value = Number(amount)
    if (!customerId || !storeId) return setError('Pilih Customer dan Toko.')
    if (!Number.isFinite(value) || value <= 0) return setError('Nominal harus lebih dari nol.')
    if (direction === 'DEBIT' && value > Number(selected?.current_balance ?? 0)) return setError('Pengurangan tidak boleh melebihi saldo Customer.')
    if (!reason.trim()) return setError('Alasan koreksi wajib diisi.')
    if (!confirmed) return setError('Centang konfirmasi sebelum mengajukan.')
    setBusy(true); setError('')
    try {
      const response = await fetch('/api/finance/customer-balances/corrections', { method: 'POST', headers: { ...authHeaders(session), 'Content-Type': 'application/json' }, body: JSON.stringify({ customerId, storeId, direction, amount: value, sourceAccountFunction: source, reason, evidenceUrl: evidenceUrl || null, idempotencyKey }) })
      const result = await response.json() as { error?: string }
      if (!response.ok) throw new Error(friendlyError(result.error))
      await completed('Pengajuan koreksi saldo dikirim untuk persetujuan.')
    } catch (caught) { setError(caught instanceof Error ? caught.message : 'Pengajuan gagal.') } finally { setBusy(false) }
  }
  const field = 'mt-2 min-h-11 w-full rounded-xl border border-slate-200 bg-white px-3 font-normal'
  return <Dialog title="Ajukan koreksi saldo" subtitle="Belum mengubah saldo" close={close} busy={busy}><label className="block text-sm font-black">Customer<select value={customerId} onChange={(event) => setCustomerId(event.target.value)} className={field}><option value="">Pilih Customer</option>{payload.customers.map((row) => <option key={row.id} value={row.id}>{row.name} · saldo {rupiah(row.current_balance)}</option>)}</select></label><label className="mt-4 block text-sm font-black">Toko sumber<select value={storeId} onChange={(event) => setStoreId(event.target.value)} className={field}><option value="">Pilih Toko</option>{payload.stores.map((row) => <option key={row.id} value={row.id}>{row.store_name}</option>)}</select></label><div className="mt-4"><span className="text-sm font-black">Jenis koreksi</span><div className="mt-2 grid grid-cols-2 gap-2"><Choice active={direction === 'CREDIT'} onClick={() => changeDirection('CREDIT')} title="Tambah saldo" note="Company berutang lebih besar" /><Choice active={direction === 'DEBIT'} onClick={() => changeDirection('DEBIT')} title="Kurangi saldo" note="Kewajiban Company berkurang" /></div></div><label className="mt-4 block text-sm font-black">Nominal<input type="number" min="0.01" step="0.01" value={amount} onChange={(event) => setAmount(event.target.value)} className={field} /></label><label className="mt-4 block text-sm font-black">Sumber / penyelesaian<select value={source} onChange={(event) => setSource(event.target.value)} className={field}>{direction === 'CREDIT' ? <><option value="CASH_DRAWER">Titipan tunai diterima</option><option value="BANK">Titipan transfer diterima</option></> : <><option value="CUSTOMER_RECEIVABLE">Koreksi kewajiban Customer</option><option value="CASH_DRAWER">Pengembalian tunai</option><option value="BANK">Pengembalian transfer</option></>}</select></label><label className="mt-4 block text-sm font-black">Alasan koreksi<textarea rows={3} maxLength={1000} value={reason} onChange={(event) => setReason(event.target.value)} className={`${field} py-3`} /></label><label className="mt-4 block text-sm font-black">Link bukti HTTPS (opsional)<input type="url" value={evidenceUrl} onChange={(event) => setEvidenceUrl(event.target.value)} placeholder="https://drive.google.com/..." className={field} /></label><label className="mt-4 flex gap-3 rounded-xl border border-slate-200 p-3 text-sm font-semibold"><input type="checkbox" checked={confirmed} onChange={(event) => setConfirmed(event.target.checked)} className="mt-0.5 h-4 w-4 accent-violet-600" /><span>Saya sudah memeriksa Customer, Toko, nominal, sumber dana, dan bukti. Reviewer berbeda harus menyetujui.</span></label>{error && <ErrorText>{error}</ErrorText>}<Actions busy={busy} close={close} submit={() => void submit()} label="Kirim pengajuan" /></Dialog>
}

function ReviewDialog({ session, request, decision, close, completed }: { session: Session; request: Correction; decision: 'APPROVE' | 'REJECT'; close: () => void; completed: (message: string) => Promise<void> }) {
  const [reason, setReason] = useState(''); const [confirmed, setConfirmed] = useState(false); const [busy, setBusy] = useState(false); const [error, setError] = useState(''); const [idempotencyKey] = useState(() => crypto.randomUUID())
  useEscapeClose(() => { if (!busy) close() })
  async function submit() {
    if (decision === 'REJECT' && !reason.trim()) return setError('Alasan penolakan wajib diisi.')
    if (!confirmed) return setError('Centang konfirmasi sebelum melanjutkan.')
    setBusy(true); setError('')
    try { const response = await fetch(`/api/finance/customer-balances/corrections/${request.id}/review`, { method: 'POST', headers: { ...authHeaders(session), 'Content-Type': 'application/json' }, body: JSON.stringify({ masterVersion: Number(request.master_version), action: decision, reason: decision === 'REJECT' ? reason : null, idempotencyKey }) }); const result = await response.json() as { error?: string }; if (!response.ok) throw new Error(friendlyError(result.error)); await completed(decision === 'APPROVE' ? 'Koreksi disetujui dan saldo diperbarui.' : 'Pengajuan koreksi ditolak.') } catch (caught) { setError(caught instanceof Error ? caught.message : 'Review gagal.') } finally { setBusy(false) }
  }
  return <Dialog title={decision === 'APPROVE' ? 'Setujui koreksi?' : 'Tolak koreksi?'} subtitle={request.request_no} close={close} busy={busy}><div className="rounded-xl bg-slate-50 p-4"><strong className="block text-lg">{request.direction === 'CREDIT' ? 'Tambah' : 'Kurangi'} {rupiah(request.amount)}</strong><p className="mt-1 text-sm text-slate-600">{request.reason}</p></div>{decision === 'REJECT' && <label className="mt-4 block text-sm font-black">Alasan penolakan<textarea rows={3} maxLength={1000} value={reason} onChange={(event) => setReason(event.target.value)} className="mt-2 min-h-24 w-full rounded-xl border border-slate-200 p-3 font-normal" /></label>}<label className="mt-4 flex gap-3 rounded-xl border border-slate-200 p-3 text-sm font-semibold"><input type="checkbox" checked={confirmed} onChange={(event) => setConfirmed(event.target.checked)} className="mt-0.5 h-4 w-4 accent-violet-600" /><span>{decision === 'APPROVE' ? 'Saya bukan pembuat dan sudah memeriksa nominal, sumber, alasan, serta bukti.' : 'Saya memastikan pengajuan harus dikembalikan kepada pembuat.'}</span></label>{error && <ErrorText>{error}</ErrorText>}<Actions busy={busy} close={close} submit={() => void submit()} label={decision === 'APPROVE' ? 'Ya, setujui' : 'Ya, tolak'} danger={decision === 'REJECT'} /></Dialog>
}

function StatementDialog({ session, customer, stores, close }: { session: Session; customer: Customer; stores: Map<string, string>; close: () => void }) {
  const [statement, setStatement] = useState<Statement | null>(null); const [loading, setLoading] = useState(true); const [error, setError] = useState('')
  useEscapeClose(close)
  useEffect(() => { void (async () => { try { const response = await fetch(`/api/finance/customer-balances/${customer.id}/statement`, { headers: authHeaders(session), cache: 'no-store' }); const result = await response.json() as { data?: Statement; error?: string }; if (!response.ok) throw new Error(friendlyError(result.error)); setStatement(result.data ?? null) } catch (caught) { setError(caught instanceof Error ? caught.message : 'Statement gagal dimuat.') } finally { setLoading(false) } })() }, [customer.id, session])
  return <Dialog title={customer.name} subtitle="Riwayat Saldo Customer" close={close} busy={false}><div className="rounded-xl bg-violet-50 p-4 text-violet-900"><span className="text-xs font-bold uppercase tracking-wider">Saldo saat ini</span><strong className="mt-1 block text-2xl">{rupiah(statement?.currentBalance ?? customer.current_balance)}</strong></div>{loading ? <div className="grid min-h-40 place-items-center"><Loader2 className="h-6 w-6 animate-spin" /></div> : error ? <ErrorText>{error}</ErrorText> : <div className="mt-4 max-h-[50vh] space-y-2 overflow-y-auto">{(statement?.entries ?? []).slice().reverse().map((entry) => <div key={entry.ledgerEntryId} className="rounded-xl border border-slate-200 p-3"><div className="flex items-start justify-between gap-3"><div><strong>{entry.sourceReference}</strong><span className="mt-1 block text-xs text-slate-500">{stores.get(entry.storeId ?? '') ?? 'Company'} · {dateTime(entry.createdAt)}</span></div><strong className={entry.direction === 'CREDIT' ? 'text-emerald-700' : 'text-rose-700'}>{entry.direction === 'CREDIT' ? '+' : '-'}{rupiah(entry.amount)}</strong></div><p className="mt-2 text-sm text-slate-600">{entry.reason}</p><p className="mt-2 text-xs font-bold text-slate-500">Saldo {rupiah(entry.balanceBefore)} → {rupiah(entry.balanceAfter)}</p></div>)}{!statement?.entries.length && <p className="rounded-xl bg-slate-50 p-6 text-center text-sm text-slate-500">Belum ada mutasi saldo.</p>}</div>}<div className="mt-5 flex justify-end"><button type="button" onClick={close} className="min-h-10 rounded-xl border border-slate-200 px-4 font-bold">Tutup</button></div></Dialog>
}

function Dialog({ title, subtitle, close, busy, children }: { title: string; subtitle: string; close: () => void; busy: boolean; children: React.ReactNode }) { return <div className="fixed inset-0 z-[70] grid place-items-center bg-slate-950/70 p-4"><section role="dialog" aria-modal="true" className="max-h-[94vh] w-full max-w-xl overflow-y-auto rounded-3xl bg-white p-6 shadow-2xl"><header className="flex items-start justify-between gap-4"><div><p className="text-xs font-black uppercase tracking-wider text-violet-600">{subtitle}</p><h2 className="mt-1 text-2xl font-black">{title}</h2></div><button type="button" onClick={close} disabled={busy} aria-label="Tutup" className="grid h-10 w-10 shrink-0 place-items-center rounded-xl bg-slate-100"><X className="h-5 w-5" /></button></header><div className="mt-5">{children}</div></section></div> }
function Actions({ busy, close, submit, label, danger = false }: { busy: boolean; close: () => void; submit: () => void; label: string; danger?: boolean }) { return <div className="mt-5 flex justify-end gap-2"><button type="button" onClick={close} disabled={busy} className="min-h-10 rounded-xl border border-slate-200 px-4 font-bold">Batal</button><button type="button" onClick={submit} disabled={busy} className={`inline-flex min-h-10 items-center gap-2 rounded-xl px-4 font-black text-white ${danger ? 'bg-rose-600' : 'bg-violet-600'}`}>{busy ? <Loader2 className="h-4 w-4 animate-spin" /> : danger ? <XCircle className="h-4 w-4" /> : <CheckCircle2 className="h-4 w-4" />}{busy ? 'Memproses...' : label}</button></div> }
function Choice({ active, onClick, title, note }: { active: boolean; onClick: () => void; title: string; note: string }) { return <button type="button" onClick={onClick} className={`rounded-xl border p-3 text-left ${active ? 'border-violet-500 bg-violet-50' : 'border-slate-200'}`}><strong className="block">{title}</strong><span className="mt-1 block text-xs text-slate-500">{note}</span></button> }
function Summary({ label, value }: { label: string; value: string }) { return <div className="rounded-2xl border border-slate-200 bg-white p-4"><p className="text-xs font-bold uppercase tracking-wider text-slate-500">{label}</p><p className="mt-2 text-2xl font-black">{value}</p></div> }
function Status({ status }: { status: Correction['status'] }) { const config = status === 'APPROVED' ? ['Disetujui', 'bg-emerald-100 text-emerald-800'] : status === 'REJECTED' ? ['Ditolak', 'bg-rose-100 text-rose-800'] : ['Menunggu', 'bg-amber-100 text-amber-800']; return <span className={`inline-flex rounded-full px-2.5 py-1 text-xs font-black ${config[1]}`}>{config[0]}</span> }
function ErrorText({ children }: { children: React.ReactNode }) { return <p className="mt-4 rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-700">{children}</p> }
