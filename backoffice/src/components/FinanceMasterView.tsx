'use client'

import { useCallback, useEffect, useMemo, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import {
  BookOpen,
  Edit3,
  Landmark,
  Loader2,
  Plus,
  RefreshCcw,
  Route,
  ShieldCheck,
  X,
} from 'lucide-react'
import { useEscapeClose } from '@/lib/use-escape-close'

type AccountFunction = {
  function_key: string
  function_name: string
  compatible_account_types: string[]
}
type SystemEvent = {
  system_key: string
  event_group: string
  event_name: string
  required_account_functions: string[]
  conditional_account_functions: string[]
}
type Account = {
  id: string
  account_code: string
  account_name: string
  account_type: string
  normal_balance: string
  parent_account_id: string | null
  system_function_key: string | null
  is_system_account: boolean
  is_postable: boolean
  allow_manual_posting: boolean
  allow_reconciliation: boolean
  is_active: boolean
  master_version: number
}
type Category = {
  id: string
  category_code: string
  category_name: string
  system_key: string
  description: string | null
  is_active: boolean
  is_system_default: boolean
  master_version: number
}
type Rule = {
  id: string
  transaction_category_id: string
  account_function_key: string
  account_id: string
  effective_from: string
  effective_to: string | null
  rule_version: number
  status: string
}
type Fallback = {
  id: string
  account_function_key: string
  account_id: string
  effective_from: string
  effective_to: string | null
  fallback_version: number
  status: string
}
type Payload = {
  accountFunctions?: AccountFunction[]
  systemEvents?: SystemEvent[]
  accounts?: Account[]
  categories?: Category[]
  rules?: Rule[]
  fallbacks?: Fallback[]
  error?: string
}
type Tab = 'categories' | 'rules' | 'accounts' | 'fallbacks'

const accountTypes = Object.keys({
  ASSET: true, LIABILITY: true, EQUITY: true, REVENUE: true,
  COGS: true, EXPENSE: true, OTHER_INCOME: true, OTHER_EXPENSE: true,
})
const defaultBalance: Record<string, string> = {
  ASSET: 'DEBIT', COGS: 'DEBIT', EXPENSE: 'DEBIT', OTHER_EXPENSE: 'DEBIT',
  LIABILITY: 'CREDIT', EQUITY: 'CREDIT', REVENUE: 'CREDIT', OTHER_INCOME: 'CREDIT',
}

const accountTypeLabels: Record<string, string> = {
  ASSET: 'Aset', LIABILITY: 'Kewajiban', EQUITY: 'Ekuitas',
  REVENUE: 'Pendapatan', COGS: 'HPP', EXPENSE: 'Beban',
  OTHER_INCOME: 'Pendapatan lain', OTHER_EXPENSE: 'Beban lain',
}
const groupLabels: Record<string, string> = {
  SALES: 'Penjualan', PURCHASE: 'Pembelian', INVENTORY: 'Persediaan',
  EXPENSE: 'Pengeluaran', CASH: 'Kas', CUSTOMER: 'Customer',
  KETUL: 'Ketul', FINANCE: 'Keuangan',
}

function authHeaders(session: Session) {
  return { Authorization: `Bearer ${session.access_token}` }
}
function dateInput(value?: string | null) {
  if (!value) return ''
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return ''
  const local = new Date(date.getTime() - date.getTimezoneOffset() * 60_000)
  return local.toISOString().slice(0, 16)
}
function friendlyError(code?: string) {
  const messages: Record<string, string> = {
    FINANCE_MASTER_MANAGER_REQUIRED: 'Role ini tidak boleh mengubah master Finance.',
    INVALID_TRANSACTION_CATEGORY_IDENTITY: 'Nama dan kode kategori wajib diisi.',
    ACTIVE_SYSTEM_EVENT_NOT_FOUND: 'Jenis transaksi sistem tidak aktif atau tidak ditemukan.',
    TRANSACTION_CATEGORY_NOT_FOUND: 'Kategori transaksi tidak ditemukan.',
    ACTIVE_TRANSACTION_CATEGORY_NOT_FOUND: 'Pilih kategori transaksi yang aktif.',
    MASTER_VERSION_CONFLICT: 'Data sudah diubah pengguna lain. Muat ulang lalu coba lagi.',
    DUPLICATE_TRANSACTION_CATEGORY: 'Nama atau kode kategori sudah dipakai.',
    ACTIVE_POSTABLE_ACCOUNT_REQUIRED: 'Pilih akun aktif yang boleh menerima posting.',
    INCOMPATIBLE_ACCOUNT_TYPE: 'Jenis akun tidak cocok dengan fungsi akun ini.',
    CATEGORY_SYSTEM_EVENT_LOCKED_BY_HISTORY: 'Jenis transaksi tidak dapat diubah karena kategori sudah memiliki mapping.',
    RULE_VERSION_CONFLICT: 'Tanggal mulai bertabrakan dengan versi mapping yang sudah ada.',
    INVALID_EFFECTIVE_PERIOD: 'Tanggal berakhir harus setelah tanggal mulai.',
    EFFECTIVE_FROM_REQUIRED: 'Tanggal mulai berlaku wajib diisi.',
    EFFECTIVE_TO_INVALID: 'Tanggal berakhir tidak valid.',
    TRANSACTION_RULE_PERIOD_OVERLAP: 'Periode mapping bertabrakan dengan versi lain.',
    FINANCE_ENTITY_TYPE_INVALID: 'Jenis data Finance tidak valid.',
    REQUIRED_TRANSACTION_CATEGORY_CANNOT_BE_DISABLED: 'Kategori bawaan wajib harus tetap aktif.',
    REQUIRED_TRANSACTION_CATEGORY_SYSTEM_EVENT_LOCKED: 'Jenis transaksi kategori bawaan tidak dapat diubah.',
    REQUIRED_TRANSACTION_CATEGORY_CANNOT_BE_DELETED: 'Kategori bawaan wajib tidak dapat dihapus.',
    INVALID_ACCOUNT_IDENTITY: 'Kode dan nama akun wajib diisi.',
    INVALID_ACCOUNT_TYPE: 'Tipe akun tidak valid.',
    INVALID_NORMAL_BALANCE: 'Saldo normal akun tidak valid.',
    MANUAL_POSTING_REQUIRES_POSTABLE_ACCOUNT: 'Posting manual hanya boleh untuk akun posting.',
    SYSTEM_ACCOUNT_FLAG_LOCKED: 'Penanda akun sistem tidak dapat diubah.',
    ACCOUNT_IN_USE_BY_ACTIVE_RULE: 'Akun masih dipakai mapping aktif.',
    ACCOUNT_IN_USE_BY_ACTIVE_FALLBACK: 'Akun masih dipakai fallback aktif.',
    ACTIVE_CHILD_ACCOUNT_EXISTS: 'Nonaktifkan akun anak lebih dahulu.',
    COA_HIERARCHY_CYCLE: 'Susunan induk akun membentuk lingkaran.',
    COA_HIERARCHY_MAX_DEPTH_EXCEEDED: 'Hierarki akun maksimal tiga tingkat.',
    PARENT_ACCOUNT_NOT_FOUND: 'Akun induk tidak ditemukan di Company aktif.',
    PARENT_ACCOUNT_MUST_BE_NONPOSTABLE: 'Akun induk harus berupa grup, bukan akun posting.',
    ACTIVE_PARENT_ACCOUNT_REQUIRED: 'Akun induk harus aktif.',
    PARENT_ACCOUNT_TYPE_MISMATCH: 'Tipe akun anak harus sama dengan akun induk.',
    PARENT_ACCOUNT_CANNOT_BE_POSTABLE: 'Akun yang memiliki anak tidak dapat menerima posting.',
    CHILD_ACCOUNT_TYPE_MISMATCH: 'Tipe akun tidak cocok dengan akun anak yang ada.',
    ACTIVE_ACCOUNT_FUNCTION_NOT_FOUND: 'Fungsi akun tidak aktif atau tidak ditemukan.',
    ACCOUNT_TYPE_LOCKED_BY_HISTORY: 'Tipe akun dikunci karena sudah memiliki histori jurnal.',
    ACCOUNT_FUNCTION_LOCKED_BY_HISTORY: 'Fungsi akun dikunci karena sudah memiliki histori jurnal.',
    CHART_OF_ACCOUNT_NOT_FOUND: 'Akun tidak ditemukan.',
    DUPLICATE_CHART_OF_ACCOUNT: 'Kode atau nama akun sudah dipakai.',
    FALLBACK_VERSION_CONFLICT: 'Tanggal mulai harus setelah versi fallback aktif sebelumnya.',
    COMPANY_FALLBACK_PERIOD_OVERLAP: 'Periode fallback bertabrakan dengan versi lain.',
    FALLBACK_STATUS_INVALID: 'Status fallback tidak valid.',
    FORBIDDEN: 'Anda tidak memiliki akses ke data Finance ini.',
  }
  return messages[code ?? ''] ?? code ?? 'Operasi master Finance gagal.'
}

export function FinanceMasterView({
  session, companyId, canManage, notify,
}: {
  session: Session
  companyId: string
  canManage: boolean
  notify: (message: string | null) => void
}) {
  const [tab, setTab] = useState<Tab>('categories')
  const [data, setData] = useState<Required<Omit<Payload, 'error'>>>({
    accountFunctions: [], systemEvents: [], accounts: [], categories: [], rules: [], fallbacks: [],
  })
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [categoryEditor, setCategoryEditor] = useState<Category | null | undefined>()
  const [showRuleEditor, setShowRuleEditor] = useState(false)
  const [accountEditor, setAccountEditor] = useState<Account | null | undefined>()
  const [showFallbackEditor, setShowFallbackEditor] = useState(false)

  const refresh = useCallback(async () => {
    setLoading(true); setError('')
    try {
      const response = await fetch('/api/master/finance-masters', {
        headers: authHeaders(session), cache: 'no-store',
      })
      const payload = await response.json() as Payload
      if (!response.ok) throw new Error(friendlyError(payload.error))
      setData({
        accountFunctions: payload.accountFunctions ?? [],
        systemEvents: payload.systemEvents ?? [],
        accounts: payload.accounts ?? [],
        categories: payload.categories ?? [],
        rules: payload.rules ?? [],
        fallbacks: payload.fallbacks ?? [],
      })
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Gagal memuat master Finance.')
    } finally { setLoading(false) }
  }, [session])

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- data follows active Company context
    void refresh()
  }, [companyId, refresh])

  const eventByKey = useMemo(
    () => new Map(data.systemEvents.map((item) => [item.system_key, item])),
    [data.systemEvents],
  )
  const functionByKey = useMemo(
    () => new Map(data.accountFunctions.map((item) => [item.function_key, item])),
    [data.accountFunctions],
  )
  const categoryById = useMemo(
    () => new Map(data.categories.map((item) => [item.id, item])),
    [data.categories],
  )
  const accountById = useMemo(
    () => new Map(data.accounts.map((item) => [item.id, item])),
    [data.accounts],
  )

  return <>
    <div className="mb-7 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
      <div><p className="text-xs font-bold uppercase tracking-[.16em] text-emerald-600">Master Keuangan</p><h1 className="mt-2 text-2xl font-black tracking-tight text-slate-950 md:text-3xl">Kategori Transaksi & COA</h1><p className="mt-2 text-sm text-slate-500">Hubungkan kategori bisnis ke fungsi dan akun tanpa menampilkan identifier teknis kepada pengguna.</p></div>
      <button onClick={() => void refresh()} className="inline-flex items-center justify-center gap-2 rounded-xl border border-slate-200 bg-white px-4 py-3 text-sm font-bold text-slate-600"><RefreshCcw className={`h-4 w-4 ${loading ? 'animate-spin' : ''}`} /> Muat ulang</button>
    </div>
    <div className="mb-5 rounded-2xl border border-amber-100 bg-amber-50 p-4 text-sm leading-6 text-amber-900"><b>Finance posting belum aktif.</b> Menu ini baru mengatur master dan versi mapping. Tidak ada jurnal yang dibuat dari perubahan di sini.</div>
    <div className="mb-5 grid gap-3 md:grid-cols-3">
      <Guide number="1" title="Kategori transaksi" text="Alasan bisnis yang dipilih user, misalnya Penjualan, Setoran Kas, atau Listrik." />
      <Guide number="2" title="Jenis transaksi sistem" text="Proses aplikasi di balik kategori. Kategori bawaan sudah dipasangkan dan tidak perlu diubah." />
      <Guide number="3" title="Mapping akun" text="Menentukan akun tujuan. Ini konfigurasi Finance dan belum membuat jurnal selama posting belum aktif." />
    </div>
    {error && <div className="mb-5 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-700">{error}</div>}
    <div className="mb-5 flex flex-wrap gap-2">{([
      ['categories','Kategori transaksi',BookOpen],
      ['rules','Mapping akun',Route],
      ['accounts','Daftar akun',Landmark],
      ['fallbacks','Fallback Company',ShieldCheck],
    ] as const).map(([id,label,Icon]) => <button key={id} onClick={() => setTab(id)} className={`inline-flex items-center gap-2 rounded-xl px-4 py-2.5 text-sm font-bold ${tab === id ? 'bg-slate-950 text-white' : 'border border-slate-200 bg-white text-slate-600'}`}><Icon className="h-4 w-4" />{label}</button>)}</div>

    {tab === 'categories' && <Section title="Kategori transaksi" description="Kategori bawaan mencakup proses wajib aplikasi. Tambahkan kategori khusus hanya bila bisnis perlu rincian, misalnya Listrik atau Bensin." action={canManage && <button onClick={() => setCategoryEditor(null)} className="inline-flex items-center gap-2 rounded-xl bg-emerald-500 px-4 py-2.5 text-sm font-bold text-white"><Plus className="h-4 w-4" /> Tambah kategori khusus</button>}>
      <Table headers={['Nama kategori','Jenis transaksi','Keterangan','Sifat','Status',...(canManage ? ['Aksi'] : [])]}>{data.categories.map((item) => { const event = eventByKey.get(item.system_key); return <tr key={item.id} className="border-t border-slate-100"><td className="px-5 py-4 font-bold">{item.category_name}</td><td className="px-5 py-4"><p>{event?.event_name ?? 'Jenis transaksi tidak tersedia'}</p><p className="mt-1 text-xs text-slate-400">{groupLabels[event?.event_group ?? ''] ?? event?.event_group}</p></td><td className="max-w-sm px-5 py-4 text-slate-500">{item.description || '-'}</td><td className="px-5 py-4">{item.is_system_default ? <span className="rounded-full bg-blue-50 px-2.5 py-1 text-[11px] font-bold text-blue-700">Bawaan wajib</span> : <span className="rounded-full bg-slate-100 px-2.5 py-1 text-[11px] font-bold text-slate-600">Khusus Company</span>}</td><td className="px-5 py-4"><Status active={item.is_active} /></td>{canManage && <td className="px-5 py-4 text-right"><button onClick={() => setCategoryEditor(item)} className="rounded-lg border border-slate-200 p-2 text-slate-500" aria-label={`Edit ${item.category_name}`}><Edit3 className="h-4 w-4" /></button></td>}</tr> })}</Table>
      {!loading && !data.categories.length && <Empty text="Belum ada kategori transaksi. Buat kategori sesuai kebutuhan bisnis Company." />}
    </Section>}

    {tab === 'rules' && <Section title="Mapping kategori ke akun" description="Setiap perubahan aktif membuat versi baru dan menutup periode versi sebelumnya." action={canManage && <button disabled={!data.categories.some((item) => item.is_active)} onClick={() => setShowRuleEditor(true)} className="inline-flex items-center gap-2 rounded-xl bg-emerald-500 px-4 py-2.5 text-sm font-bold text-white disabled:opacity-50"><Plus className="h-4 w-4" /> Tambah mapping</button>}>
      <Table headers={['Kategori','Fungsi akun','Akun tujuan','Periode','Versi','Status']}>{data.rules.map((item) => <tr key={item.id} className="border-t border-slate-100"><td className="px-5 py-4 font-bold">{categoryById.get(item.transaction_category_id)?.category_name ?? '-'}</td><td className="px-5 py-4">{functionByKey.get(item.account_function_key)?.function_name ?? 'Fungsi tidak tersedia'}</td><td className="px-5 py-4"><p className="font-semibold">{accountById.get(item.account_id)?.account_name ?? '-'}</p><p className="mt-1 text-xs text-slate-400">{accountById.get(item.account_id)?.account_code}</p></td><td className="px-5 py-4 text-xs text-slate-500">{new Date(item.effective_from).toLocaleDateString('id-ID')} — {item.effective_to ? new Date(item.effective_to).toLocaleDateString('id-ID') : 'seterusnya'}</td><td className="px-5 py-4">v{item.rule_version}</td><td className="px-5 py-4"><span className={`rounded-full px-2.5 py-1 text-[11px] font-bold ${item.status === 'ACTIVE' ? 'bg-emerald-50 text-emerald-700' : 'bg-amber-50 text-amber-700'}`}>{item.status === 'ACTIVE' ? 'Aktif' : 'Draft'}</span></td></tr>)}</Table>
      {!loading && !data.rules.length && <Empty text="Belum ada mapping. Journal tetap tidak akan diposting sampai resolver Finance diaktifkan pada gate terpisah." />}
    </Section>}

    {tab === 'accounts' && <Section title="Chart of Accounts" description="Akun grup menyusun hierarki maksimal tiga tingkat. Hanya akun posting aktif yang dapat dipakai mapping." action={canManage && <button onClick={() => setAccountEditor(null)} className="inline-flex items-center gap-2 rounded-xl bg-emerald-500 px-4 py-2.5 text-sm font-bold text-white"><Plus className="h-4 w-4" /> Tambah akun</button>}>
      <Table headers={['Kode akun','Nama akun','Induk','Tipe','Saldo normal','Pemakaian','Status',...(canManage ? ['Aksi'] : [])]}>{data.accounts.map((item) => <tr key={item.id} className="border-t border-slate-100"><td className="px-5 py-4 font-mono text-xs text-slate-500">{item.account_code}</td><td className="px-5 py-4"><p className="font-bold">{item.account_name}</p>{item.is_system_account && <p className="mt-1 text-[11px] font-bold text-blue-600">Akun sistem</p>}</td><td className="px-5 py-4 text-slate-500">{item.parent_account_id ? accountById.get(item.parent_account_id)?.account_name ?? '-' : 'Akun utama'}</td><td className="px-5 py-4">{accountTypeLabels[item.account_type] ?? item.account_type}</td><td className="px-5 py-4">{item.normal_balance === 'DEBIT' ? 'Debit' : 'Kredit'}{defaultBalance[item.account_type] !== item.normal_balance && <p className="mt-1 text-[11px] font-bold text-amber-600">Override</p>}</td><td className="px-5 py-4 text-xs text-slate-500">{item.is_postable ? 'Akun posting' : 'Grup'}{item.allow_reconciliation ? ' · Rekonsiliasi' : ''}{item.allow_manual_posting ? ' · Manual' : ''}</td><td className="px-5 py-4"><Status active={item.is_active} /></td>{canManage && <td className="px-5 py-4 text-right"><button onClick={() => setAccountEditor(item)} className="rounded-lg border border-slate-200 p-2 text-slate-500" aria-label={`Edit ${item.account_name}`}><Edit3 className="h-4 w-4" /></button></td>}</tr>)}</Table>
      {!loading && !data.accounts.length && <Empty text="Akun tidak tersedia untuk role ini atau template COA belum diprovision." />}
    </Section>}

    {tab === 'fallbacks' && <Section title="Fallback fungsi akun Company" description="Dipakai hanya bila kategori transaksi tidak memiliki mapping yang lebih spesifik. Versi aktif baru menutup versi sebelumnya tanpa mengubah histori." action={canManage && <button onClick={() => setShowFallbackEditor(true)} className="inline-flex items-center gap-2 rounded-xl bg-emerald-500 px-4 py-2.5 text-sm font-bold text-white"><Plus className="h-4 w-4" /> Tambah versi fallback</button>}>
      <div className="border-b border-blue-100 bg-blue-50 p-4 text-sm leading-6 text-blue-800"><b>Bukan tebakan otomatis.</b> Finance memilih fungsi dan akun secara eksplisit. Jika mapping dan fallback belum ada, transaksi nanti harus ditahan saat engine Finance diaktifkan.</div>
      <Table headers={['Fungsi akun','Akun tujuan','Periode','Versi','Status']}>{data.fallbacks.map((item) => <tr key={item.id} className="border-t border-slate-100"><td className="px-5 py-4 font-bold">{functionByKey.get(item.account_function_key)?.function_name ?? 'Fungsi tidak tersedia'}</td><td className="px-5 py-4"><p className="font-semibold">{accountById.get(item.account_id)?.account_name ?? '-'}</p><p className="mt-1 text-xs text-slate-400">{accountById.get(item.account_id)?.account_code}</p></td><td className="px-5 py-4 text-xs text-slate-500">{new Date(item.effective_from).toLocaleDateString('id-ID')} — {item.effective_to ? new Date(item.effective_to).toLocaleDateString('id-ID') : 'seterusnya'}</td><td className="px-5 py-4">v{item.fallback_version}</td><td className="px-5 py-4"><span className={`rounded-full px-2.5 py-1 text-[11px] font-bold ${item.status === 'ACTIVE' ? 'bg-emerald-50 text-emerald-700' : 'bg-amber-50 text-amber-700'}`}>{item.status === 'ACTIVE' ? 'Aktif' : 'Draft'}</span></td></tr>)}</Table>
      {!loading && !data.fallbacks.length && <Empty text="Belum ada fallback Company. Ini aman selama posting Finance masih belum diaktifkan." />}
    </Section>}

    {categoryEditor !== undefined && <CategoryEditor session={session} record={categoryEditor ?? undefined} events={data.systemEvents} close={() => setCategoryEditor(undefined)} complete={async () => { setCategoryEditor(undefined); await refresh(); notify('Kategori transaksi berhasil disimpan.') }} />}
    {showRuleEditor && <RuleEditor session={session} categories={data.categories} events={data.systemEvents} functions={data.accountFunctions} accounts={data.accounts} close={() => setShowRuleEditor(false)} complete={async () => { setShowRuleEditor(false); await refresh(); notify('Versi mapping akun berhasil disimpan.') }} />}
    {accountEditor !== undefined && <AccountEditor session={session} record={accountEditor ?? undefined} functions={data.accountFunctions} accounts={data.accounts} close={() => setAccountEditor(undefined)} complete={async () => { setAccountEditor(undefined); await refresh(); notify('Chart of Account berhasil disimpan.') }} />}
    {showFallbackEditor && <FallbackEditor session={session} functions={data.accountFunctions} accounts={data.accounts} close={() => setShowFallbackEditor(false)} complete={async () => { setShowFallbackEditor(false); await refresh(); notify('Versi fallback Company berhasil disimpan.') }} />}
  </>
}

