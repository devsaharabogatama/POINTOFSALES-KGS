'use client'

import { useCallback, useEffect, useMemo, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import {
  CreditCard,
  Edit3,
  Loader2,
  Plus,
  RefreshCcw,
  Search,
  X,
} from 'lucide-react'
import { useEscapeClose } from '@/lib/use-escape-close'

type StoreOption = { id: string; store_code: string; store_name: string }
type StoreAssignment = { id: string; payment_method_id: string; store_id: string }
type PaymentMethod = {
  id: string
  payment_method_code: string
  payment_method_name: string
  method_type: MethodType
  settlement_route: SettlementRoute
  is_default: boolean
  available_all_stores: boolean
  proof_mode: ProofMode
  fee_enabled: boolean
  fee_bearer: FeeBearer | null
  fee_type: FeeType | null
  fee_percent: number | string | null
  fee_fixed_amount: number | string | null
  effective_from: string
  effective_to: string | null
  is_active: boolean
  is_system_method: boolean
  master_version: number
  store_assignments: StoreAssignment[]
}
type MethodType = 'CASH' | 'TRANSFER' | 'QRIS' | 'CARD' | 'E_WALLET' | 'TEMPO' | 'CUSTOM'
type SettlementRoute = 'CASH_DRAWER' | 'DIRECT_BANK' | 'CLEARING' | 'RECEIVABLE'
type ProofMode = 'OPTIONAL' | 'REQUIRED'
type FeeBearer = 'COMPANY' | 'CUSTOMER'
type FeeType = 'PERCENT' | 'FIXED' | 'PERCENT_PLUS_FIXED'

const methodLabels: Record<string, string> = {
  CASH: 'Tunai', TRANSFER: 'Transfer bank', QRIS: 'QRIS', CARD: 'Kartu',
  E_WALLET: 'E-Wallet', TEMPO: 'Tempo / piutang', CUSTOM: 'Metode custom',
  CUSTOMER_BALANCE: 'Saldo Customer', KETUL_OFFSET: 'Potongan Ketul',
}
const routeLabels: Record<string, string> = {
  CASH_DRAWER: 'Laci kas', DIRECT_BANK: 'Langsung ke bank',
  CLEARING: 'Menunggu settlement', RECEIVABLE: 'Piutang',
  INTERNAL_LIABILITY: 'Saldo internal',
}

function authHeaders(session: Session) {
  return { Authorization: `Bearer ${session.access_token}` }
}
function rupiah(value: number | string | null) {
  return new Intl.NumberFormat('id-ID', {
    style: 'currency', currency: 'IDR', maximumFractionDigits: 0,
  }).format(Number(value) || 0)
}
function dateInput(value: string | null) {
  if (!value) return ''
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return ''
  const local = new Date(date.getTime() - date.getTimezoneOffset() * 60_000)
  return local.toISOString().slice(0, 16)
}
function friendlyError(code?: string) {
  const messages: Record<string, string> = {
    PAYMENT_METHOD_MANAGER_REQUIRED: 'Role ini tidak boleh mengubah metode pembayaran.',
    INVALID_PAYMENT_METHOD_IDENTITY: 'Nama dan kode metode wajib diisi.',
    INVALID_PAYMENT_METHOD_TYPE: 'Jenis metode pembayaran tidak valid.',
    INVALID_SETTLEMENT_ROUTE: 'Jalur penerimaan dana tidak valid.',
    PAYMENT_METHOD_ROUTE_MISMATCH: 'Jalur penerimaan tidak cocok dengan jenis metode.',
    PAYMENT_METHOD_STORE_REQUIRED: 'Pilih minimal satu toko.',
    ACTIVE_STORE_NOT_FOUND: 'Ada toko yang tidak aktif atau bukan milik Company ini.',
    DEFAULT_PAYMENT_METHOD_MUST_BE_ACTIVE: 'Metode default harus aktif.',
    ACTIVE_COMPANY_REQUIRES_ONE_DEFAULT_PAYMENT_METHOD: 'Company harus memiliki tepat satu metode default aktif.',
    FEE_REQUIRES_ELECTRONIC_SETTLEMENT: 'Fee hanya berlaku untuk pembayaran bank atau clearing.',
    INVALID_FEE_PERCENT: 'Persentase fee harus berada antara 0 sampai 100.',
    FEE_PERCENT_REQUIRED: 'Persentase fee wajib diisi.',
    FEE_FIXED_AMOUNT_REQUIRED: 'Nominal fee wajib diisi.',
    INVALID_PAYMENT_METHOD_PERIOD: 'Tanggal berakhir tidak boleh sebelum tanggal mulai.',
    MASTER_VERSION_CONFLICT: 'Data sudah diubah pengguna lain. Muat ulang lalu coba lagi.',
    PAYMENT_METHOD_CODE_LOCKED_BY_HISTORY: 'Identitas metode tidak dapat diubah karena sudah memiliki histori transaksi.',
    DUPLICATE_OR_DEFAULT_PAYMENT_METHOD_CONFLICT: 'Nama sudah dipakai atau konfigurasi default bertabrakan.',
    PAYMENT_METHOD_VALIDATION_FAILED: 'Konfigurasi metode belum konsisten. Periksa jenis, jalur dana, dan fee.',
  }
  return messages[code ?? ''] ?? code ?? 'Operasi metode pembayaran gagal.'
}

export function PaymentMethodMasterView({
  session, companyId, canManage, notify,
}: {
  session: Session
  companyId: string
  canManage: boolean
  notify: (message: string | null) => void
}) {
  const [methods, setMethods] = useState<PaymentMethod[]>([])
  const [stores, setStores] = useState<StoreOption[]>([])
  const [query, setQuery] = useState('')
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [editor, setEditor] = useState<PaymentMethod | null | undefined>(undefined)

  const refresh = useCallback(async () => {
    setLoading(true); setError('')
    try {
      const response = await fetch('/api/master/payment-methods?includeInactive=true', {
        headers: authHeaders(session), cache: 'no-store',
      })
      const payload = await response.json() as {
        data?: PaymentMethod[]; stores?: StoreOption[]; error?: string
      }
      if (!response.ok) throw new Error(friendlyError(payload.error))
      setMethods(payload.data ?? []); setStores(payload.stores ?? [])
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Gagal memuat metode pembayaran.')
    } finally { setLoading(false) }
  }, [session])

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- master loading follows the active tenant context
    void refresh()
  }, [companyId, refresh])

  const storeById = useMemo(() => new Map(stores.map((item) => [item.id, item])), [stores])
  const normalized = query.trim().toLowerCase()
  const filtered = methods.filter((item) => !normalized || [
    item.payment_method_name, methodLabels[item.method_type], routeLabels[item.settlement_route],
  ].some((value) => value?.toLowerCase().includes(normalized)))

  return <>
    <div className="mb-7 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
      <div><p className="text-xs font-bold uppercase tracking-[.16em] text-emerald-600">Master Penjualan</p><h1 className="mt-2 text-2xl font-black tracking-tight text-slate-950 md:text-3xl">Metode Pembayaran</h1><p className="mt-2 text-sm text-slate-500">Atur metode yang tersedia, toko pemakai, bukti pembayaran, jalur dana, dan perkiraan fee.</p></div>
      <div className="flex gap-2"><button onClick={() => void refresh()} className="inline-flex items-center gap-2 rounded-xl border border-slate-200 bg-white px-4 py-3 text-sm font-bold text-slate-600"><RefreshCcw className={`h-4 w-4 ${loading ? 'animate-spin' : ''}`} /> Muat ulang</button>{canManage && <button onClick={() => setEditor(null)} className="inline-flex items-center gap-2 rounded-xl bg-emerald-500 px-4 py-3 text-sm font-bold text-white"><Plus className="h-4 w-4" /> Tambah Metode</button>}</div>
    </div>
    <div className="mb-5 rounded-2xl border border-blue-100 bg-blue-50 p-4 text-sm leading-6 text-blue-800"><b>Belum terhubung ke checkout.</b> Konfigurasi ini baru menyiapkan master. Fee yang tampil adalah perkiraan konfigurasi; fee aktual tetap ditentukan saat settlement/reconciliation.</div>
    {error && <div className="mb-5 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-700">{error}</div>}
    <div className="rounded-2xl border border-slate-200 bg-white shadow-sm">
      <div className="flex items-center gap-3 border-b border-slate-100 p-4"><Search className="h-4 w-4 text-slate-400" /><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Cari nama atau jenis pembayaran..." className="w-full bg-transparent text-sm outline-none" /></div>
      <div className="overflow-x-auto"><table className="w-full min-w-[1050px] text-left text-sm"><thead className="bg-slate-50 text-xs uppercase tracking-wider text-slate-500"><tr><th className="px-5 py-4">Metode</th><th className="px-5 py-4">Dana diterima melalui</th><th className="px-5 py-4">Berlaku di</th><th className="px-5 py-4">Fee konfigurasi</th><th className="px-5 py-4">Bukti</th><th className="px-5 py-4">Status</th>{canManage && <th className="px-5 py-4 text-right">Aksi</th>}</tr></thead><tbody className="divide-y divide-slate-100">{filtered.map((item) => {
        const assigned = item.store_assignments.map((row) => storeById.get(row.store_id)?.store_name).filter(Boolean)
        const fee = !item.fee_enabled ? 'Tanpa fee' : item.fee_type === 'PERCENT' ? `${Number(item.fee_percent)}%` : item.fee_type === 'FIXED' ? rupiah(item.fee_fixed_amount) : `${Number(item.fee_percent)}% + ${rupiah(item.fee_fixed_amount)}`
        return <tr key={item.id}><td className="px-5 py-4"><p className="font-bold">{item.payment_method_name}{item.is_default && <span className="ml-2 rounded-full bg-violet-50 px-2 py-1 text-[10px] text-violet-700">Default</span>}</p><p className="mt-1 text-xs text-slate-400">{methodLabels[item.method_type] ?? item.method_type}</p></td><td className="px-5 py-4">{routeLabels[item.settlement_route] ?? item.settlement_route}</td><td className="px-5 py-4">{item.available_all_stores ? 'Semua toko' : assigned.join(', ') || '-'}</td><td className="px-5 py-4"><p className="font-semibold">{fee}</p>{item.fee_enabled && <p className="mt-1 text-xs text-slate-400">Ditanggung {item.fee_bearer === 'CUSTOMER' ? 'Customer' : 'Company'}</p>}</td><td className="px-5 py-4">{item.proof_mode === 'REQUIRED' ? 'Wajib' : 'Opsional'}</td><td className="px-5 py-4"><Status active={item.is_active} /></td>{canManage && <td className="px-5 py-4 text-right">{!item.is_system_method && <button onClick={() => setEditor(item)} className="rounded-lg border border-slate-200 p-2 text-slate-500 hover:text-emerald-600" aria-label={`Edit ${item.payment_method_name}`}><Edit3 className="h-4 w-4" /></button>}</td>}</tr>
      })}{!loading && !filtered.length && <tr><td colSpan={canManage ? 7 : 6} className="p-10 text-center text-slate-400">Belum ada metode pembayaran.</td></tr>}</tbody></table>{loading && <div className="p-10 text-center text-sm text-slate-500">Memuat metode pembayaran...</div>}</div>
    </div>
    {editor !== undefined && <PaymentMethodEditor session={session} record={editor ?? undefined} stores={stores} close={() => setEditor(undefined)} complete={async () => { setEditor(undefined); await refresh(); notify('Metode pembayaran berhasil disimpan.') }} />}
  </>
}

