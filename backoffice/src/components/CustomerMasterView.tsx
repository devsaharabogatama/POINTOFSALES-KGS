'use client'

import { useCallback, useEffect, useMemo, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import { useEscapeClose } from '@/lib/use-escape-close'
import { CustomerGroupingPanel } from '@/components/CustomerGroupingPanel'
import { ContactRound, Edit3, Layers3, Loader2, Plus, RefreshCcw, Search, ShieldCheck, X } from 'lucide-react'

type Category = { id: string; category_code: string; category_name: string; is_system_category: boolean; is_active: boolean; master_version: number }
type Customer = {
  id: string; code: string; name: string; customer_category_id: string; phone: string | null
  email: string | null; address: string | null; customer_type: 'INDIVIDUAL' | 'BUSINESS' | 'WALK_IN'
  current_balance: number | string; credit_limit: number | string; credit_term_days: number | null
  is_active: boolean; is_system_customer: boolean; notes: string | null; master_version: number
  parent_customer_id: string | null
  default_pricelist_id: string | null
  category: { id: string; category_code: string; category_name: string; is_system_category: boolean; is_active: boolean } | null
}
type PricelistOption = { id: string; name: string; scope: 'GLOBAL' | 'CUSTOMER'; is_active: boolean }
type Editor = { kind: 'customer'; record?: Customer } | { kind: 'category'; record?: Category }
type ApiList<T> = { data?: T[]; error?: string }

const authHeaders = (session: Session) => ({ Authorization: `Bearer ${session.access_token}` })
const rupiah = (value: number | string) => new Intl.NumberFormat('id-ID', { style: 'currency', currency: 'IDR', maximumFractionDigits: 0 }).format(Number(value) || 0)

function friendlyError(code?: string) {
  const messages: Record<string, string> = {
    MASTER_VERSION_CONFLICT: 'Data sudah berubah di tab lain. Muat ulang lalu edit kembali.',
    DUPLICATE_CUSTOMER: 'Kode atau nama Customer sudah digunakan pada company aktif.',
    DUPLICATE_CUSTOMER_CATEGORY: 'Nama kategori Customer sudah digunakan.',
    ACTIVE_CUSTOMER_CATEGORY_NOT_FOUND: 'Kategori Customer tidak aktif atau bukan milik company aktif.',
    SYSTEM_CUSTOMER_IMMUTABLE: 'Pelanggan Umum adalah data sistem dan tidak dapat diedit.',
    SYSTEM_CUSTOMER_CATEGORY_IMMUTABLE: 'Kategori Umum adalah data sistem dan tidak dapat diedit.',
    CUSTOMER_MANAGER_REQUIRED: 'Role Anda tidak diizinkan mengubah identitas Customer.',
    CUSTOMER_CREDIT_MANAGER_REQUIRED: 'Hanya Owner, Admin, Finance, atau Accounting yang dapat mengubah batas dan termin kredit.',
    INVALID_CUSTOMER_CREDIT_LIMIT: 'Batas kredit tidak valid.',
    INVALID_CUSTOMER_CREDIT_TERM: 'Termin kredit harus 0 sampai 3650 hari.',
    CUSTOMER_CODE_REQUIRED: 'Kode Customer wajib diisi saat mengedit.',
    ACTIVE_ROOT_PARENT_CUSTOMER_NOT_FOUND: 'Customer induk tidak aktif, bukan milik company aktif, atau sudah merupakan Customer cabang.',
    CUSTOMER_WITH_CHILDREN_CANNOT_BECOME_CHILD: 'Customer yang sudah memiliki cabang tidak dapat dijadikan Customer cabang.',
    CUSTOMER_CANNOT_PARENT_ITSELF: 'Customer tidak dapat menjadi induk untuk dirinya sendiri.',
    ACTIVE_CUSTOMER_PRICELIST_NOT_FOUND: 'Pricelist khusus tidak aktif atau bukan milik company aktif.',
    SYSTEM_CUSTOMER_CANNOT_HAVE_PRICELIST: 'Pelanggan Umum wajib memakai Harga Umum Global.',
    FORBIDDEN: 'Role Anda tidak diizinkan mengakses Customer.',
  }
  return messages[code ?? ''] ?? code ?? 'Operasi Customer gagal.'
}

export function CustomerMasterView({ session, companyId, canManageIdentity, canManageCredit, notify }: {
  session: Session; companyId: string; canManageIdentity: boolean; canManageCredit: boolean; notify: (message: string) => void
}) {
  const [tab, setTab] = useState<'customer' | 'category'>('customer')
  const [customers, setCustomers] = useState<Customer[]>([])
  const [categories, setCategories] = useState<Category[]>([])
  const [pricelists, setPricelists] = useState<PricelistOption[]>([])
  const [query, setQuery] = useState('')
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [editor, setEditor] = useState<Editor | null>(null)
  useEscapeClose(() => setEditor(null))

  const fetchData = useCallback(async () => {
    const responses = await Promise.all([
      fetch('/api/master/customers?includeInactive=true', { headers: authHeaders(session) }),
      fetch('/api/master/customer-categories?includeInactive=true', { headers: authHeaders(session) }),
      fetch('/api/master/pricelists?includeInactive=true', { headers: authHeaders(session) }),
    ])
    const payloads = await Promise.all(responses.map((response) => response.json())) as [ApiList<Customer>, ApiList<Category>, ApiList<PricelistOption>]
    const failed = responses.findIndex((response) => !response.ok)
    if (failed >= 0) throw new Error(friendlyError(payloads[failed].error))
    return payloads
  }, [session])

  const refresh = useCallback(async () => {
    setLoading(true); setError('')
    try { const data = await fetchData(); setCustomers(data[0].data ?? []); setCategories(data[1].data ?? []); setPricelists(data[2].data ?? []) }
    catch (caught) { setError(caught instanceof Error ? caught.message : 'Gagal memuat Customer.') }
    finally { setLoading(false) }
  }, [fetchData])

  useEffect(() => { let cancelled = false; fetchData().then((data) => { if (!cancelled) { setCustomers(data[0].data ?? []); setCategories(data[1].data ?? []); setPricelists(data[2].data ?? []) } }).catch((caught) => { if (!cancelled) setError(caught instanceof Error ? caught.message : 'Gagal memuat Customer.') }).finally(() => { if (!cancelled) setLoading(false) }); return () => { cancelled = true } }, [companyId, fetchData])

  const normalized = query.trim().toLowerCase()
  const filteredCustomers = useMemo(() => customers.filter((item) => !normalized || [item.code, item.name, item.phone ?? '', item.email ?? '', item.category?.category_name ?? ''].some((value) => value.toLowerCase().includes(normalized))), [customers, normalized])
  const filteredCategories = useMemo(() => categories.filter((item) => !normalized || item.category_name.toLowerCase().includes(normalized)), [categories, normalized])
  const canEditCustomer = canManageIdentity || canManageCredit
  const pricelistById = useMemo(() => new Map(pricelists.map((item) => [item.id, item])), [pricelists])

  return <>
    <div className="mb-7 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between"><div><p className="text-xs font-bold uppercase tracking-[.16em] text-emerald-600">Master Penjualan</p><h1 className="mt-2 text-2xl font-black tracking-tight text-slate-950 md:text-3xl">Customer</h1><p className="mt-2 text-sm text-slate-500">Kelola identitas, kategori, dan konfigurasi kredit. Saldo hanya ditampilkan dan belum dapat dikoreksi dari menu ini.</p></div><div className="flex gap-2"><button onClick={() => void refresh()} className="inline-flex items-center gap-2 rounded-xl border border-slate-200 bg-white px-4 py-3 text-sm font-bold text-slate-600"><RefreshCcw className={`h-4 w-4 ${loading ? 'animate-spin' : ''}`} /> Muat ulang</button>{((tab === 'customer' && canManageIdentity) || (tab === 'category' && canManageIdentity)) && <button onClick={() => setEditor({ kind: tab })} className="inline-flex items-center gap-2 rounded-xl bg-emerald-500 px-4 py-3 text-sm font-bold text-white"><Plus className="h-4 w-4" /> {tab === 'customer' ? 'Tambah Customer' : 'Tambah Kategori'}</button>}</div></div>
    <div className="mb-5 inline-flex rounded-xl border border-slate-200 bg-white p-1"><Tab active={tab === 'customer'} onClick={() => setTab('customer')} icon={<ContactRound className="h-4 w-4" />} label="Daftar Customer" /><Tab active={tab === 'category'} onClick={() => setTab('category')} icon={<Layers3 className="h-4 w-4" />} label="Kategori Customer" /></div>
    <div className="mb-5 rounded-2xl border border-blue-100 bg-blue-50 p-4 text-sm leading-6 text-blue-800"><ShieldCheck className="mr-2 inline h-4 w-4" /><b>Pelanggan Umum</b> dibuat otomatis untuk transaksi tanpa identitas pelanggan dan tidak dapat diedit. Saldo Customer berasal dari ledger pada fase berikutnya, bukan input manual.</div>
    {error && <div className="mb-5 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-700">{error}</div>}
    <div className="rounded-2xl border border-slate-200 bg-white shadow-sm"><div className="flex items-center gap-3 border-b border-slate-100 p-4"><Search className="h-4 w-4 text-slate-400" /><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder={tab === 'customer' ? 'Cari kode, nama, telepon, email, atau kategori...' : 'Cari kategori Customer...'} className="w-full bg-transparent text-sm outline-none" /></div><div className="overflow-x-auto">
      {tab === 'customer' ? <table className="w-full min-w-[1200px] text-left text-sm"><thead className="bg-slate-50 text-xs uppercase tracking-wider text-slate-500"><tr><th className="px-5 py-4">Customer</th><th className="px-5 py-4">Kategori / tipe</th><th className="px-5 py-4">Pricelist</th><th className="px-5 py-4">Kontak</th><th className="px-5 py-4 text-right">Batas kredit</th><th className="px-5 py-4">Termin</th><th className="px-5 py-4 text-right">Saldo (read-only)</th><th className="px-5 py-4">Status</th>{canEditCustomer && <th className="px-5 py-4 text-right">Aksi</th>}</tr></thead><tbody className="divide-y divide-slate-100">{filteredCustomers.map((item) => <tr key={item.id}><td className="px-5 py-4"><p className="font-bold">{item.name}{item.is_system_customer && <span className="ml-2 rounded-full bg-blue-50 px-2 py-1 text-[10px] text-blue-700">Sistem</span>}</p><p className="mt-1 text-xs font-semibold text-slate-400">{item.code}</p></td><td className="px-5 py-4"><p className="font-semibold">{item.category?.category_name ?? '-'}</p><p className="mt-1 text-xs text-slate-400">{item.customer_type === 'BUSINESS' ? 'Bisnis' : item.customer_type === 'WALK_IN' ? 'Walk-in' : 'Perorangan'}</p></td><td className="px-5 py-4"><p className="font-semibold">{pricelistById.get(item.default_pricelist_id ?? '')?.name ?? 'Harga Umum'}</p><p className="mt-1 text-xs text-slate-400">{item.default_pricelist_id ? 'Khusus Customer' : 'Global default'}</p></td><td className="px-5 py-4"><p>{item.phone ?? '-'}</p><p className="mt-1 text-xs text-slate-400">{item.email ?? '-'}</p></td><td className="px-5 py-4 text-right">{rupiah(item.credit_limit)}</td><td className="px-5 py-4">{item.credit_term_days === null ? 'Tunai / tidak diatur' : `${item.credit_term_days} hari`}</td><td className="px-5 py-4 text-right font-bold text-slate-700">{rupiah(item.current_balance)}</td><td className="px-5 py-4"><Status active={item.is_active} /></td>{canEditCustomer && <td className="px-5 py-4 text-right">{!item.is_system_customer && <EditButton onClick={() => setEditor({ kind: 'customer', record: item })} />}</td>}</tr>)}{!loading && !filteredCustomers.length && <tr><td colSpan={canEditCustomer ? 9 : 8} className="p-10 text-center text-slate-400">Belum ada Customer.</td></tr>}</tbody></table> : <table className="w-full min-w-[520px] text-left text-sm"><thead className="bg-slate-50 text-xs uppercase tracking-wider text-slate-500"><tr><th className="px-5 py-4">Kategori</th><th className="px-5 py-4">Status</th>{canManageIdentity && <th className="px-5 py-4 text-right">Aksi</th>}</tr></thead><tbody className="divide-y divide-slate-100">{filteredCategories.map((item) => <tr key={item.id}><td className="px-5 py-4 font-bold">{item.category_name}{item.is_system_category && <span className="ml-2 rounded-full bg-blue-50 px-2 py-1 text-[10px] text-blue-700">Sistem</span>}</td><td className="px-5 py-4"><Status active={item.is_active} /></td>{canManageIdentity && <td className="px-5 py-4 text-right">{!item.is_system_category && <EditButton onClick={() => setEditor({ kind: 'category', record: item })} />}</td>}</tr>)}</tbody></table>}
      {loading && <div className="p-10 text-center text-sm text-slate-500">Memuat master Customer...</div>}
    </div></div>
    {canManageIdentity && customers.filter((item) => !item.is_system_customer).length < 2 && (
      <div className="mt-5 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm leading-6 text-amber-800">
        Buat minimal dua Customer biasa untuk mengaktifkan grouping induk dan cabang. Pilihan Customer induk pada modal Edit Customer tercatat sebagai penyempurnaan UX berikutnya.
      </div>
    )}
    <CustomerGroupingPanel session={session} customers={customers} canManage={canManageIdentity} refresh={refresh} notify={notify} />
    {editor?.kind === 'customer' && <CustomerEditor session={session} record={editor.record} categories={categories} pricelists={pricelists} canManageIdentity={canManageIdentity} canManageCredit={canManageCredit} close={() => setEditor(null)} complete={async () => { setEditor(null); await refresh(); notify('Customer berhasil disimpan.') }} />}
    {editor?.kind === 'category' && <CategoryEditor session={session} record={editor.record} close={() => setEditor(null)} complete={async () => { setEditor(null); await refresh(); notify('Kategori Customer berhasil disimpan.') }} />}
  </>
}

function CustomerEditor({ session, record, categories, pricelists, canManageIdentity, canManageCredit, close, complete }: { session: Session; record?: Customer; categories: Category[]; pricelists: PricelistOption[]; canManageIdentity: boolean; canManageCredit: boolean; close: () => void; complete: () => Promise<void> }) {
  useEscapeClose(close)
  const activeCategories = categories.filter((item) => item.is_active || item.id === record?.customer_category_id)
  const [form, setForm] = useState({ customerCode: record?.code ?? '', customerName: record?.name ?? '', customerCategoryId: record?.customer_category_id ?? activeCategories[0]?.id ?? '', defaultPricelistId: record?.default_pricelist_id ?? '', phone: record?.phone ?? '', email: record?.email ?? '', address: record?.address ?? '', customerType: record?.customer_type === 'BUSINESS' ? 'BUSINESS' : 'INDIVIDUAL', creditLimit: String(record?.credit_limit ?? 0), creditTermDays: record?.credit_term_days === null || record?.credit_term_days === undefined ? '' : String(record.credit_term_days), notes: record?.notes ?? '', isActive: record?.is_active ?? true })
  const [saving, setSaving] = useState(false); const [error, setError] = useState('')
  async function submit(event: React.FormEvent) { event.preventDefault(); setSaving(true); setError(''); try { const response = await fetch(record ? `/api/master/customers/${record.id}` : '/api/master/customers', { method: record ? 'PATCH' : 'POST', headers: { 'Content-Type': 'application/json', ...authHeaders(session) }, body: JSON.stringify({ ...form, creditLimit: Number(form.creditLimit || 0), creditTermDays: form.creditTermDays === '' ? null : Number(form.creditTermDays), ...(record ? { masterVersion: record.master_version } : {}) }) }); const payload = await response.json() as { error?: string }; if (!response.ok) throw new Error(friendlyError(payload.error)); await complete() } catch (caught) { setError(caught instanceof Error ? caught.message : 'Gagal menyimpan Customer.') } finally { setSaving(false) } }
  const identityDisabled = !canManageIdentity
  return <Modal title={record ? 'Edit Customer' : 'Tambah Customer'} description="Identitas, Pricelist, dan konfigurasi kredit disimpan terpisah dari saldo. Kosongkan kode saat membuat Customer agar sistem membuat CUST-000001 dan seterusnya." close={close}>
    <form onSubmit={submit} className="space-y-5">
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="Kode Customer"><input disabled={identityDisabled} required={Boolean(record)} placeholder="Otomatis jika dikosongkan" value={form.customerCode} onChange={(e) => setForm({ ...form, customerCode: e.target.value.toUpperCase() })} className="input disabled:bg-slate-100" /></Field>
        <Field label="Nama Customer"><input disabled={identityDisabled} required value={form.customerName} onChange={(e) => setForm({ ...form, customerName: e.target.value })} className="input disabled:bg-slate-100" /></Field>
        <Field label="Kategori Customer"><select disabled={identityDisabled} required value={form.customerCategoryId} onChange={(e) => setForm({ ...form, customerCategoryId: e.target.value })} className="input disabled:bg-slate-100">{activeCategories.map((item) => <option key={item.id} value={item.id}>{item.category_name}</option>)}</select></Field>
        <Field label="Tipe Customer"><select disabled={identityDisabled} value={form.customerType} onChange={(e) => setForm({ ...form, customerType: e.target.value as 'INDIVIDUAL' | 'BUSINESS' })} className="input disabled:bg-slate-100"><option value="INDIVIDUAL">Perorangan</option><option value="BUSINESS">Bisnis</option></select></Field>
        <Field label="Pricelist khusus"><select disabled={identityDisabled} value={form.defaultPricelistId} onChange={(e) => setForm({ ...form, defaultPricelistId: e.target.value })} className="input disabled:bg-slate-100"><option value="">Harga Umum (Global default)</option>{pricelists.filter((item) => item.scope === 'CUSTOMER' && item.is_active).map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}</select><span className="mt-1 block text-xs text-slate-400">Pricelist yang sama dapat dipakai banyak Customer.</span></Field>
        <Field label="Telepon (opsional)"><input disabled={identityDisabled} value={form.phone} onChange={(e) => setForm({ ...form, phone: e.target.value })} className="input disabled:bg-slate-100" /></Field>
        <Field label="Email (opsional)"><input disabled={identityDisabled} type="email" value={form.email} onChange={(e) => setForm({ ...form, email: e.target.value })} className="input disabled:bg-slate-100" /></Field>
      </div>
      <Field label="Alamat (opsional)"><textarea disabled={identityDisabled} rows={2} value={form.address} onChange={(e) => setForm({ ...form, address: e.target.value })} className="input resize-none disabled:bg-slate-100" /></Field>
      <div className="rounded-2xl border border-amber-100 bg-amber-50 p-4"><p className="mb-1 text-sm font-bold text-amber-900">Konfigurasi kredit — bukan saldo</p><p className="mb-4 text-xs leading-5 text-amber-700">Batas kredit dan termin hanya mengatur kebijakan Customer. Saldo tetap berasal dari ledger dan tidak dapat diinput di sini.</p><div className="grid gap-4 sm:grid-cols-2"><Field label="Batas kredit"><input disabled={!canManageCredit} min={0} step="any" type="number" value={form.creditLimit} onChange={(e) => setForm({ ...form, creditLimit: e.target.value })} className="input bg-white disabled:bg-slate-100" /></Field><Field label="Termin kredit (hari, opsional)"><input disabled={!canManageCredit} min={0} max={3650} type="number" value={form.creditTermDays} onChange={(e) => setForm({ ...form, creditTermDays: e.target.value })} className="input bg-white disabled:bg-slate-100" /></Field></div>{record && <p className="mt-3 text-xs font-semibold text-amber-800">Saldo saat ini: {rupiah(record.current_balance)} — read-only</p>}</div>
      <Field label="Catatan (opsional)"><textarea disabled={identityDisabled} rows={2} value={form.notes} onChange={(e) => setForm({ ...form, notes: e.target.value })} className="input resize-none disabled:bg-slate-100" /></Field>
      <Checkbox disabled={identityDisabled} checked={form.isActive} onChange={(value) => setForm({ ...form, isActive: value })} label="Customer aktif dan dapat dipilih" />
      {error && <FormError message={error} />}<Actions saving={saving} close={close} label="Simpan Customer" />
    </form>
  </Modal>
}

function CategoryEditor({ session, record, close, complete }: { session: Session; record?: Category; close: () => void; complete: () => Promise<void> }) { const [form, setForm] = useState({ categoryName: record?.category_name ?? '', isActive: record?.is_active ?? true }); const [saving, setSaving] = useState(false); const [error, setError] = useState(''); async function submit(event: React.FormEvent) { event.preventDefault(); setSaving(true); setError(''); try { const response = await fetch(record ? `/api/master/customer-categories/${record.id}` : '/api/master/customer-categories', { method: record ? 'PATCH' : 'POST', headers: { 'Content-Type': 'application/json', ...authHeaders(session) }, body: JSON.stringify({ ...form, ...(record ? { masterVersion: record.master_version } : {}) }) }); const payload = await response.json() as { error?: string }; if (!response.ok) throw new Error(friendlyError(payload.error)); await complete() } catch (caught) { setError(caught instanceof Error ? caught.message : 'Gagal menyimpan kategori.') } finally { setSaving(false) } } return <Modal title={record ? 'Edit Kategori Customer' : 'Tambah Kategori Customer'} description="Nama kategori harus unik dan identitas internal dibuat otomatis. Kategori sistem Umum tidak dapat diedit." close={close}><form onSubmit={submit} className="space-y-5"><Field label="Nama kategori"><input required value={form.categoryName} onChange={(e) => setForm({ ...form, categoryName: e.target.value })} className="input" /></Field><Checkbox checked={form.isActive} onChange={(value) => setForm({ ...form, isActive: value })} label="Kategori aktif dan dapat dipilih" />{error && <FormError message={error} />}<Actions saving={saving} close={close} label="Simpan Kategori" /></form></Modal> }

function Tab({ active, onClick, icon, label }: { active: boolean; onClick: () => void; icon: React.ReactNode; label: string }) { return <button onClick={onClick} className={`inline-flex items-center gap-2 rounded-lg px-4 py-2.5 text-sm font-bold ${active ? 'bg-slate-950 text-white' : 'text-slate-500'}`}>{icon}{label}</button> }
function Status({ active }: { active: boolean }) { return <span className={`rounded-full px-2.5 py-1 text-[11px] font-bold ${active ? 'bg-emerald-50 text-emerald-700' : 'bg-slate-100 text-slate-500'}`}>{active ? 'Aktif' : 'Nonaktif'}</span> }
function EditButton({ onClick }: { onClick: () => void }) { return <button onClick={onClick} className="rounded-lg border border-slate-200 p-2 text-slate-500 hover:text-emerald-600" aria-label="Edit"><Edit3 className="h-4 w-4" /></button> }
function Field({ label, children }: { label: string; children: React.ReactNode }) { return <label className="block"><span className="mb-2 block text-sm font-bold text-slate-700">{label}</span>{children}</label> }
function Checkbox({ checked, onChange, label, disabled = false }: { checked: boolean; onChange: (value: boolean) => void; label: string; disabled?: boolean }) { return <label className="flex items-center gap-3 rounded-xl border border-slate-200 p-4 text-sm font-semibold"><input disabled={disabled} type="checkbox" checked={checked} onChange={(e) => onChange(e.target.checked)} className="h-4 w-4 accent-emerald-500" />{label}</label> }
function FormError({ message }: { message: string }) { return <div className="rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-700">{message}</div> }
function Actions({ saving, close, label }: { saving: boolean; close: () => void; label: string }) { return <div className="flex justify-end gap-3 border-t border-slate-100 pt-5"><button type="button" onClick={close} className="rounded-xl border border-slate-200 px-5 py-3 text-sm font-bold text-slate-600">Batal</button><button disabled={saving} type="submit" className="inline-flex items-center gap-2 rounded-xl bg-emerald-500 px-5 py-3 text-sm font-bold text-white disabled:opacity-60">{saving && <Loader2 className="h-4 w-4 animate-spin" />}{label}</button></div> }
function Modal({ title, description, close, children }: { title: string; description: string; close: () => void; children: React.ReactNode }) { return <div className="fixed inset-0 z-[70] overflow-y-auto bg-slate-950/50 p-4 backdrop-blur-sm"><div className="mx-auto my-6 max-w-4xl rounded-3xl bg-white shadow-2xl"><div className="flex items-start justify-between border-b border-slate-100 p-6"><div><h2 className="text-xl font-black text-slate-950">{title}</h2><p className="mt-2 max-w-2xl text-sm leading-6 text-slate-500">{description}</p></div><button onClick={close} className="rounded-xl border border-slate-200 p-2 text-slate-500" aria-label="Tutup"><X className="h-5 w-5" /></button></div><div className="p-6">{children}</div></div></div> }