function CategoryEditor({ session, record, events, close, complete }: { session: Session; record?: Category; events: SystemEvent[]; close: () => void; complete: () => Promise<void> }) {
  useEscapeClose(close)
  const [form, setForm] = useState({ name: record?.category_name ?? '', systemKey: record?.system_key ?? events[0]?.system_key ?? '', description: record?.description ?? '', isActive: record?.is_active ?? true })
  const [saving, setSaving] = useState(false); const [error, setError] = useState('')
  async function submit(event: React.FormEvent) { event.preventDefault(); setSaving(true); setError(''); try { const response = await fetch(record ? `/api/master/finance-masters/${record.id}` : '/api/master/finance-masters', { method: record ? 'PATCH' : 'POST', headers: { 'Content-Type': 'application/json', ...authHeaders(session) }, body: JSON.stringify({ entityType: 'CATEGORY', ...form, ...(record ? { masterVersion: record.master_version } : {}) }) }); const payload = await response.json() as { error?: string }; if (!response.ok) throw new Error(friendlyError(payload.error)); await complete() } catch (caught) { setError(caught instanceof Error ? caught.message : 'Gagal menyimpan kategori.') } finally { setSaving(false) } }
  return <Modal title={record ? 'Edit Kategori Transaksi' : 'Tambah Kategori Khusus'} close={close}><form onSubmit={submit} className="space-y-5">{record?.is_system_default && <div className="rounded-xl border border-blue-100 bg-blue-50 p-3 text-sm text-blue-800"><b>Kategori bawaan wajib.</b> Nama dan penjelasan boleh disesuaikan. Jenis transaksi, identitas sistem, dan status aktif dikunci agar alur aplikasi tetap lengkap.</div>}<div className="grid gap-4 sm:grid-cols-2"><Field label="Nama yang dilihat pengguna"><input required className="input" value={form.name} onChange={(event) => setForm({ ...form, name: event.target.value })} placeholder="Contoh: Listrik" /><span className="mt-1 block text-xs text-slate-400">Nama harus unik. Identitas internal dibuat otomatis.</span></Field><Field label="Jenis transaksi sistem"><select disabled={record?.is_system_default} required className="input disabled:bg-slate-100" value={form.systemKey} onChange={(event) => setForm({ ...form, systemKey: event.target.value })}>{events.map((item) => <option key={item.system_key} value={item.system_key}>{item.event_name} — {groupLabels[item.event_group] ?? item.event_group}</option>)}</select></Field><Field label="Keterangan untuk membantu user"><input className="input" value={form.description} onChange={(event) => setForm({ ...form, description: event.target.value })} /></Field></div>{record?.is_system_default ? <div className="rounded-xl border border-slate-200 p-3 text-sm font-semibold text-slate-600">Status: Aktif wajib</div> : <Checkbox checked={form.isActive} onChange={(isActive) => setForm({ ...form, isActive })} label="Kategori aktif dan dapat dipilih" />}{error && <ErrorBox text={error} />}<Actions saving={saving} close={close} label="Simpan Kategori" /></form></Modal>
}

