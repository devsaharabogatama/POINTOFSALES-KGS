'use client'

import { useCallback, useEffect, useMemo, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import { BadgePercent, CircleAlert, Edit3, Plus, RefreshCcw, ShieldCheck, X } from 'lucide-react'
import { useEscapeClose } from '@/lib/use-escape-close'

type TaxScope = 'SALES' | 'PURCHASE'
type TaxVersion = {
  id: string; tax_rule_id: string; rate_percent: number | string
  calculation_scope: 'PER_LINE' | 'PER_DOCUMENT'
  default_price_mode: 'INCLUSIVE' | 'EXCLUSIVE'; account_id: string
  is_recoverable: boolean | null; effective_from: string; effective_to: string | null
  rule_version: number; status: string
}
type TaxRule = {
  id: string; tax_code: string; tax_name: string; tax_scope: TaxScope
  is_active: boolean; master_version: number; versions: TaxVersion[]
}
type Account = {
  id: string; account_code: string; account_name: string; account_type: string
  system_function_key: string | null
}
type Payload = {
  data?: TaxRule[]; accounts?: Account[]
  entitlements?: { salesEnabled: boolean; purchaseEnabled: boolean }; error?: string
}

function authHeaders(session: Session) { return { Authorization: `Bearer ${session.access_token}` } }
function dateInput(value?: string | null) {
  if (!value) return ''
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return ''
  const local = new Date(date.getTime() - date.getTimezoneOffset() * 60_000)
  return local.toISOString().slice(0, 16)
}
function displayDate(value?: string | null) {
  if (!value) return 'Tanpa batas'
  return new Intl.DateTimeFormat('id-ID', { dateStyle: 'medium' }).format(new Date(value))
}
function friendlyError(code?: string) {
  const messages: Record<string, string> = {
    TAX_MASTER_MANAGER_REQUIRED: 'Role ini tidak boleh mengubah master pajak.',
    TAX_FEATURE_DISABLED: 'Entitlement pajak untuk scope ini belum diaktifkan oleh Super Admin.',
    INVALID_TAX_IDENTITY: 'Nama dan kode pajak wajib diisi.',
    INVALID_TAX_RATE: 'Tarif pajak harus berada di antara 0 sampai 100%.',
    ACTIVE_POSTABLE_TAX_ACCOUNT_REQUIRED: 'Pilih akun pajak aktif yang dapat menerima posting.',
    INCOMPATIBLE_TAX_ACCOUNT_TYPE: 'Jenis akun tidak cocok dengan scope pajak.',
    SALES_TAX_MUST_BE_INCLUSIVE: 'Harga pajak penjualan wajib termasuk pajak.',
    PURCHASE_TAX_RECOVERABLE_REQUIRED: 'Tentukan apakah pajak pembelian dapat dikreditkan.',
    TAX_ACTIVE_VERSION_REQUIRES_ACTIVE_RULE: 'Versi aktif hanya dapat dipakai pada aturan yang aktif.',
    INVALID_EFFECTIVE_PERIOD: 'Tanggal berakhir harus setelah tanggal mulai.',
    TAX_RULE_NOT_FOUND: 'Aturan pajak tidak ditemukan.',
    MASTER_VERSION_CONFLICT: 'Data sudah diubah pengguna lain. Muat ulang lalu coba lagi.',
    TAX_SCOPE_LOCKED_BY_VERSION_HISTORY: 'Scope tidak dapat diubah setelah aturan memiliki versi.',
    TAX_RULE_VERSION_CONFLICT: 'Tanggal mulai bertabrakan dengan versi aktif sebelumnya.',
    TAX_RULE_VERSION_PERIOD_OVERLAP: 'Periode aturan pajak bertabrakan dengan versi lain.',
    DUPLICATE_TAX_RULE: 'Nama atau kode pajak sudah digunakan.',
    FORBIDDEN: 'Anda tidak memiliki akses ke master pajak ini.',
  }
  return messages[code ?? ''] ?? code ?? 'Operasi master pajak gagal.'
}

export function TaxMasterView({ session, companyId, canManage, notify }: {
  session: Session; companyId: string; canManage: boolean
  notify: (message: string | null) => void
}) {
  const [rules, setRules] = useState<TaxRule[]>([])
  const [accounts, setAccounts] = useState<Account[]>([])
  const [entitlements, setEntitlements] = useState({ salesEnabled: false, purchaseEnabled: false })
  const [filter, setFilter] = useState<'ALL' | TaxScope>('ALL')
  const [editor, setEditor] = useState<TaxRule | null | undefined>()
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')

  const refresh = useCallback(async () => {
    setLoading(true); setError('')
    try {
      const response = await fetch('/api/master/tax-rules', {
        headers: authHeaders(session), cache: 'no-store',
      })
      const payload = await response.json() as Payload
      if (!response.ok) throw new Error(friendlyError(payload.error))
      setRules(payload.data ?? [])
      setAccounts(payload.accounts ?? [])
      setEntitlements(payload.entitlements ?? { salesEnabled: false, purchaseEnabled: false })
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Gagal memuat master pajak.')
    } finally { setLoading(false) }
  }, [session])

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- data follows active Company context
    void refresh()
  }, [companyId, refresh])

  const filtered = useMemo(
    () => rules.filter((rule) => filter === 'ALL' || rule.tax_scope === filter),
    [filter, rules],
  )
  const accountById = useMemo(() => new Map(accounts.map((row) => [row.id, row])), [accounts])
  const enabled = entitlements.salesEnabled || entitlements.purchaseEnabled

  return <>
    <div className="mb-7 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
      <div><p className="text-xs font-bold uppercase tracking-[.16em] text-emerald-600">Master Keuangan</p><h1 className="mt-2 text-2xl font-black tracking-tight text-slate-950 md:text-3xl">Aturan Pajak</h1><p className="mt-2 max-w-3xl text-sm leading-6 text-slate-500">Kelola nama, tarif, akun, dan periode aturan pajak Sales atau Purchase. Kode internal hanya ditampilkan sebagai informasi sekunder.</p></div>
      <div className="flex gap-2"><button onClick={() => void refresh()} className="inline-flex items-center gap-2 rounded-xl border border-slate-200 bg-white px-4 py-3 text-sm font-bold text-slate-600"><RefreshCcw className={`h-4 w-4 ${loading ? 'animate-spin' : ''}`} /> Muat ulang</button>{canManage && <button disabled={!enabled} onClick={() => setEditor(null)} className="inline-flex items-center gap-2 rounded-xl bg-emerald-500 px-4 py-3 text-sm font-bold text-white disabled:cursor-not-allowed disabled:bg-slate-300"><Plus className="h-4 w-4" /> Tambah aturan</button>}</div>
    </div>
    <div className="mb-5 rounded-2xl border border-amber-100 bg-amber-50 p-4 text-sm leading-6 text-amber-900"><b>Kalkulasi dan posting pajak belum aktif.</b> Menu ini baru menyimpan master serta versi konfigurasi. Perubahan di sini belum menghitung pajak transaksi atau membuat jurnal.</div>
    <div className="mb-5 grid gap-3 md:grid-cols-2">
      <EntitlementCard title="Pajak Penjualan" enabled={entitlements.salesEnabled} text="Harga jual tetap termasuk pajak (inclusive). Akun tujuan adalah Pajak Keluaran." />
      <EntitlementCard title="Pajak Pembelian" enabled={entitlements.purchaseEnabled} text="Invoice Supplier dapat inclusive/exclusive. Akun recoverable adalah Pajak Masukan." />
    </div>
    {!enabled && <div className="mb-5 flex gap-3 rounded-2xl border border-slate-200 bg-white p-4 text-sm text-slate-600"><CircleAlert className="h-5 w-5 shrink-0 text-amber-500" /><span>Belum ada entitlement pajak aktif. Hanya Super Admin yang dapat mengaktifkannya; Company tidak dapat menyalakannya dari menu ini.</span></div>}
    {error && <div className="mb-5 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-700">{error}</div>}
    <div className="mb-4 flex flex-wrap gap-2">{([['ALL','Semua'],['SALES','Penjualan'],['PURCHASE','Pembelian']] as const).map(([id,label]) => <button key={id} onClick={() => setFilter(id)} className={`rounded-xl px-4 py-2 text-sm font-bold ${filter === id ? 'bg-slate-950 text-white' : 'border border-slate-200 bg-white text-slate-600'}`}>{label}</button>)}</div>
    <div className="overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-sm"><div className="overflow-x-auto"><table className="min-w-full text-left text-sm"><thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500"><tr><th className="px-5 py-4">Aturan pajak</th><th className="px-5 py-4">Scope</th><th className="px-5 py-4">Tarif & mode</th><th className="px-5 py-4">Akun</th><th className="px-5 py-4">Periode</th><th className="px-5 py-4">Status</th>{canManage && <th className="px-5 py-4 text-right">Aksi</th>}</tr></thead><tbody className="divide-y divide-slate-100">{filtered.map((rule) => {
      const version = rule.versions[0]
      const account = version ? accountById.get(version.account_id) : undefined
      const scopeEnabled = rule.tax_scope === 'SALES'
        ? entitlements.salesEnabled : entitlements.purchaseEnabled
      return <tr key={rule.id} className="align-top"><td className="px-5 py-4"><p className="font-bold text-slate-900">{rule.tax_name}</p><p className="mt-1 text-xs text-slate-400">Kode: {rule.tax_code}</p></td><td className="px-5 py-4">{rule.tax_scope === 'SALES' ? 'Penjualan' : 'Pembelian'}</td><td className="px-5 py-4"><p className="font-semibold">{version ? `${Number(version.rate_percent)}%` : 'Belum ada versi'}</p>{version && <p className="mt-1 text-xs text-slate-400">{version.default_price_mode === 'INCLUSIVE' ? 'Harga termasuk pajak' : 'Harga belum termasuk pajak'} · {version.calculation_scope === 'PER_DOCUMENT' ? 'Per dokumen' : 'Per baris'}</p>}</td><td className="px-5 py-4"><p className="font-medium">{account?.account_name ?? '-'}</p>{account && <p className="mt-1 text-xs text-slate-400">{account.account_code}</p>}</td><td className="px-5 py-4 text-xs leading-5 text-slate-600">{version ? <>{displayDate(version.effective_from)}<br />s.d. {displayDate(version.effective_to)}<br />Versi {version.rule_version}</> : '-'}</td><td className="px-5 py-4"><Status active={rule.is_active} version={version} /></td>{canManage && <td className="px-5 py-4 text-right"><button disabled={!scopeEnabled} title={scopeEnabled ? 'Edit aturan' : 'Entitlement scope ini nonaktif'} onClick={() => setEditor(rule)} className="rounded-lg border border-slate-200 p-2 text-slate-500 hover:text-emerald-600 disabled:cursor-not-allowed disabled:bg-slate-50 disabled:text-slate-300" aria-label={`Edit ${rule.tax_name}`}><Edit3 className="h-4 w-4" /></button></td>}</tr>
    })}{!loading && filtered.length === 0 && <tr><td colSpan={canManage ? 7 : 6} className="p-10 text-center text-slate-400">Belum ada aturan pajak.</td></tr>}</tbody></table></div>{loading && <div className="p-10 text-center text-sm text-slate-500">Memuat aturan pajak...</div>}</div>
    {editor !== undefined && <TaxEditor session={session} record={editor ?? undefined} accounts={accounts} entitlements={entitlements} close={() => setEditor(undefined)} complete={async () => { setEditor(undefined); await refresh(); notify('Aturan pajak berhasil disimpan.') }} />}
  </>
}