function PaymentMethodEditor({ session, record, stores, close, complete }: {
  session: Session; record?: PaymentMethod; stores: StoreOption[]
  close: () => void; complete: () => Promise<void>
}) {
  useEscapeClose(close)
  const defaultRoute = (type: MethodType): SettlementRoute => type === 'CASH' ? 'CASH_DRAWER' : type === 'TEMPO' ? 'RECEIVABLE' : type === 'TRANSFER' ? 'DIRECT_BANK' : 'CLEARING'
  const [form, setForm] = useState({
    name: record?.payment_method_name ?? '',
    methodType: record?.method_type ?? 'CASH' as MethodType,
    settlementRoute: record?.settlement_route ?? 'CASH_DRAWER' as SettlementRoute,
    isDefault: record?.is_default ?? false,
    availableAllStores: record?.available_all_stores ?? true,
    storeIds: record?.store_assignments.map((row) => row.store_id) ?? [],
    proofMode: record?.proof_mode ?? 'OPTIONAL' as ProofMode,
    feeEnabled: record?.fee_enabled ?? false,
    feeBearer: record?.fee_bearer ?? 'COMPANY' as FeeBearer,
    feeType: record?.fee_type ?? 'PERCENT' as FeeType,
    feePercent: record?.fee_percent === null || record?.fee_percent === undefined ? '' : String(record.fee_percent),
    feeFixedAmount: record?.fee_fixed_amount === null || record?.fee_fixed_amount === undefined ? '' : String(record.fee_fixed_amount),
    effectiveFrom: dateInput(record?.effective_from ?? new Date().toISOString()),
    effectiveUntil: dateInput(record?.effective_to ?? null),
    isActive: record?.is_active ?? true,
  })
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')
  const electronic = ['TRANSFER', 'QRIS', 'CARD', 'E_WALLET'].includes(form.methodType) || form.methodType === 'CUSTOM' && ['DIRECT_BANK', 'CLEARING'].includes(form.settlementRoute)

  function changeType(methodType: MethodType) {
    const settlementRoute = defaultRoute(methodType)
    setForm((current) => ({
      ...current, methodType, settlementRoute,
      feeEnabled: ['DIRECT_BANK', 'CLEARING'].includes(settlementRoute) ? current.feeEnabled : false,
    }))
  }
  async function submit(event: React.FormEvent) {
    event.preventDefault(); setSaving(true); setError('')
    try {
      const body = {
        ...form,
        storeIds: form.availableAllStores ? [] : form.storeIds,
        feePercent: form.feeEnabled && form.feeType !== 'FIXED' ? Number(form.feePercent) : null,
        feeFixedAmount: form.feeEnabled && form.feeType !== 'PERCENT' ? Number(form.feeFixedAmount) : null,
        clearingAccountFunction: form.settlementRoute === 'CLEARING' ? 'PAYMENT_CLEARING' : null,
        bankAccountFunction: form.settlementRoute === 'DIRECT_BANK' ? 'BANK_RECEIPT' : null,
        effectiveUntil: form.effectiveUntil || null,
        ...(record ? { masterVersion: record.master_version } : {}),
      }
      const response = await fetch(record ? `/api/master/payment-methods/${record.id}` : '/api/master/payment-methods', {
        method: record ? 'PATCH' : 'POST',
        headers: { 'Content-Type': 'application/json', ...authHeaders(session) },
        body: JSON.stringify(body),
      })
      const payload = await response.json() as { error?: string }
      if (!response.ok) throw new Error(friendlyError(payload.error))
      await complete()
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Gagal menyimpan metode pembayaran.')
    } finally { setSaving(false) }
  }

  return <Modal title={record ? 'Edit Metode Pembayaran' : 'Tambah Metode Pembayaran'} close={close}>
    <form onSubmit={submit} className="space-y-6">
      <div className="grid gap-4 sm:grid-cols-2"><Field label="Nama yang dilihat pengguna"><input required value={form.name} onChange={(event) => setForm({ ...form, name: event.target.value })} className="input" placeholder="Contoh: QRIS BCA" /><Hint>Nama harus unik. Identitas internal dibuat otomatis oleh sistem.</Hint></Field><Field label="Jenis pembayaran"><select value={form.methodType} onChange={(event) => changeType(event.target.value as MethodType)} className="input">{(['CASH','TRANSFER','QRIS','CARD','E_WALLET','TEMPO','CUSTOM'] as MethodType[]).map((type) => <option key={type} value={type}>{methodLabels[type]}</option>)}</select></Field><Field label="Dana diterima melalui"><select disabled={form.methodType === 'CASH' || form.methodType === 'TEMPO'} value={form.settlementRoute} onChange={(event) => { const settlementRoute = event.target.value as SettlementRoute; setForm({ ...form, settlementRoute, feeEnabled: ['DIRECT_BANK','CLEARING'].includes(settlementRoute) ? form.feeEnabled : false }) }} className="input disabled:bg-slate-100">{form.methodType === 'CASH' ? <option value="CASH_DRAWER">Laci kas</option> : form.methodType === 'TEMPO' ? <option value="RECEIVABLE">Piutang</option> : <><option value="DIRECT_BANK">Langsung ke bank (sudah terverifikasi)</option><option value="CLEARING">Clearing (menunggu settlement)</option>{form.methodType === 'CUSTOM' && <><option value="CASH_DRAWER">Laci kas</option><option value="RECEIVABLE">Piutang</option></>}</>}</select><Hint>Pilih Clearing bila dana provider belum benar-benar masuk rekening.</Hint></Field><Field label="Bukti pembayaran"><select value={form.proofMode} onChange={(event) => setForm({ ...form, proofMode: event.target.value as ProofMode })} className="input"><option value="OPTIONAL">Opsional</option><option value="REQUIRED">Wajib sebelum verifikasi</option></select></Field><Field label="Mulai berlaku"><input required type="datetime-local" value={form.effectiveFrom} onChange={(event) => setForm({ ...form, effectiveFrom: event.target.value })} className="input" /></Field><Field label="Berakhir (opsional)"><input type="datetime-local" value={form.effectiveUntil} onChange={(event) => setForm({ ...form, effectiveUntil: event.target.value })} className="input" /></Field></div>
      <section className="rounded-2xl border border-slate-200 p-4"><Checkbox checked={form.availableAllStores} onChange={(value) => setForm({ ...form, availableAllStores: value, storeIds: value ? [] : form.storeIds })} label="Tersedia di semua toko" />{!form.availableAllStores && <div className="mt-4 grid gap-2 sm:grid-cols-2">{stores.map((store) => <Checkbox key={store.id} checked={form.storeIds.includes(store.id)} onChange={(checked) => setForm({ ...form, storeIds: checked ? [...form.storeIds, store.id] : form.storeIds.filter((id) => id !== store.id) })} label={store.store_name} />)}</div>}</section>
      <section className="rounded-2xl border border-slate-200 p-4"><Checkbox disabled={!electronic} checked={form.feeEnabled} onChange={(value) => setForm({ ...form, feeEnabled: value })} label="Metode ini memiliki fee konfigurasi" />{form.feeEnabled && <div className="mt-4 grid gap-4 sm:grid-cols-2 xl:grid-cols-4"><Field label="Fee ditanggung"><select value={form.feeBearer} onChange={(event) => setForm({ ...form, feeBearer: event.target.value as FeeBearer })} className="input"><option value="COMPANY">Company</option><option value="CUSTOMER">Customer (surcharge terpisah)</option></select></Field><Field label="Bentuk fee"><select value={form.feeType} onChange={(event) => setForm({ ...form, feeType: event.target.value as FeeType })} className="input"><option value="PERCENT">Persentase</option><option value="FIXED">Nominal tetap</option><option value="PERCENT_PLUS_FIXED">Persentase + nominal</option></select></Field>{form.feeType !== 'FIXED' && <Field label="Fee (%)"><input required min="0" max="100" step="any" type="number" value={form.feePercent} onChange={(event) => setForm({ ...form, feePercent: event.target.value })} className="input" /></Field>}{form.feeType !== 'PERCENT' && <Field label="Fee tetap (Rp)"><input required min="0" step="any" type="number" value={form.feeFixedAmount} onChange={(event) => setForm({ ...form, feeFixedAmount: event.target.value })} className="input" /></Field>}</div>}<Hint>Nilai ini untuk preview dan matching. Fee aktual tetap dicatat saat settlement.</Hint></section>
      <div className="grid gap-3 sm:grid-cols-2"><Checkbox checked={form.isDefault} onChange={(value) => setForm({ ...form, isDefault: value, isActive: value ? true : form.isActive })} label="Metode default Company" /><Checkbox checked={form.isActive} onChange={(value) => setForm({ ...form, isActive: value, isDefault: value ? form.isDefault : false })} label="Metode aktif" /></div>
      {error && <div className="rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-700">{error}</div>}
      <div className="flex justify-end gap-3 border-t border-slate-100 pt-5"><button type="button" onClick={close} className="rounded-xl border border-slate-200 px-5 py-3 text-sm font-bold text-slate-600">Batal</button><button disabled={saving} type="submit" className="inline-flex items-center gap-2 rounded-xl bg-emerald-500 px-5 py-3 text-sm font-bold text-white disabled:opacity-60">{saving && <Loader2 className="h-4 w-4 animate-spin" />}Simpan Metode</button></div>
    </form>
  </Modal>
}