function RuleEditor({ session, categories, events, functions, accounts, close, complete }: { session: Session; categories: Category[]; events: SystemEvent[]; functions: AccountFunction[]; accounts: Account[]; close: () => void; complete: () => Promise<void> }) {
  useEscapeClose(close)
  const activeCategories = categories.filter((item) => item.is_active)
  const [form, setForm] = useState({ categoryId: activeCategories[0]?.id ?? '', accountFunctionKey: '', accountId: '', effectiveFrom: dateInput(new Date().toISOString()), effectiveTo: '', status: 'ACTIVE' })
  const [saving, setSaving] = useState(false); const [error, setError] = useState('')
  const category = categories.find((item) => item.id === form.categoryId)
  const systemEvent = events.find((item) => item.system_key === category?.system_key)
  const suggestedKeys = new Set([...(systemEvent?.required_account_functions ?? []), ...(systemEvent?.conditional_account_functions ?? [])])
  const availableFunctions = functions.filter((item) => !suggestedKeys.size || suggestedKeys.has(item.function_key))
  const selectedFunction = functions.find((item) => item.function_key === form.accountFunctionKey)
  const availableAccounts = accounts.filter((item) => item.is_active && item.is_postable && (!selectedFunction || selectedFunction.compatible_account_types.includes(item.account_type)))
  function changeCategory(categoryId: string) { setForm({ ...form, categoryId, accountFunctionKey: '', accountId: '' }) }
  function changeFunction(accountFunctionKey: string) { setForm({ ...form, accountFunctionKey, accountId: '' }) }
  async function submit(event: React.FormEvent) { event.preventDefault(); setSaving(true); setError(''); try { const response = await fetch('/api/master/finance-masters', { method: 'POST', headers: { 'Content-Type': 'application/json', ...authHeaders(session) }, body: JSON.stringify({ entityType: 'RULE', ...form, effectiveTo: form.effectiveTo || null }) }); const payload = await response.json() as { error?: string }; if (!response.ok) throw new Error(friendlyError(payload.error)); await complete() } catch (caught) { setError(caught instanceof Error ? caught.message : 'Gagal menyimpan mapping.') } finally { setSaving(false) } }
  return <Modal title="Tambah Versi Mapping Akun" close={close}><form onSubmit={submit} className="space-y-5"><div className="rounded-xl border border-blue-100 bg-blue-50 p-3 text-sm text-blue-800">Pilih berdasarkan nama. Versi aktif baru otomatis menutup periode versi aktif sebelumnya tanpa mengubah histori.</div><div className="grid gap-4 sm:grid-cols-2"><Field label="Kategori transaksi"><select required className="input" value={form.categoryId} onChange={(event) => changeCategory(event.target.value)}>{activeCategories.map((item) => <option key={item.id} value={item.id}>{item.category_name}</option>)}</select></Field><Field label="Fungsi akun"><select required className="input" value={form.accountFunctionKey} onChange={(event) => changeFunction(event.target.value)}><option value="">Pilih fungsi akun</option>{availableFunctions.map((item) => <option key={item.function_key} value={item.function_key}>{item.function_name}</option>)}</select></Field><Field label="Akun tujuan"><select required className="input" value={form.accountId} onChange={(event) => setForm({ ...form, accountId: event.target.value })}><option value="">Pilih akun yang kompatibel</option>{availableAccounts.map((item) => <option key={item.id} value={item.id}>{item.account_name} ({item.account_code})</option>)}</select></Field><Field label="Status"><select className="input" value={form.status} onChange={(event) => setForm({ ...form, status: event.target.value })}><option value="ACTIVE">Aktif setelah disimpan</option><option value="DRAFT">Draft</option></select></Field><Field label="Mulai berlaku"><input required type="datetime-local" className="input" value={form.effectiveFrom} onChange={(event) => setForm({ ...form, effectiveFrom: event.target.value })} /></Field><Field label="Berakhir (opsional)"><input type="datetime-local" className="input" value={form.effectiveTo} onChange={(event) => setForm({ ...form, effectiveTo: event.target.value })} /></Field></div>{error && <ErrorBox text={error} />}<Actions saving={saving} close={close} label="Simpan Versi Mapping" /></form></Modal>
}

