'use client'

import { useCallback, useEffect, useMemo, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import { Edit3, Loader2, Plus, RefreshCcw, Search, Tags, Trash2, X } from 'lucide-react'
import { useEscapeClose } from '@/lib/use-escape-close'

type StoreOption = { id: string; store_code: string; store_name: string; status: string }
type ProductUom = {
  id: string; uom_id: string; factor_to_base: number | string; sales_allowed: boolean
  sale_price: number | string | null; is_active: boolean
  uom: { id: string; name: string; is_active: boolean } | null
}
type Product = { id: string; sku: string; name: string; is_active: boolean; product_uoms: ProductUom[] }
type PricelistRule = {
  id: string; product_id: string; product_uom_id: string; min_qty: number | string
  tier_qty_basis: 'SALES_UOM' | 'BASE_UOM_EQUIVALENT'
  pricing_method: 'FIXED_PRICE' | 'DISCOUNT_AMOUNT' | 'DISCOUNT_PERCENT'
  fixed_unit_price: number | string | null; discount_amount_per_unit: number | string | null
  discount_percent: number | string | null; is_active: boolean
}
type Pricelist = {
  id: string; code: string; name: string; scope: 'GLOBAL' | 'CUSTOMER'; customer_id: string | null
  priority: number; is_default: boolean; applies_all_stores: boolean
  valid_from: string | null; valid_until: string | null; is_active: boolean; notes: string | null
  master_version: number; store_assignments: { id: string; store_id: string }[]; rules: PricelistRule[]
}
type ApiList<T> = { data?: T[]; stores?: StoreOption[]; error?: string }
type RuleForm = {
  productId: string; productUomId: string; minQty: string
  tierQtyBasis: 'SALES_UOM' | 'BASE_UOM_EQUIVALENT'
  pricingMethod: 'FIXED_PRICE' | 'DISCOUNT_AMOUNT' | 'DISCOUNT_PERCENT'; value: string; isActive: boolean
}

const authHeaders = (session: Session) => ({ Authorization: `Bearer ${session.access_token}` })
const rupiah = (value: number | string | null) => new Intl.NumberFormat('id-ID', { style: 'currency', currency: 'IDR', maximumFractionDigits: 0 }).format(Number(value) || 0)
const dateInput = (value: string | null) => value ? new Date(value).toISOString().slice(0, 16) : ''

function friendlyError(code?: string) {
  const messages: Record<string, string> = {
    MASTER_VERSION_CONFLICT: 'Pricelist sudah berubah di tab lain. Muat ulang lalu edit kembali.',
    DUPLICATE_OR_DEFAULT_PRICELIST_CONFLICT: 'Nama sudah digunakan, atau sudah ada default aktif untuk scope tersebut.',
    ACTIVE_COMPANY_REQUIRES_ONE_DEFAULT_GLOBAL_PRICELIST: 'Company aktif wajib memiliki tepat satu Harga Umum default. Pilih Pricelist lain sebagai default untuk memindahkannya.',
    ACTIVE_REGULAR_CUSTOMER_NOT_FOUND: 'Customer tidak aktif, merupakan Pelanggan Umum, atau bukan milik company aktif.',
    ACTIVE_SALES_PRODUCT_UOM_NOT_FOUND: 'Product atau UOM jual tidak aktif. Muat ulang dan pilih data aktif.',
    CUSTOMER_PRICELIST_TIER_NOT_ALLOWED: 'Harga khusus Customer tidak menggunakan quantity tier. Minimum quantity harus 1.',
    PRICELIST_STORE_REQUIRED: 'Pilih minimal satu toko atau aktifkan Semua toko.',
    ACTIVE_STORE_NOT_FOUND: 'Toko tidak aktif atau bukan milik company aktif.',
    INVALID_PRICELIST_RULE_VALUE: 'Nilai harga atau diskon pada salah satu rule tidak valid.',
    DUPLICATE_RULE_TIER: 'Product, UOM, dan minimum quantity yang sama tidak boleh diulang.',
    PRICELIST_MANAGER_REQUIRED: 'Role Anda tidak diizinkan mengubah Pricelist.',
    FORBIDDEN: 'Role Anda tidak diizinkan mengakses Pricelist.',
  }
  return messages[code ?? ''] ?? code ?? 'Operasi Pricelist gagal.'
}

export function PricelistMasterView({ session, companyId, canManage, notify }: {
  session: Session; companyId: string; canManage: boolean; notify: (message: string) => void
}) {
  const [pricelists, setPricelists] = useState<Pricelist[]>([])
  const [products, setProducts] = useState<Product[]>([])
  const [stores, setStores] = useState<StoreOption[]>([])
  const [query, setQuery] = useState('')
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [editor, setEditor] = useState<Pricelist | null | undefined>(undefined)
  useEscapeClose(() => setEditor(undefined))

  const fetchData = useCallback(async () => {
    const responses = await Promise.all([
      fetch('/api/master/pricelists?includeInactive=true', { headers: authHeaders(session) }),
      fetch('/api/master/products?includeInactive=true', { headers: authHeaders(session) }),
    ])
    const payloads = await Promise.all(responses.map((response) => response.json())) as [ApiList<Pricelist>, ApiList<Product>]
    const failed = responses.findIndex((response) => !response.ok)
    if (failed >= 0) throw new Error(friendlyError(payloads[failed].error))
    return payloads
  }, [session])

  const refresh = useCallback(async () => {
    setLoading(true); setError('')
    try {
      const payloads = await fetchData()
      setPricelists(payloads[0].data ?? []); setStores(payloads[0].stores ?? [])
      setProducts(payloads[1].data ?? [])
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Gagal memuat Pricelist.')
    } finally { setLoading(false) }
  }, [fetchData])

  useEffect(() => { let cancelled = false; fetchData().then((payloads) => { if (!cancelled) { setPricelists(payloads[0].data ?? []); setStores(payloads[0].stores ?? []); setProducts(payloads[1].data ?? []) } }).catch((caught) => { if (!cancelled) setError(caught instanceof Error ? caught.message : 'Gagal memuat Pricelist.') }).finally(() => { if (!cancelled) setLoading(false) }); return () => { cancelled = true } }, [companyId, fetchData])

  const storeById = useMemo(() => new Map(stores.map((item) => [item.id, item])), [stores])
  const normalized = query.trim().toLowerCase()
  const filtered = pricelists.filter((item) => !normalized || [item.name, item.scope].some((value) => value.toLowerCase().includes(normalized)))
  const usableProducts = products.filter((item) => item.is_active && item.product_uoms.some((row) => row.is_active && row.sales_allowed && row.uom?.is_active))

  return <>
    <div className="mb-7 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between"><div><p className="text-xs font-bold uppercase tracking-[.16em] text-emerald-600">Master Penjualan</p><h1 className="mt-2 text-2xl font-black tracking-tight text-slate-950 md:text-3xl">Pricelist</h1><p className="mt-2 text-sm text-slate-500">Atur Harga Umum, harga khusus Customer, cakupan toko, dan quantity tier per UOM jual. Belum mengubah harga checkout.</p></div><div className="flex gap-2"><button onClick={() => void refresh()} className="inline-flex items-center gap-2 rounded-xl border border-slate-200 bg-white px-4 py-3 text-sm font-bold text-slate-600"><RefreshCcw className={`h-4 w-4 ${loading ? 'animate-spin' : ''}`} /> Muat ulang</button>{canManage && <button onClick={() => setEditor(null)} className="inline-flex items-center gap-2 rounded-xl bg-emerald-500 px-4 py-3 text-sm font-bold text-white"><Plus className="h-4 w-4" /> Tambah Pricelist</button>}</div></div>
    <div className="mb-5 rounded-2xl border border-blue-100 bg-blue-50 p-4 text-sm leading-6 text-blue-800"><b>Cara mengisi harga:</b> masukkan harga akhir yang ingin dipakai. Contoh harga Product-UOM Rp5.000 dan harga Pricelist Rp4.000, cukup isi Rp4.000—bukan potongan Rp1.000. Potongan per UOM hanya tersedia untuk quantity tier Global. Pricelist khusus ditempelkan ke Customer dari menu Customer.</div>
    {error && <div className="mb-5 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-700">{error}</div>}
    <div className="rounded-2xl border border-slate-200 bg-white shadow-sm"><div className="flex items-center gap-3 border-b border-slate-100 p-4"><Search className="h-4 w-4 text-slate-400" /><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Cari nama atau jenis Pricelist..." className="w-full bg-transparent text-sm outline-none" /></div><div className="overflow-x-auto"><table className="w-full min-w-[1050px] text-left text-sm"><thead className="bg-slate-50 text-xs uppercase tracking-wider text-slate-500"><tr><th className="px-5 py-4">Pricelist</th><th className="px-5 py-4">Scope</th><th className="px-5 py-4">Berlaku di</th><th className="px-5 py-4">Rule aktif</th><th className="px-5 py-4">Prioritas</th><th className="px-5 py-4">Status</th>{canManage && <th className="px-5 py-4 text-right">Aksi</th>}</tr></thead><tbody className="divide-y divide-slate-100">{filtered.map((item) => {
        const assignedStores = item.store_assignments.map((row) => storeById.get(row.store_id)?.store_name).filter(Boolean)
        return <tr key={item.id}><td className="px-5 py-4"><p className="font-bold">{item.name}{item.is_default && <span className="ml-2 rounded-full bg-violet-50 px-2 py-1 text-[10px] text-violet-700">Default</span>}</p></td><td className="px-5 py-4"><p className="font-semibold">{item.scope === 'GLOBAL' ? 'Global' : 'Khusus Customer'}</p><p className="mt-1 text-xs text-slate-400">{item.scope === 'CUSTOMER' ? 'Dipilih dari menu Customer' : 'Semua Customer tanpa harga khusus'}</p></td><td className="px-5 py-4">{item.applies_all_stores ? 'Semua toko' : assignedStores.join(', ') || '-'}</td><td className="px-5 py-4 font-bold">{item.rules.length}</td><td className="px-5 py-4">{item.priority}</td><td className="px-5 py-4"><Status active={item.is_active} /></td>{canManage && <td className="px-5 py-4 text-right"><button onClick={() => setEditor(item)} className="rounded-lg border border-slate-200 p-2 text-slate-500 hover:text-emerald-600" aria-label={`Edit ${item.name}`}><Edit3 className="h-4 w-4" /></button></td>}</tr>
      })}{!loading && !filtered.length && <tr><td colSpan={canManage ? 7 : 6} className="p-10 text-center text-slate-400">Belum ada Pricelist.</td></tr>}</tbody></table>{loading && <div className="p-10 text-center text-sm text-slate-500">Memuat Pricelist...</div>}</div></div>
    {editor !== undefined && <PricelistEditor session={session} record={editor ?? undefined} products={usableProducts} stores={stores} close={() => setEditor(undefined)} complete={async () => { setEditor(undefined); await refresh(); notify('Pricelist berhasil disimpan.') }} />}
  </>
}

