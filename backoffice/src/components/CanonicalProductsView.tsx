'use client'

import { useCallback, useEffect, useMemo, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import { useEscapeClose } from '@/lib/use-escape-close'
import { Edit3, Loader2, PackagePlus, Plus, RefreshCcw, Search, Trash2, X } from 'lucide-react'

type Category = {
  id: string
  category_code: string
  category_name: string
  is_active: boolean
  default_sales_tax_rule_id: string | null
  default_purchase_tax_rule_id: string | null
}

type TaxRuleOption = {
  id: string
  name: string
  scope: 'SALES' | 'PURCHASE'
  ratePercent: number | string
}

type TaxOptions = {
  data?: TaxRuleOption[]
  entitlements?: { salesEnabled: boolean; purchaseEnabled: boolean }
  error?: string
}

type UomMaster = {
  id: string
  code: string
  name: string
  uom_type: string
  allow_decimal: boolean
  decimal_precision: number
  is_active: boolean
}

type ProductUom = {
  id: string
  uom_id: string
  factor_to_base: number | string
  purchase_allowed: boolean
  sales_allowed: boolean
  purchase_price: number | string | null
  sale_price: number | string | null
  barcode: string | null
  is_active: boolean
  conversion_version: number
  master_version: number
  uom: UomMaster
}

type ProductRow = {
  id: string
  sku: string
  name: string
  category_id: string
  uom_id: string
  weight_reference_uom_id: string
  weight_per_uom_kg: number | string
  image_url: string | null
  is_bundle: boolean
  is_active: boolean
  master_version: number
  sales_tax_rule_id: string | null
  purchase_tax_rule_id: string | null
  category: Category
  product_uoms: ProductUom[]
}

type UomDraft = {
  uomId: string
  factorToBase: number
  purchaseAllowed: boolean
  salesAllowed: boolean
  purchasePrice: number
  salePrice: number
  barcode: string
  isActive: boolean
}

type ProductDraft = {
  sku: string
  name: string
  categoryId: string
  baseUomId: string
  weightReferenceUomId: string
  weightPerReferenceUomKg: number
  imageUrl: string
  isActive: boolean
  salesTaxRuleId: string | null
  purchaseTaxRuleId: string | null
  uoms: UomDraft[]
}

type ApiList<T> = { data?: T[]; error?: string }

type StockBalance = {
  product_id: string
  warehouse_id: string
  stock_qty: number | string
}

type StockWarehouse = {
  id: string
  name: string
  warehouse_type: string | null
  location: string | null
  is_active: boolean
}

type StockOverview = {
  balances?: StockBalance[]
  warehouses?: StockWarehouse[]
  error?: string
}

function authHeaders(session: Session) {
  return { Authorization: `Bearer ${session.access_token}` }
}

function friendlyError(code?: string) {
  const messages: Record<string, string> = {
    MASTER_VERSION_CONFLICT: 'Produk sudah berubah di tab lain. Muat ulang sebelum mengedit.',
    DUPLICATE_PRODUCT_OR_BARCODE: 'SKU, nama, atau barcode sudah digunakan.',
    ACTIVE_PRODUCT_CATEGORY_NOT_FOUND: 'Kategori tidak aktif atau bukan milik company aktif.',
    ACTIVE_PRODUCT_UOM_NOT_FOUND: 'Salah satu UOM tidak aktif atau bukan milik company aktif.',
    EXACTLY_ONE_BASE_UOM_REQUIRED: 'Pilih tepat satu base UOM.',
    WEIGHT_REFERENCE_MUST_BE_LARGEST_UOM: 'UOM acuan berat harus memiliki faktor terbesar.',
    ACTIVE_SALES_UOM_REQUIRED: 'Minimal satu UOM aktif harus dapat dijual.',
    ACTIVE_PURCHASE_UOM_REQUIRED: 'Minimal satu UOM aktif harus dapat dibeli.',
    PRODUCT_UOM_FACTOR_BELOW_BASE: 'Faktor UOM tidak boleh lebih kecil dari base.',
    NON_BASE_UOM_FACTOR_MUST_EXCEED_ONE: 'UOM selain base harus memiliki faktor lebih dari 1.',
    POSITIVE_REFERENCE_WEIGHT_REQUIRED: 'Berat UOM acuan wajib lebih dari 0 kg.',
    CATALOG_MANAGER_REQUIRED: 'Role Anda tidak diizinkan mengubah Product.',
    TAX_SALES_FEATURE_DISABLED: 'Modul Pajak Penjualan belum diaktifkan.',
    TAX_PURCHASE_FEATURE_DISABLED: 'Modul Pajak Pembelian belum diaktifkan.',
    CURRENT_SALES_TAX_RULE_REQUIRED: 'Pilih aturan Pajak Penjualan aktif yang berlaku saat ini.',
    CURRENT_PURCHASE_TAX_RULE_REQUIRED: 'Pilih aturan Pajak Pembelian aktif yang berlaku saat ini.',
  }
  return messages[code ?? ''] ?? code ?? 'Operasi Product gagal.'
}

export function CanonicalProductsView({
  session,
  companyId,
  canManage,
  notify,
  onChanged,
}: {
  session: Session
  companyId: string
  canManage: boolean
  notify: (message: string) => void
  onChanged: () => Promise<void>
}) {
  const [products, setProducts] = useState<ProductRow[]>([])
  const [categories, setCategories] = useState<Category[]>([])
  const [uoms, setUoms] = useState<UomMaster[]>([])
  const [taxRules, setTaxRules] = useState<TaxRuleOption[]>([])
  const [taxEntitlements, setTaxEntitlements] = useState({
    salesEnabled: false,
    purchaseEnabled: false,
  })
  const [stockBalances, setStockBalances] = useState<StockBalance[]>([])
  const [stockWarehouses, setStockWarehouses] = useState<StockWarehouse[]>([])
  const [query, setQuery] = useState('')
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [editor, setEditor] = useState<ProductRow | 'create' | null>(null)

  const fetchData = useCallback(async () => {
    const paths = [
      '/api/master/products?includeInactive=true',
      '/api/master/product-categories?includeInactive=true',
      '/api/master/uoms?includeInactive=true',
      '/api/master/tax-assignment-options',
      '/api/inventory/stock-overview',
    ]
    const responses = await Promise.all(
      paths.map((path) => fetch(path, { headers: authHeaders(session) })),
    )
    const payloads = (await Promise.all(responses.map((response) => response.json()))) as [
      ApiList<ProductRow>,
      ApiList<Category>,
      ApiList<UomMaster>,
      TaxOptions,
      StockOverview,
    ]
    const failed = responses.findIndex((response) => !response.ok)
    if (failed >= 0) throw new Error(friendlyError(payloads[failed].error))
    return payloads
  }, [session])

  useEffect(() => {
    let cancelled = false
    fetchData()
      .then((payloads) => {
        if (cancelled) return
        setProducts((payloads[0].data ?? []).filter((product) => !product.is_bundle))
        setCategories(payloads[1].data ?? [])
        setUoms(payloads[2].data ?? [])
        setTaxRules(payloads[3].data ?? [])
        setTaxEntitlements(payloads[3].entitlements ?? {
          salesEnabled: false,
          purchaseEnabled: false,
        })
        setStockBalances(payloads[4].balances ?? [])
        setStockWarehouses(payloads[4].warehouses ?? [])
      })
      .catch((caught) => {
        if (!cancelled) setError(caught instanceof Error ? caught.message : 'Gagal memuat Product.')
      })
      .finally(() => {
        if (!cancelled) setLoading(false)
      })
    return () => {
      cancelled = true
    }
  }, [companyId, fetchData])

  async function refresh() {
    setLoading(true)
    setError('')
    try {
      const payloads = await fetchData()
      setProducts((payloads[0].data ?? []).filter((product) => !product.is_bundle))
      setCategories(payloads[1].data ?? [])
      setUoms(payloads[2].data ?? [])
      setTaxRules(payloads[3].data ?? [])
      setTaxEntitlements(payloads[3].entitlements ?? {
        salesEnabled: false,
        purchaseEnabled: false,
      })
      setStockBalances(payloads[4].balances ?? [])
      setStockWarehouses(payloads[4].warehouses ?? [])
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Gagal memuat Product.')
    } finally {
      setLoading(false)
    }
  }

  const filtered = useMemo(() => {
    const normalized = query.trim().toLowerCase()
    if (!normalized) return products
    return products.filter((product) =>
      [product.sku, product.name, product.category?.category_name ?? ''].some((value) =>
        value.toLowerCase().includes(normalized),
      ),
    )
  }, [products, query])

  const readyToCreate = categories.some((item) => item.is_active) && uoms.some((item) => item.is_active)
  const ruleName = (id: string | null | undefined) =>
    taxRules.find((rule) => rule.id === id)?.name ?? 'Tanpa pajak'
  const warehouseById = useMemo(
    () => new Map(stockWarehouses.map((warehouse) => [warehouse.id, warehouse])),
    [stockWarehouses],
  )
  const balancesByProduct = useMemo(() => {
    const grouped = new Map<string, StockBalance[]>()
    for (const balance of stockBalances) {
      grouped.set(balance.product_id, [
        ...(grouped.get(balance.product_id) ?? []),
        balance,
      ])
    }
    return grouped
  }, [stockBalances])

  return (
    <>
      <div className="mb-7 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <p className="text-xs font-bold uppercase tracking-[.16em] text-emerald-600">Master Product</p>
          <h1 className="mt-2 text-2xl font-black tracking-tight text-slate-950 md:text-3xl">Produk & UOM</h1>
          <p className="mt-2 text-sm text-slate-500">
            Product STOCK dan seluruh konversi UOM disimpan sebagai satu perubahan atomic.
          </p>
        </div>
        <div className="flex gap-2">
          <button onClick={() => void refresh()} className="inline-flex items-center gap-2 rounded-xl border border-slate-200 bg-white px-4 py-3 text-sm font-bold text-slate-600">
            <RefreshCcw className={`h-4 w-4 ${loading ? 'animate-spin' : ''}`} /> Muat ulang
          </button>
          {canManage && (
            <button
              disabled={!readyToCreate}
              onClick={() => setEditor('create')}
              className="inline-flex items-center gap-2 rounded-xl bg-emerald-500 px-4 py-3 text-sm font-bold text-white disabled:cursor-not-allowed disabled:opacity-50"
            >
              <Plus className="h-4 w-4" /> Tambah Product
            </button>
          )}
        </div>
      </div>

      {!readyToCreate && canManage && (
        <div className="mb-5 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-800">
          Buat minimal satu Category dan satu UOM aktif pada menu Master Data sebelum membuat Product.
        </div>
      )}
      {error && <div className="mb-5 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-700">{error}</div>}

      <div className="rounded-2xl border border-slate-200 bg-white shadow-sm">
        <div className="flex items-center gap-3 border-b border-slate-100 p-4">
          <Search className="h-4 w-4 text-slate-400" />
          <input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Cari SKU, nama, atau kategori..." className="w-full bg-transparent text-sm outline-none" />
        </div>
        <div className="overflow-x-auto">
          <table className="w-full min-w-[1250px] text-left text-sm">
            <thead className="bg-slate-50 text-xs uppercase tracking-wider text-slate-500">
              <tr><th className="px-5 py-4">Product</th><th className="px-5 py-4">Category</th><th className="px-5 py-4">Base UOM</th><th className="px-5 py-4">Stok aktual</th><th className="px-5 py-4">Per Gudang</th><th className="px-5 py-4">UOM tersedia</th><th className="px-5 py-4">Acuan berat</th><th className="px-5 py-4">Pajak efektif</th><th className="px-5 py-4">Status</th>{canManage && <th className="px-5 py-4 text-right">Aksi</th>}</tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {filtered.map((product) => {
                const base = product.product_uoms.find((row) => row.uom_id === product.uom_id)
                const weight = product.product_uoms.find((row) => row.uom_id === product.weight_reference_uom_id)
                const productBalances = balancesByProduct.get(product.id) ?? []
                const actualStock = productBalances.reduce(
                  (total, balance) => total + (Number(balance.stock_qty) || 0),
                  0,
                )
                return (
                  <tr key={product.id}>
                    <td className="px-5 py-4"><p className="font-bold">{product.name}</p><p className="mt-1 text-xs font-semibold text-slate-400">{product.sku}</p></td>
                    <td className="px-5 py-4 text-slate-600">{product.category?.category_name ?? '-'}</td>
                    <td className="px-5 py-4 font-semibold">{base?.uom?.name ?? '-'}</td>
                    <td className="px-5 py-4 font-black text-slate-900">{actualStock.toLocaleString('id-ID', { maximumFractionDigits: 6 })} {base?.uom?.name ?? ''}</td>
                    <td className="px-5 py-4 text-xs leading-5 text-slate-600">
                      {productBalances.length
                        ? productBalances.map((balance) => (
                            <span key={balance.warehouse_id} className="block">
                              {warehouseById.get(balance.warehouse_id)?.name ?? 'Gudang'}: <b>{Number(balance.stock_qty).toLocaleString('id-ID', { maximumFractionDigits: 6 })}</b>
                            </span>
                          ))
                        : 'Belum ada saldo'}
                    </td>
                    <td className="px-5 py-4 text-slate-600">{product.product_uoms.filter((row) => row.is_active).length}</td>
                    <td className="px-5 py-4 text-slate-600">{weight?.uom?.name ?? '-'} · {Number(product.weight_per_uom_kg).toLocaleString('id-ID')} kg</td>
                    <td className="px-5 py-4 text-xs leading-5 text-slate-600"><span className="block">Jual: {ruleName(product.sales_tax_rule_id ?? product.category?.default_sales_tax_rule_id)}</span><span className="block">Beli: {ruleName(product.purchase_tax_rule_id ?? product.category?.default_purchase_tax_rule_id)}</span></td>
                    <td className="px-5 py-4"><span className={`rounded-full px-2.5 py-1 text-[11px] font-bold ${product.is_active ? 'bg-emerald-50 text-emerald-700' : 'bg-slate-100 text-slate-500'}`}>{product.is_active ? 'Aktif' : 'Nonaktif'}</span></td>
                    {canManage && <td className="px-5 py-4 text-right"><button onClick={() => setEditor(product)} className="rounded-lg border border-slate-200 p-2 text-slate-500 hover:text-emerald-600" aria-label="Edit Product"><Edit3 className="h-4 w-4" /></button></td>}
                  </tr>
                )
              })}
              {!loading && !filtered.length && <tr><td colSpan={canManage ? 10 : 9} className="p-10 text-center text-sm text-slate-400">Belum ada Product canonical.</td></tr>}
            </tbody>
          </table>
          {loading && <div className="p-10 text-center text-sm text-slate-500">Memuat Product...</div>}
        </div>
      </div>

      {editor && (
        <ProductEditor
          record={editor === 'create' ? undefined : editor}
          categories={categories.filter((item) => item.is_active || item.id === (editor === 'create' ? '' : editor.category_id))}
          uoms={uoms.filter((item) => item.is_active || (editor !== 'create' && editor.product_uoms.some((row) => row.uom_id === item.id)))}
          taxRules={taxRules}
          taxEntitlements={taxEntitlements}
          close={() => setEditor(null)}
          save={async (body) => {
            const record = editor === 'create' ? undefined : editor
            const response = await fetch(record ? `/api/master/products/${record.id}` : '/api/master/products', {
              method: record ? 'PATCH' : 'POST',
              headers: { 'Content-Type': 'application/json', ...authHeaders(session) },
              body: JSON.stringify({ ...body, ...(record ? { masterVersion: record.master_version } : {}) }),
            })
            const payload = (await response.json()) as { error?: string }
            if (!response.ok) throw new Error(friendlyError(payload.error))
            setEditor(null)
            await refresh()
            await onChanged()
            notify(`Product berhasil ${record ? 'diperbarui' : 'dibuat'}.`)
          }}
        />
      )}
    </>
  )
}

function initialDraft(record: ProductRow | undefined, categories: Category[], uoms: UomMaster[]): ProductDraft {
  if (record) {
    return {
      sku: record.sku,
      name: record.name,
      categoryId: record.category_id,
      baseUomId: record.uom_id,
      weightReferenceUomId: record.weight_reference_uom_id,
      weightPerReferenceUomKg: Number(record.weight_per_uom_kg),
      imageUrl: record.image_url ?? '',
      isActive: record.is_active,
      salesTaxRuleId: record.sales_tax_rule_id,
      purchaseTaxRuleId: record.purchase_tax_rule_id,
      uoms: record.product_uoms
        .slice()
        .sort((a, b) => Number(a.factor_to_base) - Number(b.factor_to_base))
        .map((row) => ({
          uomId: row.uom_id,
          factorToBase: Number(row.factor_to_base),
          purchaseAllowed: row.purchase_allowed,
          salesAllowed: row.sales_allowed,
          purchasePrice: Number(row.purchase_price ?? 0),
          salePrice: Number(row.sale_price ?? 0),
          barcode: row.barcode ?? '',
          isActive: row.is_active,
        })),
    }
  }
  const firstUom = uoms.find((item) => item.is_active)?.id ?? ''
  return {
    sku: '',
    name: '',
    categoryId: categories.find((item) => item.is_active)?.id ?? '',
    baseUomId: firstUom,
    weightReferenceUomId: firstUom,
    weightPerReferenceUomKg: 1,
    imageUrl: '',
    isActive: true,
    salesTaxRuleId: null,
    purchaseTaxRuleId: null,
    uoms: firstUom ? [{ uomId: firstUom, factorToBase: 1, purchaseAllowed: true, salesAllowed: true, purchasePrice: 0, salePrice: 0, barcode: '', isActive: true }] : [],
  }
}

function ProductEditor({ record, categories, uoms, taxRules, taxEntitlements, close, save }: { record?: ProductRow; categories: Category[]; uoms: UomMaster[]; taxRules: TaxRuleOption[]; taxEntitlements: { salesEnabled: boolean; purchaseEnabled: boolean }; close: () => void; save: (body: ProductDraft & { isBundle: false }) => Promise<void> }) {
  useEscapeClose(close)
  const [form, setForm] = useState(() => initialDraft(record, categories, uoms))
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState('')

  function largestUomId(rows: UomDraft[]) {
    return rows.reduce((largest, row) => row.factorToBase > largest.factorToBase ? row : largest).uomId
  }

  function updateUom(index: number, changes: Partial<UomDraft>) {
    setForm((current) => {
      const rows = current.uoms.map((row, rowIndex) => rowIndex === index ? { ...row, ...changes } : row)
      return { ...current, uoms: rows, weightReferenceUomId: largestUomId(rows) }
    })
  }

  function changeUom(index: number, nextUomId: string) {
    setForm((current) => {
      const rows = current.uoms.map((row, rowIndex) => rowIndex === index ? { ...row, uomId: nextUomId } : row)
      return { ...current, uoms: rows, weightReferenceUomId: largestUomId(rows) }
    })
  }

  function changeBaseUom(nextUomId: string) {
    setForm((current) => {
      if (current.uoms.length > 1) return current
      const baseRow = current.uoms[0]
      const rows = [{ ...baseRow, uomId: nextUomId, factorToBase: 1 }]
      return { ...current, baseUomId: nextUomId, weightReferenceUomId: nextUomId, uoms: rows }
    })
  }

  function addDerivedUom() {
    const next = uoms.find((master) => !form.uoms.some((row) => row.uomId === master.id))
    if (!next) return
    setForm((current) => {
      const nextFactor = Math.max(...current.uoms.map((row) => row.factorToBase)) + 1
      const rows = [
        ...current.uoms.map((row) => ({ ...row, purchaseAllowed: false })),
        { uomId: next.id, factorToBase: nextFactor, purchaseAllowed: true, salesAllowed: false, purchasePrice: 0, salePrice: 0, barcode: '', isActive: true },
      ]
      return { ...current, uoms: rows, weightReferenceUomId: next.id }
    })
  }

  function removeDerivedUom(uomId: string) {
    setForm((current) => {
      let rows = current.uoms.filter((row) => row.uomId !== uomId)
      if (!rows.some((row) => row.purchaseAllowed)) {
        rows = rows.map((row) => row.uomId === current.baseUomId ? { ...row, purchaseAllowed: true } : row)
      }
      if (!rows.some((row) => row.salesAllowed)) {
        rows = rows.map((row) => row.uomId === current.baseUomId ? { ...row, salesAllowed: true } : row)
      }
      return { ...current, uoms: rows, weightReferenceUomId: largestUomId(rows) }
    })
  }

  async function submit(event: React.FormEvent) {
    event.preventDefault()
    const baseRow = form.uoms.find((row) => row.uomId === form.baseUomId)
    if (!baseRow || baseRow.factorToBase !== 1) {
      setError('Satuan stok dasar Product tidak valid.')
      return
    }
    setLoading(true)
    setError('')
    try {
      await save({ ...form, weightReferenceUomId: largestUomId(form.uoms), isBundle: false })
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Gagal menyimpan Product.')
    } finally {
      setLoading(false)
    }
  }

  const baseRowIndex = form.uoms.findIndex((row) => row.uomId === form.baseUomId)
  const baseRow = form.uoms[baseRowIndex]
  const baseMaster = uoms.find((master) => master.id === form.baseUomId)
  const gradedRows = form.uoms
    .filter((row) => row.uomId !== form.baseUomId)
    .slice()
    .sort((a, b) => a.factorToBase - b.factorToBase)
  const largestRow = form.uoms.reduce((largest, row) => row.factorToBase > largest.factorToBase ? row : largest)
  const largestMaster = uoms.find((master) => master.id === largestRow.uomId)
  const unusedUoms = uoms.filter((master) => !form.uoms.some((row) => row.uomId === master.id))
  const selectedCategory = categories.find((category) => category.id === form.categoryId)
  const salesRules = taxRules.filter((rule) => rule.scope === 'SALES')
  const purchaseRules = taxRules.filter((rule) => rule.scope === 'PURCHASE')
  const taxLabel = (id: string | null | undefined) =>
    taxRules.find((rule) => rule.id === id)?.name ?? 'Tanpa pajak'

  return (
    <div className="fixed inset-0 z-[90] grid place-items-center bg-slate-950/45 p-4 backdrop-blur-sm">
      <div className="max-h-[94vh] w-full max-w-5xl overflow-y-auto rounded-3xl bg-white p-6 shadow-2xl sm:p-8">
        <div className="flex items-start justify-between gap-4">
          <div><h2 className="text-xl font-black">{record ? 'Edit Product' : 'Product baru'}</h2><p className="mt-2 text-sm text-slate-500">Tipe Product pada fase ini adalah STOCK. Bundle disiapkan pada G3.</p></div>
          <button onClick={close} className="rounded-xl bg-slate-100 p-2 text-slate-500" aria-label="Tutup"><X className="h-4 w-4" /></button>
        </div>

        <form onSubmit={submit} className="mt-7 space-y-6">
          <div className="grid gap-4 sm:grid-cols-2">
            <Field label="SKU"><input required maxLength={100} value={form.sku} onChange={(event) => setForm({ ...form, sku: event.target.value.toUpperCase() })} className="input" /></Field>
            <Field label="Nama Product"><input required maxLength={200} value={form.name} onChange={(event) => setForm({ ...form, name: event.target.value })} className="input" /></Field>
            <Field label="Category"><select required value={form.categoryId} onChange={(event) => setForm({ ...form, categoryId: event.target.value })} className="input">{categories.map((category) => <option key={category.id} value={category.id}>{category.category_name} ({category.category_code})</option>)}</select></Field>
            <Field label="UOM stok dasar">
              <select required disabled={form.uoms.length > 1} value={form.baseUomId} onChange={(event) => changeBaseUom(event.target.value)} className="input disabled:bg-slate-100">
                {uoms.map((master) => <option key={master.id} value={master.id}>{master.name}</option>)}
              </select>
              <span className="mt-2 block text-xs font-normal text-slate-500">{form.uoms.length > 1 ? 'Hapus seluruh kemasan tambahan sebelum mengganti UOM dasar.' : 'Pilih satuan terkecil tempat stok disimpan.'}</span>
            </Field>
            <Field label="Tipe Product"><input value="STOCK" disabled className="input bg-slate-100" /></Field>
            <Field label="URL gambar eksternal (opsional)"><input type="url" maxLength={2000} placeholder="https://drive.google.com/..." value={form.imageUrl} onChange={(event) => setForm({ ...form, imageUrl: event.target.value })} className="input" /></Field>
          </div>

          {(taxEntitlements.salesEnabled || taxEntitlements.purchaseEnabled) && (
            <div className="rounded-2xl border border-blue-200 bg-blue-50/40 p-5">
              <h3 className="font-black text-slate-900">Aturan pajak</h3>
              <p className="mt-1 text-xs leading-5 text-slate-600">
                Secara default Product mengikuti Category. Pilih override hanya bila Product ini benar-benar memiliki aturan berbeda.
              </p>
              <div className="mt-4 grid gap-4 sm:grid-cols-2">
                {taxEntitlements.salesEnabled && (
                  <Field label="Pajak penjualan">
                    <select value={form.salesTaxRuleId ?? ''} onChange={(event) => setForm({ ...form, salesTaxRuleId: event.target.value || null })} className="input">
                      <option value="">Ikuti Category · {taxLabel(selectedCategory?.default_sales_tax_rule_id)}</option>
                      {salesRules.map((rule) => <option key={rule.id} value={rule.id}>Override · {rule.name} ({Number(rule.ratePercent).toLocaleString('id-ID')}%)</option>)}
                    </select>
                  </Field>
                )}
                {taxEntitlements.purchaseEnabled && (
                  <Field label="Pajak pembelian">
                    <select value={form.purchaseTaxRuleId ?? ''} onChange={(event) => setForm({ ...form, purchaseTaxRuleId: event.target.value || null })} className="input">
                      <option value="">Ikuti Category · {taxLabel(selectedCategory?.default_purchase_tax_rule_id)}</option>
                      {purchaseRules.map((rule) => <option key={rule.id} value={rule.id}>Override · {rule.name} ({Number(rule.ratePercent).toLocaleString('id-ID')}%)</option>)}
                    </select>
                  </Field>
                )}
              </div>
              <p className="mt-4 text-xs text-blue-700">Ini baru assignment master. Kalkulasi pajak transaksi belum diaktifkan.</p>
            </div>
          )}

          <div className="rounded-2xl border border-emerald-200 bg-emerald-50/50 p-5">
            <div className="flex flex-wrap items-center gap-2"><h3 className="mr-auto font-black text-slate-900">UOM Dasar: {baseMaster?.name ?? '-'}</h3><span className="rounded-full bg-emerald-100 px-3 py-1 text-xs font-bold text-emerald-700">1 {baseMaster?.name ?? 'UOM'} = 1 stok</span></div>
            <p className="mt-2 text-xs leading-5 text-slate-600">Harga dan barcode di bawah berlaku untuk satu {baseMaster?.name ?? 'UOM dasar'}. Stok internal selalu disimpan dalam satuan ini.</p>
            <div className="mt-4 grid gap-4 md:grid-cols-4">
              <Field label={`Harga beli / ${baseMaster?.name ?? 'base'}`}><input type="number" min={0} step="0.0001" required={baseRow.purchaseAllowed} disabled={!baseRow.purchaseAllowed} value={baseRow.purchasePrice} onChange={(event) => updateUom(baseRowIndex, { purchasePrice: Number(event.target.value) })} className="input disabled:bg-slate-100" /></Field>
              <Field label={`Harga jual / ${baseMaster?.name ?? 'base'}`}><input type="number" min={0} step="0.0001" required={baseRow.salesAllowed} disabled={!baseRow.salesAllowed} value={baseRow.salePrice} onChange={(event) => updateUom(baseRowIndex, { salePrice: Number(event.target.value) })} className="input disabled:bg-slate-100" /></Field>
              <Field label="Barcode base (opsional)"><input maxLength={100} value={baseRow.barcode} onChange={(event) => updateUom(baseRowIndex, { barcode: event.target.value })} className="input" /></Field>
              <div><p className="mb-2 text-sm font-semibold text-slate-700">Digunakan untuk</p><div className="flex flex-wrap gap-4 pt-3 text-sm font-semibold"><label className="flex items-center gap-2"><input type="checkbox" checked={baseRow.purchaseAllowed} onChange={(event) => updateUom(baseRowIndex, { purchaseAllowed: event.target.checked })} />Pembelian</label><label className="flex items-center gap-2"><input type="checkbox" checked={baseRow.salesAllowed} onChange={(event) => updateUom(baseRowIndex, { salesAllowed: event.target.checked })} />Penjualan</label></div></div>
            </div>
          </div>

          <div className="rounded-2xl border border-slate-200">
            <div className="flex flex-col gap-3 border-b border-slate-100 p-5 sm:flex-row sm:items-center sm:justify-between">
              <div><h3 className="font-black">Kemasan / UOM Turunan</h3><p className="mt-1 text-xs text-slate-500">Opsional. Isi berapa UOM dasar di dalam satu kemasan. Sistem mengurutkan grading otomatis.</p></div>
              <button type="button" disabled={!unusedUoms.length} onClick={addDerivedUom} className="inline-flex items-center gap-2 rounded-xl border border-slate-200 px-3 py-2 text-xs font-bold disabled:opacity-50"><PackagePlus className="h-4 w-4" /> Tambah kemasan</button>
            </div>
            <div className="space-y-4 p-5">
              {!gradedRows.length && <div className="rounded-2xl border border-dashed border-slate-300 p-6 text-center text-sm text-slate-500">Belum ada kemasan tambahan. Product hanya memakai UOM dasar {baseMaster?.name ?? '-'}.</div>}
              {gradedRows.map((row, gradeIndex) => {
                const rowIndex = form.uoms.findIndex((item) => item.uomId === row.uomId)
                const master = uoms.find((item) => item.id === row.uomId)
                const derivedWeight = form.weightPerReferenceUomKg * row.factorToBase / largestRow.factorToBase
                return (
                  <div key={row.uomId} className="rounded-2xl bg-slate-50 p-4">
                    <div className="mb-4 flex flex-wrap items-center gap-2"><p className="mr-auto font-black">Kemasan {gradeIndex + 1}</p><span className="rounded-full bg-slate-200 px-2.5 py-1 text-[11px] font-bold text-slate-700">{row.factorToBase} × {baseMaster?.name ?? 'BASE'}</span>{row.uomId === largestRow.uomId && <span className="rounded-full bg-blue-100 px-2.5 py-1 text-[11px] font-bold text-blue-700">Terbesar · acuan berat · rekomendasi beli</span>}</div>
                    <div className="grid gap-4 md:grid-cols-4">
                      <Field label="Nama kemasan"><select value={row.uomId} onChange={(event) => changeUom(rowIndex, event.target.value)} className="input">{uoms.filter((item) => item.id === row.uomId || !form.uoms.some((existing) => existing.uomId === item.id)).map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}</select></Field>
                      <Field label={`Isi ${baseMaster?.name ?? 'UOM dasar'}`}><input type="number" min="1.000001" step="0.000001" required value={row.factorToBase} onChange={(event) => updateUom(rowIndex, { factorToBase: Number(event.target.value) })} className="input" /><span className="mt-2 block text-xs font-normal text-slate-500">1 {master?.name ?? 'kemasan'} = {row.factorToBase} {baseMaster?.name ?? 'base'}</span></Field>
                      <Field label={`Harga beli / ${master?.name ?? 'kemasan'}`}><input type="number" min={0} step="0.0001" required={row.purchaseAllowed} disabled={!row.purchaseAllowed} value={row.purchasePrice} onChange={(event) => updateUom(rowIndex, { purchasePrice: Number(event.target.value) })} className="input disabled:bg-slate-100" /></Field>
                      <Field label={`Harga jual / ${master?.name ?? 'kemasan'}`}><input type="number" min={0} step="0.0001" required={row.salesAllowed} disabled={!row.salesAllowed} value={row.salePrice} onChange={(event) => updateUom(rowIndex, { salePrice: Number(event.target.value) })} className="input disabled:bg-slate-100" /></Field>
                      <Field label="Barcode (opsional)"><input maxLength={100} value={row.barcode} onChange={(event) => updateUom(rowIndex, { barcode: event.target.value })} className="input" /></Field>
                      <div className="md:col-span-2"><p className="mb-2 text-sm font-semibold text-slate-700">Digunakan untuk</p><div className="flex flex-wrap gap-4 pt-3 text-sm font-semibold"><label className="flex items-center gap-2"><input type="checkbox" checked={row.purchaseAllowed} onChange={(event) => updateUom(rowIndex, { purchaseAllowed: event.target.checked })} />Pembelian</label><label className="flex items-center gap-2"><input type="checkbox" checked={row.salesAllowed} onChange={(event) => updateUom(rowIndex, { salesAllowed: event.target.checked })} />Penjualan</label></div></div>
                      <div><p className="text-xs font-bold uppercase tracking-wide text-slate-500">Estimasi berat</p><p className="mt-2 text-sm font-bold">{derivedWeight.toLocaleString('id-ID', { maximumFractionDigits: 6 })} kg / {master?.name ?? 'UOM'}</p></div>
                    </div>
                    <div className="mt-4 flex justify-end"><button type="button" onClick={() => removeDerivedUom(row.uomId)} className="inline-flex items-center gap-1 text-xs font-bold text-rose-600"><Trash2 className="h-3.5 w-3.5" /> Hapus kemasan</button></div>
                  </div>
                )
              })}
            </div>
          </div>

          <div className="grid gap-4 rounded-2xl border border-blue-200 bg-blue-50/50 p-5 sm:grid-cols-2">
            <div><p className="text-xs font-bold uppercase tracking-wide text-blue-600">Grading otomatis</p><p className="mt-2 font-black text-slate-900">Terbesar: {largestMaster?.name ?? '-'} · {largestRow.factorToBase} {baseMaster?.name ?? 'BASE'}</p><p className="mt-1 text-xs text-slate-600">Kemasan terbesar otomatis menjadi acuan berat dan rekomendasi satuan pembelian.</p>{!largestRow.purchaseAllowed && <p className="mt-2 text-xs font-bold text-amber-700">Aktifkan Pembelian pada {largestMaster?.name ?? 'UOM terbesar'} jika ingin memakainya untuk pembelian.</p>}</div>
            <Field label={`Berat 1 ${largestMaster?.name ?? 'UOM terbesar'} (kg)`}><input type="number" required min="0.000001" step="0.000001" value={form.weightPerReferenceUomKg} onChange={(event) => setForm({ ...form, weightPerReferenceUomKg: Number(event.target.value) })} className="input" /><span className="mt-2 block text-xs font-normal text-slate-500">Berat UOM lain dihitung otomatis secara proporsional.</span></Field>
          </div>

          <label className="flex items-center gap-3 rounded-xl border border-slate-200 p-3 text-sm font-semibold"><input type="checkbox" checked={form.isActive} onChange={(event) => setForm({ ...form, isActive: event.target.checked })} />Product aktif dan dapat dipakai</label>
          {error && <div className="rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-700">{error}</div>}
          <div className="flex justify-end gap-3 border-t border-slate-100 pt-5"><button type="button" onClick={close} className="rounded-xl border border-slate-200 px-4 py-2.5 text-sm font-bold">Batal</button><button disabled={loading} className="inline-flex items-center gap-2 rounded-xl bg-emerald-500 px-5 py-2.5 text-sm font-bold text-white disabled:opacity-60">{loading && <Loader2 className="h-4 w-4 animate-spin" />}Simpan Product</button></div>
        </form>
      </div>
    </div>
  )
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return <label className="block text-sm font-semibold text-slate-700">{label}<span className="mt-2 block">{children}</span></label>
}