function TaxEditor({ session, record, accounts, entitlements, close, complete }: {
  session: Session; record?: TaxRule; accounts: Account[]
  entitlements: { salesEnabled: boolean; purchaseEnabled: boolean }
  close: () => void; complete: () => Promise<void>
}) {
  useEscapeClose(close)
  const latest = record?.versions[0]
  const initialScope: TaxScope = record?.tax_scope ?? (entitlements.salesEnabled ? 'SALES' : 'PURCHASE')
  const [form, setForm] = useState({
    name: record?.tax_name ?? '', code: record?.tax_code ?? '', scope: initialScope,
    ratePercent: latest ? String(latest.rate_percent) : '',
    calculationScope: latest?.calculation_scope ?? 'PER_DOCUMENT',
    priceMode: latest?.default_price_mode ?? 'INCLUSIVE',
    accountId: latest?.account_id ?? '', isRecoverable: latest?.is_recoverable ?? true,
    effectiveFrom: dateInput(new Date().toISOString()), effectiveTo: '',
    status: 'ACTIVE' as 'ACTIVE' | 'DRAFT', isActive: record?.is_active ?? true,
  })
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')
  const compatibleAccounts = accounts.filter((account) =>
    form.scope === 'SALES' ? account.account_type === 'LIABILITY' : account.account_type === 'ASSET',
  )

  function changeScope(scope: TaxScope) {
    setForm((current) => ({ ...current, scope, accountId: '', priceMode: 'INCLUSIVE', isRecoverable: true }))
  }
  async function submit(event: React.FormEvent) {
    event.preventDefault(); setSaving(true); setError('')
    try {
      const body = {
        ...form, ratePercent: Number(form.ratePercent),
        effectiveTo: form.effectiveTo || null,
        isRecoverable: form.scope === 'PURCHASE' ? form.isRecoverable : null,
        ...(record ? { masterVersion: record.master_version } : {}),
      }
      const response = await fetch(record ? `/api/master/tax-rules/${record.id}` : '/api/master/tax-rules', {
        method: record ? 'PATCH' : 'POST',
        headers: { 'Content-Type': 'application/json', ...authHeaders(session) },
        body: JSON.stringify(body),
      })
      const payload = await response.json() as { error?: string }
      if (!response.ok) throw new Error(friendlyError(payload.error))
      await complete()
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Gagal menyimpan aturan pajak.')
    } finally { setSaving(false) }
  }

  return <Modal title={record ? 'Edit Aturan Pajak' : 'Tambah Aturan Pajak'} close={close}><form onSubmit={submit} className="space-y-6">
    {record && <div className="rounded-2xl border border-sky-100 bg-sky-50 p-4 text-sm leading-6 text-sky-900"><b>Edit membuat versi konfigurasi baru.</b> Versi lama tidak ditimpa agar histori transaksi tetap dapat ditelusuri.</div>}
    <div className="grid gap-4 sm:grid-cols-2"><Field label="Nama pajak yang dilihat user"><input required value={form.name} onChange={(event) => setForm({ ...form, name: event.target.value })} className="input" placeholder="Contoh: PPN Penjualan 11%" /></Field><Field label="Kode internal"><input required value={form.code} onChange={(event) => setForm({ ...form, code: event.target.value.toUpperCase() })} className="input" placeholder="Contoh: PPN-S11" /><Hint>Kode harus unik; user sehari-hari cukup melihat nama pajaknya.</Hint></Field><Field label="Dipakai untuk"><select disabled={Boolean(record)} value={form.scope} onChange={(event) => changeScope(event.target.value as TaxScope)} className="input disabled:bg-slate-100"><option disabled={!entitlements.salesEnabled} value="SALES">Penjualan {entitlements.salesEnabled ? '' : '(entitlement nonaktif)'}</option><option disabled={!entitlements.purchaseEnabled} value="PURCHASE">Pembelian {entitlements.purchaseEnabled ? '' : '(entitlement nonaktif)'}</option></select></Field><Field label="Tarif pajak (%)"><input required type="number" min="0" max="100" step="0.000001" value={form.ratePercent} onChange={(event) => setForm({ ...form, ratePercent: event.target.value })} className="input" placeholder="11" /></Field><Field label="Cara menghitung"><select value={form.calculationScope} onChange={(event) => setForm({ ...form, calculationScope: event.target.value as 'PER_LINE' | 'PER_DOCUMENT' })} className="input"><option value="PER_DOCUMENT">Per dokumen (disarankan)</option><option value="PER_LINE">Per baris produk</option></select><Hint>Per dokumen membulatkan sekali pada total kelompok pajak.</Hint></Field><Field label="Harga pada dokumen"><select disabled={form.scope === 'SALES'} value={form.priceMode} onChange={(event) => setForm({ ...form, priceMode: event.target.value as 'INCLUSIVE' | 'EXCLUSIVE' })} className="input disabled:bg-slate-100"><option value="INCLUSIVE">Sudah termasuk pajak</option>{form.scope === 'PURCHASE' && <option value="EXCLUSIVE">Belum termasuk pajak</option>}</select></Field><Field label={form.scope === 'SALES' ? 'Akun Pajak Keluaran' : 'Akun Pajak Masukan'}><select required value={form.accountId} onChange={(event) => setForm({ ...form, accountId: event.target.value })} className="input"><option value="">Pilih akun</option>{compatibleAccounts.map((account) => <option key={account.id} value={account.id}>{account.account_name} ({account.account_code})</option>)}</select><Hint>{compatibleAccounts.length ? 'Nama akun ditampilkan utama; kode hanya pembeda.' : 'Belum ada akun COA aktif/postable yang kompatibel.'}</Hint></Field>{form.scope === 'PURCHASE' && <Field label="Perlakuan pajak pembelian"><select value={form.isRecoverable ? 'YES' : 'NO'} onChange={(event) => setForm({ ...form, isRecoverable: event.target.value === 'YES' })} className="input"><option value="YES">Dapat dikreditkan (Pajak Masukan)</option><option value="NO">Tidak dapat dikreditkan (masuk biaya/nilai persediaan)</option></select></Field>}<Field label="Mulai berlaku"><input required type="datetime-local" value={form.effectiveFrom} onChange={(event) => setForm({ ...form, effectiveFrom: event.target.value })} className="input" /></Field><Field label="Berakhir (opsional)"><input type="datetime-local" value={form.effectiveTo} onChange={(event) => setForm({ ...form, effectiveTo: event.target.value })} className="input" /></Field><Field label="Status versi"><select value={form.status} onChange={(event) => setForm({ ...form, status: event.target.value as 'ACTIVE' | 'DRAFT' })} className="input"><option value="ACTIVE">Aktif dan siap dipakai resolver nanti</option><option value="DRAFT">Draft, belum eligible</option></select></Field></div>
    <label className="flex items-center gap-3 rounded-xl border border-slate-200 p-4 text-sm font-bold"><input type="checkbox" checked={form.isActive} onChange={(event) => setForm({ ...form, isActive: event.target.checked, status: event.target.checked ? form.status : 'DRAFT' })} className="h-4 w-4 accent-emerald-500" />Aturan pajak aktif</label>
    {error && <div className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-700">{error}</div>}
    <div className="flex justify-end gap-3 border-t border-slate-100 pt-5"><button type="button" onClick={close} className="rounded-xl border border-slate-200 px-5 py-3 text-sm font-bold text-slate-600">Batal</button><button disabled={saving || compatibleAccounts.length === 0} className="rounded-xl bg-emerald-500 px-5 py-3 text-sm font-bold text-white disabled:bg-slate-300">{saving ? 'Menyimpan...' : 'Simpan aturan'}</button></div>
  </form></Modal>
}

function EntitlementCard({ title, enabled, text }: { title: string; enabled: boolean; text: string }) { return <div className={`rounded-2xl border p-4 ${enabled ? 'border-emerald-200 bg-emerald-50' : 'border-slate-200 bg-white'}`}><div className="flex items-center gap-2"><ShieldCheck className={`h-5 w-5 ${enabled ? 'text-emerald-600' : 'text-slate-400'}`} /><p className="font-bold text-slate-900">{title}</p><span className={`ml-auto rounded-full px-2.5 py-1 text-xs font-bold ${enabled ? 'bg-emerald-600 text-white' : 'bg-slate-100 text-slate-500'}`}>{enabled ? 'Aktif' : 'Nonaktif'}</span></div><p className="mt-2 text-xs leading-5 text-slate-500">{text}</p></div> }
function Status({ active, version }: { active: boolean; version?: TaxVersion }) { return <div className="space-y-1"><span className={`inline-flex rounded-full px-2.5 py-1 text-xs font-bold ${active ? 'bg-emerald-50 text-emerald-700' : 'bg-slate-100 text-slate-500'}`}>{active ? 'Master aktif' : 'Master nonaktif'}</span>{version && <p className="text-xs text-slate-400">Versi: {version.status === 'ACTIVE' ? 'Aktif' : 'Draft'}</p>}</div> }
function Modal({ title, close, children }: { title: string; close: () => void; children: React.ReactNode }) { return <div className="fixed inset-0 z-[70] overflow-y-auto bg-slate-950/50 p-4 backdrop-blur-sm"><div className="mx-auto my-6 max-w-5xl rounded-3xl bg-white shadow-2xl"><div className="flex items-start justify-between border-b border-slate-100 p-6"><div><div className="mb-3 inline-flex items-center gap-2 rounded-full bg-emerald-50 px-3 py-1 text-xs font-bold text-emerald-700"><BadgePercent className="h-3.5 w-3.5" /> Master pajak</div><h2 className="text-xl font-black text-slate-950">{title}</h2><p className="mt-2 max-w-3xl text-sm leading-6 text-slate-500">Atur versi untuk transaksi baru. Tombol Escape dapat menutup modal ini.</p></div><button type="button" onClick={close} className="rounded-xl border border-slate-200 p-2 text-slate-500" aria-label="Tutup"><X className="h-5 w-5" /></button></div><div className="p-6">{children}</div></div></div> }
function Field({ label, children }: { label: string; children: React.ReactNode }) { return <label className="block"><span className="mb-2 block text-sm font-bold text-slate-700">{label}</span>{children}</label> }
function Hint({ children }: { children: React.ReactNode }) { return <span className="mt-1 block text-xs leading-5 text-slate-400">{children}</span> }