function AccountEditor({ session, record, functions, accounts, close, complete }: { session: Session; record?: Account; functions: AccountFunction[]; accounts: Account[]; close: () => void; complete: () => Promise<void> }) {
  useEscapeClose(close)
  const initialType = record?.account_type ?? 'ASSET'
  const [form, setForm] = useState({ code: record?.account_code ?? '', name: record?.account_name ?? '', accountType: initialType, normalBalance: record?.normal_balance ?? defaultBalance[initialType], parentAccountId: record?.parent_account_id ?? '', systemFunctionKey: record?.system_function_key ?? '', isPostable: record?.is_postable ?? true, allowManualPosting: record?.allow_manual_posting ?? false, allowReconciliation: record?.allow_reconciliation ?? false, isActive: record?.is_active ?? true })
  const [saving, setSaving] = useState(false); const [error, setError] = useState('')
  const parents = accounts.filter((item) => item.id !== record?.id && item.is_active && !item.is_postable && item.account_type === form.accountType)
  const availableFunctions = functions.filter((item) => item.compatible_account_types.includes(form.accountType))
  const balanceOverride = defaultBalance[form.accountType] !== form.normalBalance
  function changeType(accountType: string) { setForm({ ...form, accountType, normalBalance: defaultBalance[accountType], parentAccountId: '', systemFunctionKey: '' }) }
  function changePostable(isPostable: boolean) { setForm({ ...form, isPostable, allowManualPosting: isPostable ? form.allowManualPosting : false }) }
  async function submit(event: React.FormEvent) { event.preventDefault(); setSaving(true); setError(''); try { const response = await fetch(record ? `/api/master/finance-masters/accounts/${record.id}` : '/api/master/finance-masters', { method: record ? 'PATCH' : 'POST', headers: { 'Content-Type': 'application/json', ...authHeaders(session) }, body: JSON.stringify({ entityType: 'ACCOUNT', ...form, parentAccountId: form.parentAccountId || null, systemFunctionKey: form.systemFunctionKey || null, ...(record ? { masterVersion: record.master_version } : {}) }) }); const payload = await response.json() as { error?: string }; if (!response.ok) throw new Error(friendlyError(payload.error)); await complete() } catch (caught) { setError(caught instanceof Error ? caught.message : 'Gagal menyimpan akun.') } finally { setSaving(false) } }
  return <Modal title={record ? 'Edit Chart of Account' : 'Tambah Chart of Account'} close={close}><form onSubmit={submit} className="space-y-5">{record?.is_system_account && <div className="rounded-xl border border-blue-100 bg-blue-50 p-3 text-sm text-blue-800"><b>Akun sistem.</b> Identitas boleh disesuaikan, tetapi penanda sistem dan perubahan yang merusak mapping atau histori akan ditolak server.</div>}<div className="grid gap-4 sm:grid-cols-2"><Field label="Nama akun"><input required className="input" value={form.name} onChange={(event) => setForm({ ...form, name: event.target.value })} placeholder="Contoh: Bank BCA" /></Field><Field label="Kode akun"><input required className="input" value={form.code} onChange={(event) => setForm({ ...form, code: event.target.value })} placeholder="Contoh: 1131" /></Field><Field label="Tipe akun"><select required className="input" value={form.accountType} onChange={(event) => changeType(event.target.value)}>{accountTypes.map((type) => <option key={type} value={type}>{accountTypeLabels[type]}</option>)}</select></Field><Field label="Saldo normal"><select className="input" value={form.normalBalance} onChange={(event) => setForm({ ...form, normalBalance: event.target.value })}><option value="DEBIT">Debit</option><option value="CREDIT">Kredit</option></select></Field><Field label="Akun induk (opsional)"><select className="input" value={form.parentAccountId} onChange={(event) => setForm({ ...form, parentAccountId: event.target.value })}><option value="">Akun utama / tanpa induk</option>{parents.map((item) => <option key={item.id} value={item.id}>{item.account_name} ({item.account_code})</option>)}</select></Field><Field label="Fungsi sistem (opsional)"><select className="input" value={form.systemFunctionKey} onChange={(event) => setForm({ ...form, systemFunctionKey: event.target.value })}><option value="">Tanpa fungsi khusus</option>{availableFunctions.map((item) => <option key={item.function_key} value={item.function_key}>{item.function_name}</option>)}</select></Field></div>{balanceOverride && <div className="rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-800"><b>Saldo normal di-override.</b> Default untuk {accountTypeLabels[form.accountType]} adalah {defaultBalance[form.accountType] === 'DEBIT' ? 'Debit' : 'Kredit'}. Gunakan override hanya untuk akun kontra yang memang diperlukan.</div>}<div className="grid gap-3 sm:grid-cols-2"><Checkbox checked={form.isPostable} onChange={changePostable} label="Akun dapat menerima posting" /><Checkbox checked={form.allowManualPosting} onChange={(allowManualPosting) => setForm({ ...form, allowManualPosting })} label="Boleh untuk jurnal manual" /><Checkbox checked={form.allowReconciliation} onChange={(allowReconciliation) => setForm({ ...form, allowReconciliation })} label="Perlu rekonsiliasi" /><Checkbox checked={form.isActive} onChange={(isActive) => setForm({ ...form, isActive })} label="Akun aktif" /></div>{error && <ErrorBox text={error} />}<Actions saving={saving} close={close} label="Simpan Akun" /></form></Modal>
}