function PricelistEditor({ session, record, products, stores, close, complete }: { session: Session; record?: Pricelist; products: Product[]; stores: StoreOption[]; close: () => void; complete: () => Promise<void> }) {
  useEscapeClose(close)
  const productById = useMemo(() => new Map(products.map((item) => [item.id, item])), [products])
  const [form, setForm] = useState({
    name: record?.name ?? '', scope: record?.scope ?? 'GLOBAL' as 'GLOBAL' | 'CUSTOMER',
    priority: String(record?.priority ?? 0),
    isDefault: record?.is_default ?? false, appliesAllStores: record?.applies_all_stores ?? true,
    storeIds: record?.store_assignments.map((row) => row.store_id) ?? [], validFrom: dateInput(record?.valid_from ?? null),
    validUntil: dateInput(record?.valid_until ?? null), isActive: record?.is_active ?? true, notes: record?.notes ?? '',
  })
  const [rules, setRules] = useState<RuleForm[]>(() => record?.rules.map((rule) => ({
    productId: rule.product_id, productUomId: rule.product_uom_id, minQty: String(rule.min_qty), tierQtyBasis: rule.tier_qty_basis,
    pricingMethod: rule.pricing_method, value: String(rule.fixed_unit_price ?? rule.discount_amount_per_unit ?? rule.discount_percent ?? ''), isActive: rule.is_active,
  })) ?? [])
  const [saving, setSaving] = useState(false); const [error, setError] = useState('')

  function salesUoms(productId: string) { return productById.get(productId)?.product_uoms.filter((row) => row.is_active && row.sales_allowed && row.uom?.is_active) ?? [] }
  function addRule() { const product = products[0]; const uom = product ? salesUoms(product.id)[0] : undefined; if (!product || !uom) return; setRules((current) => [...current, { productId: product.id, productUomId: uom.id, minQty: '1', tierQtyBasis: 'SALES_UOM', pricingMethod: 'FIXED_PRICE', value: String(uom.sale_price ?? 0), isActive: true }]) }
  function updateRule(index: number, patch: Partial<RuleForm>) { setRules((current) => current.map((rule, ruleIndex) => ruleIndex === index ? { ...rule, ...patch } : rule)) }
  function fallbackForRule(rule: RuleForm) { return salesUoms(rule.productId).find((item) => item.id === rule.productUomId)?.sale_price ?? 0 }
  function changeScope(scope: 'GLOBAL' | 'CUSTOMER') { setForm((current) => ({ ...current, scope, isDefault: scope === 'GLOBAL' ? current.isDefault : false })); if (scope === 'CUSTOMER') setRules((current) => current.map((rule) => ({ ...rule, minQty: '1', pricingMethod: 'FIXED_PRICE', value: String(fallbackForRule(rule)) }))) }
  async function submit(event: React.FormEvent) {
    event.preventDefault(); setSaving(true); setError('')
    try {
      const body = { ...form, priority: Number(form.priority || 0), customerId: null, storeIds: form.appliesAllStores ? [] : form.storeIds, validFrom: form.validFrom || null, validUntil: form.validUntil || null, notes: form.notes || null, rules: rules.map((rule) => ({ productId: rule.productId, productUomId: rule.productUomId, minQty: form.scope === 'CUSTOMER' ? 1 : Number(rule.minQty), tierQtyBasis: rule.tierQtyBasis, pricingMethod: rule.pricingMethod, ...(rule.pricingMethod === 'FIXED_PRICE' ? { fixedUnitPrice: Number(rule.value) } : rule.pricingMethod === 'DISCOUNT_AMOUNT' ? { discountAmountPerUnit: Number(rule.value) } : { discountPercent: Number(rule.value) }), isActive: rule.isActive })), ...(record ? { masterVersion: record.master_version } : {}) }
      const response = await fetch(record ? `/api/master/pricelists/${record.id}` : '/api/master/pricelists', { method: record ? 'PATCH' : 'POST', headers: { 'Content-Type': 'application/json', ...authHeaders(session) }, body: JSON.stringify(body) })
      const payload = await response.json() as { error?: string }
      if (!response.ok) throw new Error(friendlyError(payload.error))
      await complete()
    } catch (caught) { setError(caught instanceof Error ? caught.message : 'Gagal menyimpan Pricelist.') }
    finally { setSaving(false) }
  }

  return <Modal title={record ? 'Edit Pricelist' : 'Tambah Pricelist'} description="Atur template harga dan toko tempat harga berlaku. Pricelist khusus ditempelkan ke satu atau banyak Customer dari menu Customer." close={close}><form onSubmit={submit} className="space-y-6">
    <div className="grid gap-4 sm:grid-cols-2"><Field label="Nama Pricelist"><input required value={form.name} onChange={(event) => setForm({ ...form, name: event.target.value })} className="input" placeholder="Contoh: Harga Grosir" /><span className="mt-1 block text-xs text-slate-400">Nama harus unik. Identitas internal dibuat otomatis.</span></Field><Field label="Jenis harga"><select value={form.scope} onChange={(event) => changeScope(event.target.value as 'GLOBAL' | 'CUSTOMER')} className="input"><option value="GLOBAL">Global — berlaku umum dan boleh quantity tier</option><option value="CUSTOMER">Khusus Customer — reusable untuk banyak Customer</option></select></Field><Field label="Prioritas"><input type="number" value={form.priority} onChange={(event) => setForm({ ...form, priority: event.target.value })} className="input" /><span className="mt-1 block text-xs text-slate-400">Angka lebih besar dipilih lebih dulu dalam scope yang sama.</span></Field><Field label="Periode berlaku (opsional)"><div className="grid grid-cols-2 gap-2"><input type="datetime-local" value={form.validFrom} onChange={(event) => setForm({ ...form, validFrom: event.target.value })} className="input" aria-label="Mulai berlaku" /><input type="datetime-local" value={form.validUntil} onChange={(event) => setForm({ ...form, validUntil: event.target.value })} className="input" aria-label="Berakhir" /></div></Field></div>
    <div className="rounded-2xl border border-slate-200 p-4"><Checkbox checked={form.appliesAllStores} onChange={(value) => setForm({ ...form, appliesAllStores: value, storeIds: value ? [] : form.storeIds })} label="Berlaku di semua toko" />{!form.appliesAllStores && <div className="mt-4 grid gap-2 sm:grid-cols-2">{stores.map((store) => <Checkbox key={store.id} checked={form.storeIds.includes(store.id)} onChange={(checked) => setForm({ ...form, storeIds: checked ? [...form.storeIds, store.id] : form.storeIds.filter((id) => id !== store.id) })} label={store.store_name} />)}</div>}</div>
    <div className="rounded-2xl border border-slate-200"><div className="flex items-start justify-between gap-4 border-b border-slate-100 p-4"><div><h3 className="font-black text-slate-900">Harga akhir per UOM jual</h3><p className="mt-1 text-xs leading-5 text-slate-500">Isi langsung harga akhir Pricelist. Product tanpa rule tetap memakai harga jual Product-UOM. UOM ditampilkan dengan nama, bukan ID atau kode teknis.</p></div><button type="button" disabled={!products.length} onClick={addRule} className="inline-flex shrink-0 items-center gap-2 rounded-xl border border-slate-200 px-3 py-2 text-xs font-bold text-emerald-700 disabled:opacity-50"><Plus className="h-4 w-4" /> Tambah harga</button></div><div className="space-y-4 p-4">{rules.map((rule, index) => {
      const uoms = salesUoms(rule.productId); const selectedUom = uoms.find((item) => item.id === rule.productUomId)
      const quantityTier = form.scope === 'GLOBAL' && Number(rule.minQty) > 1
      return <div key={`${index}-${rule.productUomId}`} className="rounded-2xl bg-slate-50 p-4"><div className="grid gap-4 md:grid-cols-2 xl:grid-cols-4"><Field label="Product"><select required value={rule.productId} onChange={(event) => { const productId = event.target.value; const uom = salesUoms(productId)[0]; updateRule(index, { productId, productUomId: uom?.id ?? '', value: rule.pricingMethod === 'FIXED_PRICE' ? String(uom?.sale_price ?? 0) : '0' }) }} className="input bg-white">{products.map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}</select></Field><Field label="UOM jual"><select required value={rule.productUomId} onChange={(event) => { const uom = uoms.find((item) => item.id === event.target.value); updateRule(index, { productUomId: event.target.value, value: rule.pricingMethod === 'FIXED_PRICE' ? String(uom?.sale_price ?? 0) : '0' }) }} className="input bg-white">{uoms.map((item) => <option key={item.id} value={item.id}>{item.uom?.name ?? 'UOM tanpa nama'}</option>)}</select><span className="mt-1 block text-xs text-slate-400">Harga normal: {rupiah(selectedUom?.sale_price ?? null)}</span></Field><Field label="Minimum pembelian"><input disabled={form.scope === 'CUSTOMER'} required min="1" step="any" type="number" value={form.scope === 'CUSTOMER' ? '1' : rule.minQty} onChange={(event) => { const minQty = event.target.value; updateRule(index, Number(minQty) <= 1 && rule.pricingMethod !== 'FIXED_PRICE' ? { minQty, pricingMethod: 'FIXED_PRICE', value: String(selectedUom?.sale_price ?? 0) } : { minQty }) }} className="input bg-white disabled:bg-slate-100" /><span className="mt-1 block text-xs text-slate-400">Isi 1 untuk harga biasa; lebih dari 1 untuk harga bertingkat.</span></Field><Field label="Basis quantity"><select value={rule.tierQtyBasis} onChange={(event) => updateRule(index, { tierQtyBasis: event.target.value as RuleForm['tierQtyBasis'] })} className="input bg-white"><option value="SALES_UOM">Jumlah UOM yang dibeli</option><option value="BASE_UOM_EQUIVALENT">Ekuivalen Base UOM</option></select></Field>{quantityTier ? <Field label="Cara menentukan harga tier"><select value={rule.pricingMethod} onChange={(event) => { const pricingMethod = event.target.value as RuleForm['pricingMethod']; updateRule(index, { pricingMethod, value: pricingMethod === 'FIXED_PRICE' ? String(selectedUom?.sale_price ?? 0) : '0' }) }} className="input bg-white"><option value="FIXED_PRICE">Isi harga akhir per UOM</option><option value="DISCOUNT_AMOUNT">Isi potongan per UOM</option>{rule.pricingMethod === 'DISCOUNT_PERCENT' && <option value="DISCOUNT_PERCENT">Diskon persen (data existing)</option>}</select></Field> : <div><p className="mb-2 text-sm font-bold text-slate-700">Cara menentukan harga</p><div className="rounded-xl border border-emerald-100 bg-emerald-50 px-4 py-3 text-sm font-bold text-emerald-800">Harga akhir langsung</div></div>}<Field label={rule.pricingMethod === 'FIXED_PRICE' ? 'Harga akhir Pricelist' : rule.pricingMethod === 'DISCOUNT_AMOUNT' ? 'Potongan per UOM' : 'Diskon (%)'}><input required min={0} max={rule.pricingMethod === 'DISCOUNT_PERCENT' ? 100 : undefined} step="any" type="number" value={rule.value} onChange={(event) => updateRule(index, { value: event.target.value })} className="input bg-white" /><span className="mt-1 block text-xs text-slate-400">{rule.pricingMethod === 'FIXED_PRICE' ? `Contoh: dari ${rupiah(selectedUom?.sale_price ?? null)} menjadi Rp4.000, isi 4000.` : 'Nilai ini dikurangi untuk setiap UOM pada tier tersebut.'}</span></Field><div className="flex items-end"><Checkbox checked={rule.isActive} onChange={(value) => updateRule(index, { isActive: value })} label="Rule aktif" /></div><div className="flex items-end justify-end"><button type="button" onClick={() => setRules((current) => current.filter((_, ruleIndex) => ruleIndex !== index))} className="inline-flex items-center gap-2 rounded-xl px-3 py-3 text-sm font-bold text-rose-600"><Trash2 className="h-4 w-4" /> Hapus dari form</button></div></div></div>
    })}{!rules.length && <div className="py-6 text-center text-sm text-slate-400">Belum ada rule. Pricelist ini akan memakai harga fallback Product-UOM.</div>}</div></div>
    <Field label="Catatan (opsional)"><textarea rows={2} value={form.notes} onChange={(event) => setForm({ ...form, notes: event.target.value })} className="input resize-none" /></Field><div className="grid gap-3 sm:grid-cols-2">{form.scope === 'GLOBAL' && <Checkbox checked={form.isDefault} onChange={(value) => setForm({ ...form, isDefault: value })} label="Default Global" />}<Checkbox checked={form.isActive} onChange={(value) => setForm({ ...form, isActive: value })} label="Pricelist aktif" /></div>{error && <FormError message={error} />}<Actions saving={saving} close={close} />
  </form></Modal>
}