function Modal({ title, close, children }: { title: string; close: () => void; children: React.ReactNode }) { return <div className="fixed inset-0 z-[70] overflow-y-auto bg-slate-950/50 p-4 backdrop-blur-sm"><div className="mx-auto my-6 max-w-5xl rounded-3xl bg-white shadow-2xl"><div className="flex items-start justify-between border-b border-slate-100 p-6"><div><div className="mb-3 inline-flex items-center gap-2 rounded-full bg-emerald-50 px-3 py-1 text-xs font-bold text-emerald-700"><CreditCard className="h-3.5 w-3.5" /> Master pembayaran</div><h2 className="text-xl font-black text-slate-950">{title}</h2><p className="mt-2 max-w-3xl text-sm leading-6 text-slate-500">Konfigurasi ini berlaku untuk transaksi baru setelah resolver checkout diaktifkan pada fase berikutnya.</p></div><button type="button" onClick={close} className="rounded-xl border border-slate-200 p-2 text-slate-500" aria-label="Tutup"><X className="h-5 w-5" /></button></div><div className="p-6">{children}</div></div></div> }
function Field({ label, children }: { label: string; children: React.ReactNode }) { return <label className="block"><span className="mb-2 block text-sm font-bold text-slate-700">{label}</span>{children}</label> }
function Hint({ children }: { children: React.ReactNode }) { return <span className="mt-1 block text-xs leading-5 text-slate-400">{children}</span> }
function Checkbox({ checked, onChange, label, disabled = false }: { checked: boolean; onChange: (value: boolean) => void; label: string; disabled?: boolean }) { return <label className={`flex items-center gap-3 rounded-xl border border-slate-200 bg-white p-3 text-sm font-semibold ${disabled ? 'opacity-50' : ''}`}><input disabled={disabled} type="checkbox" checked={checked} onChange={(event) => onChange(event.target.checked)} className="h-4 w-4 accent-emerald-500" />{label}</label> }
function Status({ active }: { active: boolean }) { return <span className={`rounded-full px-2.5 py-1 text-[11px] font-bold ${active ? 'bg-emerald-50 text-emerald-700' : 'bg-slate-100 text-slate-500'}`}>{active ? 'Aktif' : 'Nonaktif'}</span> }