function FallbackEditor({ session, functions, accounts, close, complete }: { session: Session; functions: AccountFunction[]; accounts: Account[]; close: () => void; complete: () => Promise<void> }) {
  useEscapeClose(close)
  const [form, setForm] = useState({ accountFunctionKey: '', accountId: '', effectiveFrom: dateInput(new Date().toISOString()), effectiveTo: '', status: 'ACTIVE' })
  const [saving, setSaving] = useState(false); const [error, setError] = useState('')
  const selectedFunction = functions.find((item) => item.function_key === form.accountFunctionKey)
  const availableAccounts = accounts.filter((item) => item.is_active && item.is_postable && (!selectedFunction || selectedFunction.compatible_account_types.includes(item.account_type)))
  function changeFunction(accountFunctionKey: string) { setForm({ ...form, accountFunctionKey, accountId: '' }) }
  async function submit(event: React.FormEvent) { event.preventDefault(); setSaving(true); setError(''); try { const response = await fetch('/api/master/finance-masters', { method: 'POST', headers: { 'Content-Type': 'application/json', ...authHeaders(session) }, body: JSON.stringify({ entityType: 'FALLBACK', ...form, effectiveTo: form.effectiveTo || null }) }); const payload = await response.json() as { error?: string }; if (!response.ok) throw new Error(friendlyError(payload.error)); await complete() } catch (caught) { setError(caught instanceof Error ? caught.message : 'Gagal menyimpan fallback.') } finally { setSaving(false) } }
  return <Modal title="Tambah Versi Fallback Company" close={close}><form onSubmit={submit} className="space-y-5"><div className="rounded-xl border border-blue-100 bg-blue-50 p-3 text-sm leading-6 text-blue-800">Pilih berdasarkan <b>nama fungsi</b> dan <b>nama akun</b>. Jika versi baru diaktifkan, versi lama untuk fungsi yang sama otomatis berakhir pada tanggal mulai ini.</div><div className="grid gap-4 sm:grid-cols-2"><Field label="Fungsi akun"><select required className="input" value={form.accountFunctionKey} onChange={(event) => changeFunction(event.target.value)}><option value="">Pilih fungsi akun</option>{functions.map((item) => <option key={item.function_key} value={item.function_key}>{item.function_name}</option>)}</select></Field><Field label="Akun fallback"><select required className="input" value={form.accountId} onChange={(event) => setForm({ ...form, accountId: event.target.value })}><option value="">Pilih akun yang kompatibel</option>{availableAccounts.map((item) => <option key={item.id} value={item.id}>{item.account_name} ({item.account_code})</option>)}</select></Field><Field label="Mulai berlaku"><input required type="datetime-local" className="input" value={form.effectiveFrom} onChange={(event) => setForm({ ...form, effectiveFrom: event.target.value })} /></Field><Field label="Berakhir (opsional)"><input type="datetime-local" className="input" value={form.effectiveTo} onChange={(event) => setForm({ ...form, effectiveTo: event.target.value })} /></Field><Field label="Status"><select className="input" value={form.status} onChange={(event) => setForm({ ...form, status: event.target.value })}><option value="ACTIVE">Aktif setelah disimpan</option><option value="DRAFT">Draft</option></select></Field></div>{error && <ErrorBox text={error} />}<Actions saving={saving} close={close} label="Simpan Versi Fallback" /></form></Modal>
}

