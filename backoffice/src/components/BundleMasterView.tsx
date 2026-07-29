'use client'

import { useCallback, useEffect, useMemo, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import {
  Boxes,
  Edit3,
  Eye,
  Loader2,
  PackagePlus,
  Plus,
  RefreshCcw,
  Search,
  Trash2,
  X,
} from 'lucide-react'
import { useEscapeClose } from '@/lib/use-escape-close'

type Category = { id: string; category_name: string; is_active: boolean }
type Uom = { id: string; name: string; is_active: boolean }
type ProductUom = {
  uom_id: string
  factor_to_base: number | string
  is_active: boolean
  uom: Uom | null
}
type Product = {
  id: string
  sku: string
  name: string
  is_bundle: boolean
  is_active: boolean
  weight_reference_uom_id: string
  weight_per_uom_kg: number | string
  product_uoms: ProductUom[] | null
}
type Bundle = {
  id: string
  sku: string
  name: string
  category_id: string
  uom_id: string
  weight_per_uom_kg: number | string
  image_url: string | null
  is_active: boolean
  master_version: number
}
type BundleComponent = {
  id: string
  bundle_id: string
  item_id: string
  component_uom_id: string
  component_qty: number | string
  line_no: number
}
type BundleSalesUom = {
  product_id: string
  uom_id: string
  sale_price: number | string | null
  barcode: string | null
}
type Warehouse = { id: string; name: string; is_active: boolean }
type ComponentDraft = { productId: string; uomId: string; quantity: number }
type Draft = {
  sku: string
  name: string
  categoryId: string
  salesUomId: string
  salePrice: number
  barcode: string
  imageUrl: string
  isActive: boolean
  components: ComponentDraft[]
}
type ListPayload<T> = { data?: T[]; error?: string }
type BundlePayload = {
  data?: Bundle[]
  components?: BundleComponent[]
  salesUoms?: BundleSalesUom[]
  error?: string
}
type Availability = {
  bundleId: string
  warehouseId: string
  availableQuantity: number | string
  components: {
    componentProductId: string
    componentName: string
    componentUomId: string
    componentUomName: string
    quantityPerBundle: number | string
    onHandBaseQty: number | string
    capacity: number | string
  }[]
}

function authHeaders(session: Session, json = false) {
  return {
    Authorization: `Bearer ${session.access_token}`,
    ...(json ? { 'Content-Type': 'application/json' } : {}),
  }
}

function money(value: number | string | null | undefined) {
  return new Intl.NumberFormat('id-ID', {
    style: 'currency',
    currency: 'IDR',
    maximumFractionDigits: 0,
  }).format(Number(value ?? 0))
}

function qty(value: number | string | null | undefined) {
  return new Intl.NumberFormat('id-ID', { maximumFractionDigits: 6 }).format(Number(value ?? 0))
}

function friendlyError(code?: string) {
  const messages: Record<string, string> = {
    MASTER_VERSION_CONFLICT: 'Bundle sudah berubah di tab lain. Muat ulang sebelum mengedit.',
    DUPLICATE_BUNDLE_OR_BARCODE: 'SKU, nama, atau barcode sudah dipakai.',
    BUNDLE_COMPONENTS_REQUIRED: 'Tambahkan minimal satu komponen.',
    DUPLICATE_BUNDLE_COMPONENT: 'Produk dan UOM komponen yang sama tidak boleh diulang.',
    ACTIVE_STOCK_COMPONENT_UOM_NOT_FOUND: 'Produk stok atau UOM komponen tidak aktif/tidak tersedia.',
    ACTIVE_PRODUCT_CATEGORY_NOT_FOUND: 'Kategori tidak aktif atau bukan milik company aktif.',
    ACTIVE_BUNDLE_SALES_UOM_NOT_FOUND: 'UOM jual tidak aktif atau bukan milik company aktif.',
    NESTED_BUNDLE_NOT_ALLOWED: 'Bundle tidak boleh berisi Bundle lain.',
    BUNDLE_SELF_COMPONENT_NOT_ALLOWED: 'Bundle tidak boleh menjadi komponennya sendiri.',
    BUNDLE_SALE_PRICE_INVALID: 'Harga jual final Bundle tidak valid.',
    COMPONENT_WEIGHT_CONTRACT_INVALID: 'Konfigurasi berat salah satu komponen belum valid.',
    BUNDLE_PHYSICAL_STOCK_NOT_ALLOWED: 'Bundle virtual tidak boleh memiliki stok fisik.',
    PRODUCT_IMAGE_HTTPS_REQUIRED: 'URL gambar wajib menggunakan HTTPS.',
    CATALOG_MANAGER_REQUIRED: 'Role Anda tidak diizinkan mengubah Bundle.',
    FORBIDDEN: 'Role Anda tidak diizinkan melihat ketersediaan Bundle.',
  }
  return messages[code ?? ''] ?? code ?? 'Operasi Bundle gagal.'
}

export function BundleMasterView({
  session,
  companyId,
  canManage,
  notify,
}: {
  session: Session
  companyId: string
  canManage: boolean
  notify: (message: string) => void
}) {
  const [bundles, setBundles] = useState<Bundle[]>([])
  const [bundleComponents, setBundleComponents] = useState<BundleComponent[]>([])
  const [bundleSalesUoms, setBundleSalesUoms] = useState<BundleSalesUom[]>([])
  const [products, setProducts] = useState<Product[]>([])
  const [categories, setCategories] = useState<Category[]>([])
  const [uoms, setUoms] = useState<Uom[]>([])
  const [warehouses, setWarehouses] = useState<Warehouse[]>([])
  const [query, setQuery] = useState('')
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [editor, setEditor] = useState<Bundle | 'create' | null>(null)
  const [availabilityBundle, setAvailabilityBundle] = useState<Bundle | null>(null)

  const load = useCallback(async () => {
    const paths = [
      '/api/master/bundles?includeInactive=true',
      '/api/master/products?includeInactive=true',
      '/api/master/product-categories?includeInactive=true',
      '/api/master/uoms?includeInactive=true',
      '/api/master/warehouses?includeInactive=true',
    ]
    const responses = await Promise.all(
      paths.map((path) => fetch(path, { headers: authHeaders(session) })),
    )
    const payloads = (await Promise.all(responses.map((response) => response.json()))) as [
      BundlePayload,
      ListPayload<Product>,
      ListPayload<Category>,
      ListPayload<Uom>,
      ListPayload<Warehouse>,
    ]
    const failed = responses.findIndex((response) => !response.ok)
    if (failed >= 0) throw new Error(friendlyError(payloads[failed].error))
    setBundles(payloads[0].data ?? [])
    setBundleComponents(payloads[0].components ?? [])
    setBundleSalesUoms(payloads[0].salesUoms ?? [])
    setProducts((payloads[1].data ?? []).filter((product) => !product.is_bundle))
    setCategories(payloads[2].data ?? [])
    setUoms(payloads[3].data ?? [])
    setWarehouses(payloads[4].data ?? [])
  }, [session])

  const refresh = useCallback(async () => {
    setLoading(true)
    setError('')
    try {
      await load()
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Gagal memuat Bundle.')
    } finally {
      setLoading(false)
    }
  }, [load])

  useEffect(() => {
    let cancelled = false
    // eslint-disable-next-line react-hooks/set-state-in-effect -- tenant data follows the active Company prop
    load()
      .catch((caught) => {
        if (!cancelled) setError(caught instanceof Error ? caught.message : 'Gagal memuat Bundle.')
      })
      .finally(() => {
        if (!cancelled) setLoading(false)
      })
    return () => {
      cancelled = true
    }
  }, [companyId, load])

  const productById = useMemo(
    () => new Map(products.map((product) => [product.id, product])),
    [products],
  )
  const uomById = useMemo(() => new Map(uoms.map((uom) => [uom.id, uom])), [uoms])
  const categoryById = useMemo(
    () => new Map(categories.map((category) => [category.id, category])),
    [categories],
  )
  const componentsByBundle = useMemo(() => {
    const result = new Map<string, BundleComponent[]>()
    bundleComponents.forEach((component) => {
      result.set(component.bundle_id, [...(result.get(component.bundle_id) ?? []), component])
    })
    return result
  }, [bundleComponents])
  const salesUomByBundle = useMemo(
    () => new Map(bundleSalesUoms.map((row) => [row.product_id, row])),
    [bundleSalesUoms],
  )
  const filtered = useMemo(() => {
    const needle = query.trim().toLocaleLowerCase('id-ID')
    if (!needle) return bundles
    return bundles.filter((bundle) =>
      `${bundle.name} ${bundle.sku}`.toLocaleLowerCase('id-ID').includes(needle),
    )
  }, [bundles, query])

  function componentSummary(bundleId: string) {
    return (componentsByBundle.get(bundleId) ?? [])
      .map((component) => {
        const product = productById.get(component.item_id)
        return `${qty(component.component_qty)} ${uomById.get(component.component_uom_id)?.name ?? 'UOM'} ${product?.name ?? 'Produk'}`
      })
      .join(' + ')
  }

  return (
    <section className="space-y-6">
      <div className="flex flex-col gap-4 rounded-3xl border border-slate-200 bg-white p-6 shadow-sm lg:flex-row lg:items-center lg:justify-between">
        <div>
          <div className="mb-2 flex items-center gap-2 text-emerald-700">
            <Boxes className="h-5 w-5" />
            <span className="text-sm font-bold uppercase tracking-wide">Master Bundle</span>
          </div>
          <h1 className="text-2xl font-black text-slate-950">Paket jual dari beberapa produk</h1>
          <p className="mt-2 max-w-3xl text-sm text-slate-600">
            Bundle tidak menyimpan stok sendiri. Ketersediaannya dihitung otomatis dari stok
            komponen pada gudang yang dipilih.
          </p>
        </div>
        <div className="flex gap-2">
          <button onClick={refresh} className="rounded-xl border border-slate-200 p-3 text-slate-600" aria-label="Muat ulang">
            <RefreshCcw className={`h-5 w-5 ${loading ? 'animate-spin' : ''}`} />
          </button>
          {canManage && (
            <button onClick={() => setEditor('create')} className="flex items-center gap-2 rounded-xl bg-emerald-600 px-4 py-3 font-bold text-white hover:bg-emerald-700">
              <PackagePlus className="h-5 w-5" /> Buat Bundle
            </button>
          )}
        </div>
      </div>

      <div className="relative">
        <Search className="absolute left-4 top-3.5 h-5 w-5 text-slate-400" />
        <input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Cari nama atau SKU Bundle..." className="w-full rounded-2xl border border-slate-200 bg-white py-3 pl-12 pr-4 outline-none focus:border-emerald-500" />
      </div>

      {error && <div className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-semibold text-rose-700">{error}</div>}
      {loading ? (
        <div className="flex justify-center p-16"><Loader2 className="h-8 w-8 animate-spin text-emerald-600" /></div>
      ) : filtered.length === 0 ? (
        <div className="rounded-3xl border border-dashed border-slate-300 bg-white p-16 text-center">
          <Boxes className="mx-auto mb-4 h-10 w-10 text-slate-300" />
          <p className="font-bold text-slate-700">Belum ada Bundle.</p>
          <p className="mt-1 text-sm text-slate-500">Buat paket jual dari produk stok yang sudah aktif.</p>
        </div>
      ) : (
        <div className="grid gap-4 xl:grid-cols-2">
          {filtered.map((bundle) => {
            const saleUom = salesUomByBundle.get(bundle.id)
            return (
              <article key={bundle.id} className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
                <div className="flex items-start justify-between gap-4">
                  <div>
                    <div className="flex flex-wrap items-center gap-2">
                      <h2 className="text-lg font-black text-slate-950">{bundle.name}</h2>
                      <span className={`rounded-full px-2.5 py-1 text-xs font-bold ${bundle.is_active ? 'bg-emerald-50 text-emerald-700' : 'bg-slate-100 text-slate-500'}`}>
                        {bundle.is_active ? 'Aktif' : 'Nonaktif'}
                      </span>
                    </div>
                    <p className="mt-1 text-xs font-semibold text-slate-500">{bundle.sku} · {categoryById.get(bundle.category_id)?.category_name ?? 'Tanpa kategori'}</p>
                  </div>
                  <div className="flex gap-1">
                    <button onClick={() => setAvailabilityBundle(bundle)} className="rounded-xl p-2 text-blue-600 hover:bg-blue-50" aria-label="Cek ketersediaan"><Eye className="h-5 w-5" /></button>
                    {canManage && <button onClick={() => setEditor(bundle)} className="rounded-xl p-2 text-emerald-700 hover:bg-emerald-50" aria-label="Edit Bundle"><Edit3 className="h-5 w-5" /></button>}
                  </div>
                </div>
                <div className="mt-4 rounded-2xl bg-slate-50 p-4">
                  <p className="text-xs font-bold uppercase tracking-wide text-slate-500">Isi Bundle</p>
                  <p className="mt-1 font-semibold text-slate-800">{componentSummary(bundle.id)}</p>
                </div>
                <div className="mt-4 grid grid-cols-3 gap-3 text-sm">
                  <div><p className="text-xs text-slate-500">Satuan jual</p><p className="font-bold">{uomById.get(saleUom?.uom_id ?? bundle.uom_id)?.name ?? '-'}</p></div>
                  <div><p className="text-xs text-slate-500">Harga final</p><p className="font-bold">{money(saleUom?.sale_price)}</p></div>
                  <div><p className="text-xs text-slate-500">Berat total</p><p className="font-bold">{qty(bundle.weight_per_uom_kg)} kg</p></div>
                </div>
              </article>
            )
          })}
        </div>
      )}

      {editor && (
        <BundleEditor
          session={session}
          bundle={editor === 'create' ? null : editor}
          categories={categories}
          uoms={uoms}
          products={products}
          components={editor === 'create' ? [] : componentsByBundle.get(editor.id) ?? []}
          salesUom={editor === 'create' ? undefined : salesUomByBundle.get(editor.id)}
          close={() => setEditor(null)}
          saved={async () => {
            setEditor(null)
            await refresh()
            notify('Bundle berhasil disimpan.')
          }}
        />
      )}
      {availabilityBundle && (
        <AvailabilityModal
          session={session}
          bundle={availabilityBundle}
          warehouses={warehouses}
          close={() => setAvailabilityBundle(null)}
        />
      )}
    </section>
  )
}

function BundleEditor({
  session,
  bundle,
  categories,
  uoms,
  products,
  components,
  salesUom,
  close,
  saved,
}: {
  session: Session
  bundle: Bundle | null
  categories: Category[]
  uoms: Uom[]
  products: Product[]
  components: BundleComponent[]
  salesUom?: BundleSalesUom
  close: () => void
  saved: () => Promise<void>
}) {
  const activeCategories = categories.filter((row) => row.is_active || row.id === bundle?.category_id)
  const activeUoms = uoms.filter((row) => row.is_active || row.id === bundle?.uom_id)
  const initialComponent = (): ComponentDraft => {
    const product = products.find((row) => row.is_active)
    const productUom = product?.product_uoms?.find((row) => row.is_active)
    return { productId: product?.id ?? '', uomId: productUom?.uom_id ?? '', quantity: 1 }
  }
  const [draft, setDraft] = useState<Draft>({
    sku: bundle?.sku ?? '',
    name: bundle?.name ?? '',
    categoryId: bundle?.category_id ?? activeCategories[0]?.id ?? '',
    salesUomId: salesUom?.uom_id ?? bundle?.uom_id ?? activeUoms[0]?.id ?? '',
    salePrice: Number(salesUom?.sale_price ?? 0),
    barcode: salesUom?.barcode ?? '',
    imageUrl: bundle?.image_url ?? '',
    isActive: bundle?.is_active ?? true,
    components: components.length
      ? components.map((row) => ({
          productId: row.item_id,
          uomId: row.component_uom_id,
          quantity: Number(row.component_qty),
        }))
      : [initialComponent()],
  })
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState('')
  useEscapeClose(close)

  const productById = useMemo(
    () => new Map(products.map((product) => [product.id, product])),
    [products],
  )
  const uomById = useMemo(() => new Map(uoms.map((uom) => [uom.id, uom])), [uoms])

  function productUoms(productId: string) {
    return (productById.get(productId)?.product_uoms ?? []).filter((row) => row.is_active)
  }

  const derivedWeight = draft.components.reduce((total, row) => {
    const product = productById.get(row.productId)
    const selected = productUoms(row.productId).find((uom) => uom.uom_id === row.uomId)
    const reference = productUoms(row.productId).find(
      (uom) => uom.uom_id === product?.weight_reference_uom_id,
    )
    if (!product || !selected || !reference || Number(reference.factor_to_base) <= 0) return total
    return total + Number(product.weight_per_uom_kg) *
      (Number(selected.factor_to_base) / Number(reference.factor_to_base)) * row.quantity
  }, 0)

  function updateComponent(index: number, patch: Partial<ComponentDraft>) {
    setDraft((current) => ({
      ...current,
      components: current.components.map((row, rowIndex) =>
        rowIndex === index ? { ...row, ...patch } : row,
      ),
    }))
  }

  async function submit() {
    setError('')
    const duplicate = new Set(draft.components.map((row) => `${row.productId}:${row.uomId}`))
    if (duplicate.size !== draft.components.length) {
      setError('Produk dan UOM komponen yang sama tidak boleh diulang.')
      return
    }
    setSubmitting(true)
    try {
      const response = await fetch(
        bundle ? `/api/master/bundles/${bundle.id}` : '/api/master/bundles',
        {
          method: bundle ? 'PATCH' : 'POST',
          headers: authHeaders(session, true),
          body: JSON.stringify({
            ...draft,
            masterVersion: bundle?.master_version,
          }),
        },
      )
      const payload = (await response.json()) as { error?: string }
      if (!response.ok) throw new Error(friendlyError(payload.error))
      await saved()
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Gagal menyimpan Bundle.')
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-slate-950/60 p-3 backdrop-blur-sm">
      <div className="max-h-[94vh] w-full max-w-5xl overflow-y-auto rounded-3xl bg-white shadow-2xl">
        <div className="sticky top-0 z-10 flex items-center justify-between border-b border-slate-200 bg-white px-6 py-5">
          <div><h2 className="text-xl font-black">{bundle ? 'Edit Bundle' : 'Buat Bundle'}</h2><p className="text-sm text-slate-500">Isi identitas paket, harga jual final, lalu pilih komponennya.</p></div>
          <button onClick={close} className="rounded-xl p-2 hover:bg-slate-100" aria-label="Tutup"><X className="h-5 w-5" /></button>
        </div>
        <div className="space-y-6 p-6">
          <div className="grid gap-4 md:grid-cols-2">
            <Field label="SKU Bundle"><input value={draft.sku} onChange={(event) => setDraft({ ...draft, sku: event.target.value })} className="input" /></Field>
            <Field label="Nama Bundle"><input value={draft.name} onChange={(event) => setDraft({ ...draft, name: event.target.value })} className="input" /></Field>
            <Field label="Kategori"><select value={draft.categoryId} onChange={(event) => setDraft({ ...draft, categoryId: event.target.value })} className="input">{activeCategories.map((row) => <option key={row.id} value={row.id}>{row.category_name}</option>)}</select></Field>
            <Field label="Satuan jual Bundle"><select value={draft.salesUomId} onChange={(event) => setDraft({ ...draft, salesUomId: event.target.value })} className="input">{activeUoms.map((row) => <option key={row.id} value={row.id}>{row.name}</option>)}</select></Field>
            <Field label="Harga jual final"><input type="number" min="0" value={draft.salePrice} onChange={(event) => setDraft({ ...draft, salePrice: Number(event.target.value) })} className="input" /></Field>
            <Field label="Barcode (opsional)"><input value={draft.barcode} onChange={(event) => setDraft({ ...draft, barcode: event.target.value })} className="input" /></Field>
            <Field label="URL gambar HTTPS (opsional)"><input value={draft.imageUrl} onChange={(event) => setDraft({ ...draft, imageUrl: event.target.value })} className="input" /></Field>
            <label className="flex items-center gap-3 self-end rounded-2xl border border-slate-200 p-3 font-semibold"><input type="checkbox" checked={draft.isActive} onChange={(event) => setDraft({ ...draft, isActive: event.target.checked })} /> Bundle aktif dan dapat dijual</label>
          </div>

          <div className="rounded-3xl border border-slate-200">
            <div className="flex items-center justify-between border-b border-slate-200 p-5">
              <div><h3 className="font-black">Komponen Bundle</h3><p className="text-sm text-slate-500">Contoh: 2 Ketul Kebab + 1 Botol Minuman.</p></div>
              <button onClick={() => setDraft({ ...draft, components: [...draft.components, initialComponent()] })} className="flex items-center gap-2 rounded-xl border border-emerald-200 px-3 py-2 text-sm font-bold text-emerald-700"><Plus className="h-4 w-4" /> Tambah komponen</button>
            </div>
            <div className="space-y-3 p-5">
              {draft.components.map((row, index) => {
                const availableUoms = productUoms(row.productId)
                return (
                  <div key={index} className="grid gap-3 rounded-2xl bg-slate-50 p-4 md:grid-cols-[2fr_1.2fr_1fr_auto]">
                    <Field label="Produk stok"><select value={row.productId} onChange={(event) => { const productId = event.target.value; updateComponent(index, { productId, uomId: productUoms(productId)[0]?.uom_id ?? '' }) }} className="input">{products.filter((product) => product.is_active || product.id === row.productId).map((product) => <option key={product.id} value={product.id}>{product.name} ({product.sku})</option>)}</select></Field>
                    <Field label="Satuan komponen"><select value={row.uomId} onChange={(event) => updateComponent(index, { uomId: event.target.value })} className="input">{availableUoms.map((productUom) => <option key={productUom.uom_id} value={productUom.uom_id}>{productUom.uom?.name ?? uomById.get(productUom.uom_id)?.name ?? 'UOM'}</option>)}</select></Field>
                    <Field label="Jumlah"><input type="number" min="0.000001" step="any" value={row.quantity} onChange={(event) => updateComponent(index, { quantity: Number(event.target.value) })} className="input" /></Field>
                    <button disabled={draft.components.length === 1} onClick={() => setDraft({ ...draft, components: draft.components.filter((_, rowIndex) => rowIndex !== index) })} className="mt-6 rounded-xl p-3 text-rose-600 hover:bg-rose-50 disabled:opacity-30" aria-label="Hapus komponen"><Trash2 className="h-5 w-5" /></button>
                  </div>
                )
              })}
            </div>
          </div>

          <div className="rounded-2xl bg-blue-50 p-4 text-sm text-blue-900">
            Perkiraan berat satu Bundle: <strong>{qty(derivedWeight)} kg</strong>. Nilai ini dihitung otomatis dari UOM dan jumlah setiap komponen.
          </div>
          {error && <div className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-semibold text-rose-700">{error}</div>}
        </div>
        <div className="sticky bottom-0 flex justify-end gap-3 border-t border-slate-200 bg-white p-5">
          <button onClick={close} className="rounded-xl border border-slate-200 px-5 py-3 font-bold">Batal</button>
          <button disabled={submitting} onClick={submit} className="flex items-center gap-2 rounded-xl bg-emerald-600 px-5 py-3 font-bold text-white disabled:opacity-50">{submitting && <Loader2 className="h-4 w-4 animate-spin" />} Simpan Bundle</button>
        </div>
      </div>
    </div>
  )
}

function AvailabilityModal({
  session,
  bundle,
  warehouses,
  close,
}: {
  session: Session
  bundle: Bundle
  warehouses: Warehouse[]
  close: () => void
}) {
  const activeWarehouses = warehouses.filter((warehouse) => warehouse.is_active)
  const [warehouseId, setWarehouseId] = useState(activeWarehouses[0]?.id ?? '')
  const [data, setData] = useState<Availability | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState('')
  useEscapeClose(close)

  const check = useCallback(async () => {
    if (!warehouseId) return
    setLoading(true)
    setError('')
    try {
      const response = await fetch(`/api/master/bundles/${bundle.id}/availability?warehouseId=${encodeURIComponent(warehouseId)}`, { headers: authHeaders(session) })
      const payload = (await response.json()) as { data?: Availability; error?: string }
      if (!response.ok) throw new Error(friendlyError(payload.error))
      setData(payload.data ?? null)
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Gagal menghitung ketersediaan.')
    } finally {
      setLoading(false)
    }
  }, [bundle.id, session, warehouseId])

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- availability follows the selected warehouse
    void check()
  }, [check])

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-slate-950/60 p-3 backdrop-blur-sm">
      <div className="max-h-[90vh] w-full max-w-3xl overflow-y-auto rounded-3xl bg-white p-6 shadow-2xl">
        <div className="flex items-start justify-between"><div><h2 className="text-xl font-black">Ketersediaan {bundle.name}</h2><p className="text-sm text-slate-500">Dihitung dari komponen yang paling membatasi.</p></div><button onClick={close} className="rounded-xl p-2 hover:bg-slate-100"><X className="h-5 w-5" /></button></div>
        <div className="mt-5 flex gap-3"><select value={warehouseId} onChange={(event) => setWarehouseId(event.target.value)} className="input flex-1">{activeWarehouses.map((warehouse) => <option key={warehouse.id} value={warehouse.id}>{warehouse.name}</option>)}</select><button onClick={check} className="rounded-xl bg-blue-600 px-4 font-bold text-white">Hitung</button></div>
        {loading && <div className="flex justify-center p-10"><Loader2 className="h-7 w-7 animate-spin text-blue-600" /></div>}
        {error && <div className="mt-4 rounded-2xl bg-rose-50 p-4 text-sm font-semibold text-rose-700">{error}</div>}
        {!loading && data && (
          <>
            <div className="my-5 rounded-3xl bg-emerald-50 p-6 text-center"><p className="text-sm font-bold text-emerald-700">Bundle siap dijual</p><p className="text-4xl font-black text-emerald-950">{qty(data.availableQuantity)}</p></div>
            <div className="space-y-2">{data.components.map((row) => <div key={`${row.componentProductId}:${row.componentUomId}`} className="flex items-center justify-between rounded-2xl border border-slate-200 p-4"><div><p className="font-bold">{row.componentName}</p><p className="text-xs text-slate-500">Butuh {qty(row.quantityPerBundle)} {row.componentUomName} per Bundle · stok base {qty(row.onHandBaseQty)}</p></div><span className="font-black text-slate-800">kapasitas {qty(row.capacity)}</span></div>)}</div>
          </>
        )}
      </div>
    </div>
  )
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return <label className="block"><span className="mb-1.5 block text-sm font-bold text-slate-700">{label}</span>{children}</label>
}
