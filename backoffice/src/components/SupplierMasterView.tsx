'use client'

import { useCallback, useEffect, useMemo, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import { useEscapeClose } from '@/lib/use-escape-close'
import { Edit3, Loader2, PackageSearch, Plus, RefreshCcw, Search, Truck, X } from 'lucide-react'

type Supplier = {
  id: string
  supplier_code: string
  supplier_name: string
  contact_name: string | null
  phone: string | null
  address: string | null
  npwp: string | null
  payment_term: string | null
  bank_name: string | null
  bank_account_number: string | null
  bank_account_holder: string | null
  is_active: boolean
  master_version: number
}

type ProductUom = {
  uom_id: string
  factor_to_base: number | string
  purchase_allowed: boolean
  is_active: boolean
  uom: { id: string; code: string; name: string; is_active: boolean }
}

type Product = {
  id: string
  sku: string
  name: string
  is_active: boolean
  product_uoms: ProductUom[]
}

type ProductSupplier = {
  id: string
  product_id: string
  supplier_id: string
  purchase_uom_id: string
  supplier_product_code: string | null
  reference_purchase_price: number | string | null
  last_purchase_price: number | string | null
  is_preferred_supplier: boolean
  is_active: boolean
  master_version: number
}

type ApiList<T> = { data?: T[]; error?: string }
type Editor = { kind: 'supplier'; record?: Supplier } | { kind: 'relation'; record?: ProductSupplier }

function authHeaders(session: Session) {
  return { Authorization: `Bearer ${session.access_token}` }
}

function rupiah(value: number | string | null) {
  if (value === null || value === '') return '-'
  return new Intl.NumberFormat('id-ID', {
    style: 'currency',
    currency: 'IDR',
    maximumFractionDigits: 0,
  }).format(Number(value))
}

function friendlyError(code?: string) {
  const messages: Record<string, string> = {
    MASTER_VERSION_CONFLICT: 'Data sudah berubah di tab lain. Muat ulang lalu edit kembali.',
    DUPLICATE_SUPPLIER: 'Nama Supplier sudah digunakan pada company aktif.',
    PRODUCT_SUPPLIER_ALREADY_EXISTS: 'Supplier tersebut sudah terhubung ke Product ini.',
    PREFERRED_SUPPLIER_ALREADY_EXISTS: 'Product ini sudah memiliki Supplier utama. Nonaktifkan status utama pada relasi lama terlebih dahulu.',
    ACTIVE_PRODUCT_NOT_FOUND: 'Product tidak aktif atau bukan milik company aktif.',
    ACTIVE_SUPPLIER_NOT_FOUND: 'Supplier tidak aktif atau bukan milik company aktif.',
    ACTIVE_PURCHASE_PRODUCT_UOM_NOT_FOUND: 'UOM pembelian tidak aktif atau belum diizinkan untuk pembelian pada Product.',
    PREFERRED_SUPPLIER_MUST_BE_ACTIVE: 'Supplier utama harus berstatus aktif.',
    SUPPLIER_MANAGER_REQUIRED: 'Role Anda tidak diizinkan melakukan perubahan ini.',
    FORBIDDEN: 'Role Anda tidak diizinkan mengakses Supplier.',
  }
  return messages[code ?? ''] ?? code ?? 'Operasi Supplier gagal.'
}

export function SupplierMasterView({
  session,
  companyId,
  canManageSupplier,
  canManageRelation,
  notify,
}: {
  session: Session
  companyId: string
  canManageSupplier: boolean
  canManageRelation: boolean
  notify: (message: string) => void
}) {
  const [tab, setTab] = useState<'supplier' | 'relation'>('supplier')
  const [suppliers, setSuppliers] = useState<Supplier[]>([])
  const [products, setProducts] = useState<Product[]>([])
  const [relations, setRelations] = useState<ProductSupplier[]>([])
  const [query, setQuery] = useState('')
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [editor, setEditor] = useState<Editor | null>(null)

  const fetchData = useCallback(async () => {
    const paths = [
      '/api/master/suppliers?includeInactive=true',
      '/api/master/product-references?includeInactive=true',
      '/api/master/product-suppliers?includeInactive=true',
    ]
    const responses = await Promise.all(paths.map((path) => fetch(path, { headers: authHeaders(session) })))
    const payloads = (await Promise.all(responses.map((response) => response.json()))) as [
      ApiList<Supplier>, ApiList<Product>, ApiList<ProductSupplier>,
    ]
    const failed = responses.findIndex((response) => !response.ok)
    if (failed >= 0) throw new Error(friendlyError(payloads[failed].error))
    return payloads
  }, [session])

  const refresh = useCallback(async () => {
    setLoading(true)
    setError('')
    try {
      const payloads = await fetchData()
      setSuppliers(payloads[0].data ?? [])
      setProducts(payloads[1].data ?? [])
      setRelations(payloads[2].data ?? [])
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Gagal memuat Supplier.')
    } finally {
      setLoading(false)
    }
  }, [fetchData])

  useEffect(() => {
    let cancelled = false
    fetchData()
      .then((payloads) => {
        if (cancelled) return
        setSuppliers(payloads[0].data ?? [])
        setProducts(payloads[1].data ?? [])
        setRelations(payloads[2].data ?? [])
      })
      .catch((caught) => {
        if (!cancelled) {
          setError(caught instanceof Error ? caught.message : 'Gagal memuat Supplier.')
        }
      })
      .finally(() => {
        if (!cancelled) setLoading(false)
      })
    return () => {
      cancelled = true
    }
  }, [companyId, fetchData])

  const supplierById = useMemo(() => new Map(suppliers.map((item) => [item.id, item])), [suppliers])
  const productById = useMemo(() => new Map(products.map((item) => [item.id, item])), [products])
  const normalized = query.trim().toLowerCase()
  const filteredSuppliers = suppliers.filter((item) =>
    !normalized || [item.supplier_name, item.contact_name ?? ''].some((value) => value.toLowerCase().includes(normalized)),
  )
  const filteredRelations = relations.filter((item) => {
    const supplier = supplierById.get(item.supplier_id)
    const product = productById.get(item.product_id)
    return !normalized || [supplier?.supplier_name ?? '', product?.name ?? '', product?.sku ?? '', item.supplier_product_code ?? ''].some((value) => value.toLowerCase().includes(normalized))
  })
  const canCreateRelation =
    suppliers.some((item) => item.is_active) &&
    products.some((item) => item.is_active && item.product_uoms.some((row) => row.is_active && row.purchase_allowed))

  return (
    <>
      <div className="mb-7 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <p className="text-xs font-bold uppercase tracking-[.16em] text-emerald-600">Master Pembelian</p>
          <h1 className="mt-2 text-2xl font-black tracking-tight text-slate-950 md:text-3xl">Supplier & Product Supplier</h1>
          <p className="mt-2 text-sm text-slate-500">Kelola identitas vendor dan satuan pembelian yang mereka pasok. Belum membuat transaksi pembelian atau stok.</p>
        </div>
        <div className="flex gap-2">
          <button onClick={() => void refresh()} className="inline-flex items-center gap-2 rounded-xl border border-slate-200 bg-white px-4 py-3 text-sm font-bold text-slate-600">
            <RefreshCcw className={`h-4 w-4 ${loading ? 'animate-spin' : ''}`} /> Muat ulang
          </button>
          {((tab === 'supplier' && canManageSupplier) || (tab === 'relation' && canManageRelation)) && (
            <button
              disabled={tab === 'relation' && !canCreateRelation}
              onClick={() => setEditor({ kind: tab })}
              className="inline-flex items-center gap-2 rounded-xl bg-emerald-500 px-4 py-3 text-sm font-bold text-white disabled:cursor-not-allowed disabled:opacity-50"
            >
              <Plus className="h-4 w-4" /> {tab === 'supplier' ? 'Tambah Supplier' : 'Hubungkan Product'}
            </button>
          )}
        </div>
      </div>

      <div className="mb-5 inline-flex rounded-xl border border-slate-200 bg-white p-1">
        <button onClick={() => setTab('supplier')} className={`inline-flex items-center gap-2 rounded-lg px-4 py-2.5 text-sm font-bold ${tab === 'supplier' ? 'bg-slate-950 text-white' : 'text-slate-500'}`}><Truck className="h-4 w-4" /> Daftar Supplier</button>
        <button onClick={() => setTab('relation')} className={`inline-flex items-center gap-2 rounded-lg px-4 py-2.5 text-sm font-bold ${tab === 'relation' ? 'bg-slate-950 text-white' : 'text-slate-500'}`}><PackageSearch className="h-4 w-4" /> Supplier per Product</button>
      </div>

      {tab === 'relation' && !canCreateRelation && canManageRelation && (
        <div className="mb-5 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-800">Buat Supplier aktif dan pastikan Product memiliki minimal satu UOM aktif yang dicentang untuk pembelian.</div>
      )}
      {error && <div className="mb-5 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-700">{error}</div>}

      <div className="rounded-2xl border border-slate-200 bg-white shadow-sm">
        <div className="flex items-center gap-3 border-b border-slate-100 p-4"><Search className="h-4 w-4 text-slate-400" /><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder={tab === 'supplier' ? 'Cari kode, nama, atau kontak Supplier...' : 'Cari Product, SKU, Supplier, atau kode vendor...'} className="w-full bg-transparent text-sm outline-none" /></div>
        <div className="overflow-x-auto">
          {tab === 'supplier' ? (
            <table className="w-full min-w-[850px] text-left text-sm">
              <thead className="bg-slate-50 text-xs uppercase tracking-wider text-slate-500"><tr><th className="px-5 py-4">Supplier</th><th className="px-5 py-4">Kontak</th><th className="px-5 py-4">Termin</th><th className="px-5 py-4">Rekening referensi</th><th className="px-5 py-4">Status</th>{canManageSupplier && <th className="px-5 py-4 text-right">Aksi</th>}</tr></thead>
              <tbody className="divide-y divide-slate-100">
                {filteredSuppliers.map((supplier) => <tr key={supplier.id}><td className="px-5 py-4 font-bold">{supplier.supplier_name}</td><td className="px-5 py-4"><p className="text-slate-700">{supplier.contact_name ?? '-'}</p><p className="mt-1 text-xs text-slate-400">{supplier.phone ?? '-'}</p></td><td className="px-5 py-4 text-slate-600">{supplier.payment_term ?? '-'}</td><td className="px-5 py-4"><p className="text-slate-700">{supplier.bank_name ?? '-'}</p><p className="mt-1 text-xs text-slate-400">{supplier.bank_account_number ?? '-'}</p></td><td className="px-5 py-4"><Status active={supplier.is_active} /></td>{canManageSupplier && <td className="px-5 py-4 text-right"><EditButton label="Edit Supplier" onClick={() => setEditor({ kind: 'supplier', record: supplier })} /></td>}</tr>)}
                {!loading && !filteredSuppliers.length && <tr><td colSpan={canManageSupplier ? 6 : 5} className="p-10 text-center text-sm text-slate-400">Belum ada Supplier.</td></tr>}
              </tbody>
            </table>
          ) : (
            <table className="w-full min-w-[950px] text-left text-sm">
              <thead className="bg-slate-50 text-xs uppercase tracking-wider text-slate-500"><tr><th className="px-5 py-4">Product</th><th className="px-5 py-4">Supplier</th><th className="px-5 py-4">UOM beli</th><th className="px-5 py-4">Harga referensi</th><th className="px-5 py-4">Harga beli terakhir</th><th className="px-5 py-4">Prioritas</th><th className="px-5 py-4">Status</th>{canManageRelation && <th className="px-5 py-4 text-right">Aksi</th>}</tr></thead>
              <tbody className="divide-y divide-slate-100">
                {filteredRelations.map((relation) => {
                  const supplier = supplierById.get(relation.supplier_id)
                  const product = productById.get(relation.product_id)
                  const uom = product?.product_uoms.find((row) => row.uom_id === relation.purchase_uom_id)?.uom
                  return <tr key={relation.id}><td className="px-5 py-4"><p className="font-bold">{product?.name ?? '-'}</p><p className="mt-1 text-xs font-semibold text-slate-400">{product?.sku ?? '-'}</p></td><td className="px-5 py-4"><p className="font-semibold">{supplier?.supplier_name ?? '-'}</p><p className="mt-1 text-xs text-slate-400">{relation.supplier_product_code ?? 'Tanpa kode vendor'}</p></td><td className="px-5 py-4 font-bold">{uom?.name ?? '-'}</td><td className="px-5 py-4 text-slate-600">{rupiah(relation.reference_purchase_price)}</td><td className="px-5 py-4 text-slate-600">{rupiah(relation.last_purchase_price)}</td><td className="px-5 py-4">{relation.is_preferred_supplier ? <span className="rounded-full bg-blue-50 px-2.5 py-1 text-[11px] font-bold text-blue-700">Supplier utama</span> : '-'}</td><td className="px-5 py-4"><Status active={relation.is_active} /></td>{canManageRelation && <td className="px-5 py-4 text-right"><EditButton label="Edit relasi Supplier" onClick={() => setEditor({ kind: 'relation', record: relation })} /></td>}</tr>
                })}
                {!loading && !filteredRelations.length && <tr><td colSpan={canManageRelation ? 8 : 7} className="p-10 text-center text-sm text-slate-400">Belum ada Supplier yang dihubungkan ke Product.</td></tr>}
              </tbody>
            </table>
          )}
          {loading && <div className="p-10 text-center text-sm text-slate-500">Memuat data Supplier...</div>}
        </div>
      </div>

      {editor?.kind === 'supplier' && <SupplierEditor session={session} record={editor.record} close={() => setEditor(null)} complete={async () => { setEditor(null); await refresh(); notify('Supplier berhasil disimpan.') }} />}
      {editor?.kind === 'relation' && <RelationEditor session={session} record={editor.record} suppliers={suppliers} products={products} close={() => setEditor(null)} complete={async () => { setEditor(null); await refresh(); notify('Relasi Supplier dan Product berhasil disimpan.') }} />}
    </>
  )
}

function SupplierEditor({ session, record, close, complete }: { session: Session; record?: Supplier; close: () => void; complete: () => Promise<void> }) {
  useEscapeClose(close)
  const [form, setForm] = useState({ supplierName: record?.supplier_name ?? '', contactName: record?.contact_name ?? '', phone: record?.phone ?? '', address: record?.address ?? '', npwp: record?.npwp ?? '', paymentTerm: record?.payment_term ?? '', bankName: record?.bank_name ?? '', bankAccountNumber: record?.bank_account_number ?? '', bankAccountHolder: record?.bank_account_holder ?? '', isActive: record?.is_active ?? true })
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')
  async function submit(event: React.FormEvent) {
    event.preventDefault(); setSaving(true); setError('')
    try {
      const response = await fetch(record ? `/api/master/suppliers/${record.id}` : '/api/master/suppliers', { method: record ? 'PATCH' : 'POST', headers: { 'Content-Type': 'application/json', ...authHeaders(session) }, body: JSON.stringify({ ...form, ...(record ? { masterVersion: record.master_version } : {}) }) })
      const payload = (await response.json()) as { error?: string }
      if (!response.ok) throw new Error(friendlyError(payload.error))
      await complete()
    } catch (caught) { setError(caught instanceof Error ? caught.message : 'Gagal menyimpan Supplier.') } finally { setSaving(false) }
  }
  return <Modal title={record ? 'Edit Supplier' : 'Tambah Supplier'} description="Nama Supplier harus unik; identitas internal dibuat otomatis. Data rekening bersifat referensi master." close={close}><form onSubmit={submit} className="space-y-5"><div className="grid gap-4 sm:grid-cols-2"><Field label="Nama Supplier"><input required maxLength={200} value={form.supplierName} onChange={(e) => setForm({ ...form, supplierName: e.target.value })} className="input" /></Field><Field label="Nama kontak (opsional)"><input value={form.contactName} onChange={(e) => setForm({ ...form, contactName: e.target.value })} className="input" /></Field><Field label="Telepon (opsional)"><input value={form.phone} onChange={(e) => setForm({ ...form, phone: e.target.value })} className="input" /></Field><Field label="NPWP (opsional)"><input value={form.npwp} onChange={(e) => setForm({ ...form, npwp: e.target.value })} className="input" /></Field><Field label="Termin pembayaran (opsional)"><input placeholder="Contoh: NET 30" value={form.paymentTerm} onChange={(e) => setForm({ ...form, paymentTerm: e.target.value })} className="input" /></Field></div><Field label="Alamat (opsional)"><textarea rows={3} value={form.address} onChange={(e) => setForm({ ...form, address: e.target.value })} className="input resize-none" /></Field><div className="rounded-2xl bg-slate-50 p-4"><p className="mb-4 text-sm font-bold">Rekening referensi</p><div className="grid gap-4 sm:grid-cols-3"><Field label="Nama bank"><input value={form.bankName} onChange={(e) => setForm({ ...form, bankName: e.target.value })} className="input bg-white" /></Field><Field label="Nomor rekening"><input value={form.bankAccountNumber} onChange={(e) => setForm({ ...form, bankAccountNumber: e.target.value })} className="input bg-white" /></Field><Field label="Nama pemilik"><input value={form.bankAccountHolder} onChange={(e) => setForm({ ...form, bankAccountHolder: e.target.value })} className="input bg-white" /></Field></div></div><Checkbox checked={form.isActive} onChange={(value) => setForm({ ...form, isActive: value })} label="Supplier aktif dan dapat dipilih" />{error && <FormError message={error} />}<Actions saving={saving} close={close} label="Simpan Supplier" /></form></Modal>
}

function RelationEditor({ session, record, suppliers, products, close, complete }: { session: Session; record?: ProductSupplier; suppliers: Supplier[]; products: Product[]; close: () => void; complete: () => Promise<void> }) {
  useEscapeClose(close)
  const initialProduct = record?.product_id ?? products.find((item) => item.is_active && item.product_uoms.some((row) => row.is_active && row.purchase_allowed))?.id ?? ''
  const [form, setForm] = useState({ productId: initialProduct, supplierId: record?.supplier_id ?? suppliers.find((item) => item.is_active)?.id ?? '', purchaseUomId: record?.purchase_uom_id ?? '', supplierProductCode: record?.supplier_product_code ?? '', referencePurchasePrice: record?.reference_purchase_price === null ? '' : String(record?.reference_purchase_price ?? ''), isPreferredSupplier: record?.is_preferred_supplier ?? false, isActive: record?.is_active ?? true })
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')
  const selectedProduct = products.find((item) => item.id === form.productId)
  const purchaseUoms = (selectedProduct?.product_uoms ?? []).filter((row) => (row.is_active && row.purchase_allowed) || row.uom_id === record?.purchase_uom_id).sort((a, b) => Number(b.factor_to_base) - Number(a.factor_to_base))
  const selectedPurchaseUom = form.purchaseUomId || purchaseUoms[0]?.uom_id || ''
  async function submit(event: React.FormEvent) {
    event.preventDefault(); setSaving(true); setError('')
    try {
      const response = await fetch(record ? `/api/master/product-suppliers/${record.id}` : '/api/master/product-suppliers', { method: record ? 'PATCH' : 'POST', headers: { 'Content-Type': 'application/json', ...authHeaders(session) }, body: JSON.stringify({ ...form, purchaseUomId: selectedPurchaseUom, referencePurchasePrice: form.referencePurchasePrice === '' ? null : Number(form.referencePurchasePrice), ...(record ? { masterVersion: record.master_version } : {}) }) })
      const payload = (await response.json()) as { error?: string }
      if (!response.ok) throw new Error(friendlyError(payload.error))
      await complete()
    } catch (caught) { setError(caught instanceof Error ? caught.message : 'Gagal menyimpan relasi Supplier.') } finally { setSaving(false) }
  }
  return <Modal title={record ? 'Edit Supplier Product' : 'Hubungkan Supplier ke Product'} description="Pilih satuan yang benar-benar digunakan saat membeli dari Supplier. UOM terbesar ditampilkan lebih dulu." close={close}><form onSubmit={submit} className="space-y-5"><Field label="Product"><select required value={form.productId} onChange={(e) => setForm({ ...form, productId: e.target.value, purchaseUomId: '' })} className="input"><option value="">Pilih Product</option>{products.filter((item) => item.is_active || item.id === record?.product_id).map((item) => <option key={item.id} value={item.id}>{item.sku} · {item.name}</option>)}</select></Field><div className="grid gap-4 sm:grid-cols-2"><Field label="Supplier"><select required value={form.supplierId} onChange={(e) => setForm({ ...form, supplierId: e.target.value })} className="input"><option value="">Pilih Supplier</option>{suppliers.filter((item) => item.is_active || item.id === record?.supplier_id).map((item) => <option key={item.id} value={item.id}>{item.supplier_name}</option>)}</select></Field><Field label="Satuan pembelian"><select required value={selectedPurchaseUom} onChange={(e) => setForm({ ...form, purchaseUomId: e.target.value })} className="input"><option value="">Pilih UOM beli</option>{purchaseUoms.map((row) => <option key={row.uom_id} value={row.uom_id}>{row.uom.name} · 1 {row.uom.name} = {Number(row.factor_to_base).toLocaleString('id-ID')} satuan dasar</option>)}</select></Field></div><div className="grid gap-4 sm:grid-cols-2"><Field label="Kode Product dari Supplier (opsional)"><input value={form.supplierProductCode} onChange={(e) => setForm({ ...form, supplierProductCode: e.target.value })} className="input" /></Field><Field label="Harga beli referensi per UOM (opsional)"><input min={0} step="any" type="number" value={form.referencePurchasePrice} onChange={(e) => setForm({ ...form, referencePurchasePrice: e.target.value })} className="input" /></Field></div><div className="rounded-2xl border border-blue-100 bg-blue-50 p-4 text-sm leading-6 text-blue-800">Harga referensi membantu input pembelian nanti. Harga beli terakhir hanya akan diisi otomatis dari dokumen pembelian yang tervalidasi, jadi tidak dapat diedit di sini.</div><div className="grid gap-3 sm:grid-cols-2"><Checkbox checked={form.isPreferredSupplier} onChange={(value) => setForm({ ...form, isPreferredSupplier: value, isActive: value ? true : form.isActive })} label="Jadikan Supplier utama" /><Checkbox checked={form.isActive} onChange={(value) => setForm({ ...form, isActive: value, isPreferredSupplier: value ? form.isPreferredSupplier : false })} label="Relasi aktif" /></div>{error && <FormError message={error} />}<Actions saving={saving} close={close} label="Simpan Relasi" /></form></Modal>
}

function Status({ active }: { active: boolean }) { return <span className={`rounded-full px-2.5 py-1 text-[11px] font-bold ${active ? 'bg-emerald-50 text-emerald-700' : 'bg-slate-100 text-slate-500'}`}>{active ? 'Aktif' : 'Nonaktif'}</span> }
function EditButton({ label, onClick }: { label: string; onClick: () => void }) { return <button onClick={onClick} className="rounded-lg border border-slate-200 p-2 text-slate-500 hover:text-emerald-600" aria-label={label}><Edit3 className="h-4 w-4" /></button> }
function Field({ label, children }: { label: string; children: React.ReactNode }) { return <label className="block"><span className="mb-2 block text-sm font-bold text-slate-700">{label}</span>{children}</label> }
function Checkbox({ checked, onChange, label }: { checked: boolean; onChange: (value: boolean) => void; label: string }) { return <label className="flex items-center gap-3 rounded-xl border border-slate-200 p-4 text-sm font-semibold"><input type="checkbox" checked={checked} onChange={(e) => onChange(e.target.checked)} className="h-4 w-4 accent-emerald-500" />{label}</label> }
function FormError({ message }: { message: string }) { return <div className="rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-700">{message}</div> }
function Actions({ saving, close, label }: { saving: boolean; close: () => void; label: string }) { return <div className="flex justify-end gap-3 border-t border-slate-100 pt-5"><button type="button" onClick={close} className="rounded-xl border border-slate-200 px-5 py-3 text-sm font-bold text-slate-600">Batal</button><button disabled={saving} type="submit" className="inline-flex items-center gap-2 rounded-xl bg-emerald-500 px-5 py-3 text-sm font-bold text-white disabled:opacity-60">{saving && <Loader2 className="h-4 w-4 animate-spin" />}{label}</button></div> }
function Modal({ title, description, close, children }: { title: string; description: string; close: () => void; children: React.ReactNode }) { return <div className="fixed inset-0 z-[70] overflow-y-auto bg-slate-950/50 p-4 backdrop-blur-sm"><div className="mx-auto my-6 max-w-4xl rounded-3xl bg-white shadow-2xl"><div className="flex items-start justify-between border-b border-slate-100 p-6"><div><h2 className="text-xl font-black text-slate-950">{title}</h2><p className="mt-2 max-w-2xl text-sm leading-6 text-slate-500">{description}</p></div><button onClick={close} className="rounded-xl border border-slate-200 p-2 text-slate-500" aria-label="Tutup"><X className="h-5 w-5" /></button></div><div className="p-6">{children}</div></div></div> }