function Section({ title, description, action, children }: { title: string; description: string; action?: React.ReactNode; children: React.ReactNode }) { return <section className="rounded-2xl border border-slate-200 bg-white shadow-sm"><div className="flex flex-col gap-3 border-b border-slate-100 p-5 sm:flex-row sm:items-center sm:justify-between"><div><h2 className="font-black text-slate-950">{title}</h2><p className="mt-1 text-sm text-slate-500">{description}</p></div>{action}</div>{children}</section> }
function Table({ headers, children }: { headers: string[]; children: React.ReactNode }) { return <div className="overflow-x-auto"><table className="w-full min-w-[900px] text-left text-sm"><thead className="bg-slate-50 text-xs uppercase tracking-wider text-slate-500"><tr>{headers.map((header) => <th key={header} className="px-5 py-4 last:text-right">{header}</th>)}</tr></thead><tbody>{children}</tbody></table></div> }
function Empty({ text }: { text: string }) { return <div className="border-t border-slate-100 p-10 text-center text-sm text-slate-400">{text}</div> }
function Guide({ number, title, text }: { number: string; title: string; text: string }) { return <div className="rounded-2xl border border-slate-200 bg-white p-4"><div className="mb-3 flex h-7 w-7 items-center justify-center rounded-full bg-emerald-100 text-xs font-black text-emerald-700">{number}</div><p className="font-black text-slate-900">{title}</p><p className="mt-1 text-sm leading-6 text-slate-500">{text}</p></div> }
function Modal({ title, close, children }: { title: string; close: () => void; children: React.ReactNode }) { return <div className="fixed inset-0 z-[70] overflow-y-auto bg-slate-950/50 p-4 backdrop-blur-sm"><div className="mx-auto my-6 max-w-4xl rounded-3xl bg-white shadow-2xl"><div className="flex items-center justify-between border-b border-slate-100 p-6"><div><p className="text-xs font-bold uppercase tracking-wider text-emerald-600">Master Finance</p><h2 className="mt-2 text-xl font-black">{title}</h2></div><button type="button" onClick={close} className="rounded-xl border border-slate-200 p-2 text-slate-500" aria-label="Tutup"><X className="h-5 w-5" /></button></div><div className="p-6">{children}</div></div></div> }
function Field({ label, children }: { label: string; children: React.ReactNode }) { return <label className="block"><span className="mb-2 block text-sm font-bold text-slate-700">{label}</span>{children}</label> }
function Checkbox({ checked, onChange, label }: { checked: boolean; onChange: (value: boolean) => void; label: string }) { return <label className="flex items-center gap-3 rounded-xl border border-slate-200 p-3 text-sm font-semibold"><input type="checkbox" checked={checked} onChange={(event) => onChange(event.target.checked)} className="h-4 w-4 accent-emerald-500" />{label}</label> }
function Status({ active }: { active: boolean }) { return <span className={`rounded-full px-2.5 py-1 text-[11px] font-bold ${active ? 'bg-emerald-50 text-emerald-700' : 'bg-slate-100 text-slate-500'}`}>{active ? 'Aktif' : 'Nonaktif'}</span> }
function ErrorBox({ text }: { text: string }) { return <div className="rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-700">{text}</div> }
function Actions({ saving, close, label }: { saving: boolean; close: () => void; label: string }) { return <div className="flex justify-end gap-3 border-t border-slate-100 pt-5"><button type="button" onClick={close} className="rounded-xl border border-slate-200 px-5 py-3 text-sm font-bold text-slate-600">Batal</button><button disabled={saving} className="inline-flex items-center gap-2 rounded-xl bg-emerald-500 px-5 py-3 text-sm font-bold text-white disabled:opacity-60">{saving && <Loader2 className="h-4 w-4 animate-spin" />}{label}</button></div> }