function Status({ active }: { active: boolean }) { return <span className={`rounded-full px-2.5 py-1 text-[11px] font-bold ${active ? 'bg-emerald-50 text-emerald-700' : 'bg-slate-100 text-slate-500'}`}>{active ? 'Aktif' : 'Nonaktif'}</span> }
function Field({ label, children }: { label: string; children: React.ReactNode }) { return <label className="block"><span className="mb-2 block text-sm font-bold text-slate-700">{label}</span>{children}</label> }
function Checkbox({ checked, onChange, label }: { checked: boolean; onChange: (value: boolean) => void; label: string }) { return <label className="flex items-center gap-3 rounded-xl border border-slate-200 bg-white p-3 text-sm font-semibold"><input type="checkbox" checked={checked} onChange={(event) => onChange(event.target.checked)} className="h-4 w-4 accent-emerald-500" />{label}</label> }
function FormError({ message }: { message: string }) { return <div className="rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-700">{message}</div> }
function Actions({ saving, close }: { saving: boolean; close: () => void }) { return <div className="flex justify-end gap-3 border-t border-slate-100 pt-5"><button type="button" onClick={close} className="rounded-xl border border-slate-200 px-5 py-3 text-sm font-bold text-slate-600">Batal</button><button disabled={saving} type="submit" className="inline-flex items-center gap-2 rounded-xl bg-emerald-500 px-5 py-3 text-sm font-bold text-white disabled:opacity-60">{saving && <Loader2 className="h-4 w-4 animate-spin" />}Simpan Pricelist</button></div> }
function Modal({ title, description, close, children }: { title: string; description: string; close: () => void; children: React.ReactNode }) { return <div className="fixed inset-0 z-[70] overflow-y-auto bg-slate-950/50 p-4 backdrop-blur-sm"><div className="mx-auto my-6 max-w-6xl rounded-3xl bg-white shadow-2xl"><div className="flex items-start justify-between border-b border-slate-100 p-6"><div><div className="mb-3 inline-flex items-center gap-2 rounded-full bg-emerald-50 px-3 py-1 text-xs font-bold text-emerald-700"><Tags className="h-3.5 w-3.5" /> Master harga</div><h2 className="text-xl font-black text-slate-950">{title}</h2><p className="mt-2 max-w-3xl text-sm leading-6 text-slate-500">{description}</p></div><button onClick={close} className="rounded-xl border border-slate-200 p-2 text-slate-500" aria-label="Tutup"><X className="h-5 w-5" /></button></div><div className="p-6">{children}</div></div></div> }
