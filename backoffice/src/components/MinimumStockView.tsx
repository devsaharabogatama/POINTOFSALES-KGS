'use client'

import { useCallback, useEffect, useMemo, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import {
  BellRing,
  Edit3,
  Loader2,
  Plus,
  RefreshCcw,
  Search,
  X,
} from 'lucide-react'
import { useEscapeClose } from '@/lib/use-escape-close'

type ProductUom = {
  uom_id: string
  factor_to_base: number | string
  is_active: boolean
  uom: {
    id: string
    name: string
    allow_decimal: boolean
    decimal_precision: number
    is_active: boolean
  } | null
}

type Product = {
  id: string
  sku: string
  name: string
  uom_id: string
  is_bundle: boolean
  is_active: boolean
  product_uoms: ProductUom[] | null
}

type WarehouseRow = {
  id: string
  name: string
  warehouse_type: string | null
  location: string | null
  is_active: boolean
}

type MinimumStockSetting = {
  id: string
  product_id: string
  warehouse_id: string
  minimum_stock_base_qty: number | string | null
  low_stock_alert_enabled: boolean
  master_version: number
}

type StockBalance = {
  product_id: string
  warehouse_id: string
  stock_qty: number | string
}

type StockOverview = {
  balances?: StockBalance[]
  error?: string
}

type ApiList<T> = { data?: T[]; error?: string }

function authHeaders(session: Session) {
  return { Authorization: `Bearer ${session.access_token}` }
}

function friendlyError(code?: string) {
  const messages: Record<string, string> = {
    INVENTORY_CONFIGURATION_MANAGER_REQUIRED:
      'Role Anda tidak diizinkan mengatur Minimum Stock.',
    MINIMUM_STOCK_VALUE_INVALID: 'Minimum Stock harus berupa angka positif.',
    MINIMUM_STOCK_TOO_LARGE: 'Nilai Minimum Stock terlalu besar.',
    MINIMUM_STOCK_REQUIRED_WHEN_ALERT_ENABLED:
      'Isi Minimum Stock sebelum mengaktifkan notifikasi.',
    MINIMUM_STOCK_BASE_UOM_REQUIRES_INTEGER:
      'Base UOM Product ini hanya menerima quantity bilangan bulat.',
    MINIMUM_STOCK_BASE_UOM_PRECISION_EXCEEDED:
      'Jumlah desimal melebihi presisi Base UOM Product.',
    ACTIVE_STOCK_PRODUCT_WITH_BASE_UOM_NOT_FOUND:
      'Product stok atau Base UOM sudah tidak aktif.',
    ACTIVE_WAREHOUSE_NOT_FOUND: 'Gudang sudah tidak aktif.',
    PRODUCT_WAREHOUSE_STOCK_SETTING_ALREADY_EXISTS:
      'Product dan Gudang tersebut sudah memiliki pengaturan.',
    MASTER_VERSION_CONFLICT:
      'Data sudah berubah di tab lain. Muat ulang lalu edit kembali.',
    FORBIDDEN: 'Role Anda tidak diizinkan mengakses Minimum Stock.',
  }
  return messages[code ?? ''] ?? code ?? 'Operasi Minimum Stock gagal.'
}

export function MinimumStockView({
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
  const [products, setProducts] = useState<Product[]>([])
  const [warehouses, setWarehouses] = useState<WarehouseRow[]>([])
  const [settings, setSettings] = useState<MinimumStockSetting[]>([])
  const [balances, setBalances] = useState<StockBalance[]>([])
  const [query, setQuery] = useState('')
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [editing, setEditing] = useState<MinimumStockSetting | 'create' | null>(null)

  const load = useCallback(async () => {
    const paths = [
      '/api/master/products?includeInactive=true',
      '/api/master/warehouses?includeInactive=true',
      '/api/master/minimum-stock',
      '/api/inventory/stock-overview',
    ]
    const responses = await Promise.all(
      paths.map((path) => fetch(path, { headers: authHeaders(session) })),
    )
    const payloads = (await Promise.all(responses.map((response) => response.json()))) as [
      ApiList<Product>,
      ApiList<WarehouseRow>,
      ApiList<MinimumStockSetting>,
      StockOverview,
    ]
    const failed = responses.findIndex((response) => !response.ok)
    if (failed >= 0) throw new Error(friendlyError(payloads[failed].error))
    setProducts(payloads[0].data ?? [])
    setWarehouses(payloads[1].data ?? [])
    setSettings(payloads[2].data ?? [])
    setBalances(payloads[3].balances ?? [])
  }, [session])

  const refresh = useCallback(async () => {
    setLoading(true)
    setError('')
    try {
      await load()
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Gagal memuat Minimum Stock.')
    } finally {
      setLoading(false)
    }
  }, [load])

  useEffect(() => {
    let cancelled = false
    // eslint-disable-next-line react-hooks/set-state-in-effect -- tenant data follows the active Company prop
    load()
      .catch((caught) => {
        if (!cancelled) {
          setError(caught instanceof Error ? caught.message : 'Gagal memuat Minimum Stock.')
        }
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
  const warehouseById = useMemo(
    () => new Map(warehouses.map((warehouse) => [warehouse.id, warehouse])),
    [warehouses],
  )
  const baseUom = useCallback((product?: Product) => {
    if (!product) return null
    return (product.product_uoms ?? []).find((row) =>
      row.is_active &&
      row.uom?.is_active &&
      row.uom_id === product.uom_id &&
      Number(row.factor_to_base) === 1,
    )?.uom ?? null
  }, [])
  const eligibleProducts = products.filter((product) =>
    product.is_active && !product.is_bundle && Boolean(baseUom(product)))
  const configuredPairs = new Set(
    settings.map((setting) => `${setting.product_id}:${setting.warehouse_id}`),
  )
  const balanceByPair = useMemo(
    () =>
      new Map(
        balances.map((balance) => [
          `${balance.product_id}:${balance.warehouse_id}`,
          Number(balance.stock_qty) || 0,
        ]),
      ),
    [balances],
  )
  const alertCount = settings.filter((setting) => {
    if (
      !setting.low_stock_alert_enabled ||
      setting.minimum_stock_base_qty === null
    ) return false
    const actual = balanceByPair.get(
      `${setting.product_id}:${setting.warehouse_id}`,
    ) ?? 0
    return actual <= Number(setting.minimum_stock_base_qty)
  }).length
  const hasAvailablePair = eligibleProducts.some((product) =>
    warehouses.some((warehouse) =>
      warehouse.is_active &&
      !configuredPairs.has(`${product.id}:${warehouse.id}`),
    ),
  )
  const normalized = query.trim().toLocaleLowerCase('id-ID')
  const filtered = settings.filter((setting) => {
    const product = productById.get(setting.product_id)
    const warehouse = warehouseById.get(setting.warehouse_id)
    return !normalized || [
      product?.name ?? '',
      product?.sku ?? '',
      warehouse?.name ?? '',
    ].some((value) => value.toLocaleLowerCase('id-ID').includes(normalized))
  })

  return (
    <>
      <div className="mb-7 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <p className="text-xs font-bold uppercase tracking-[.16em] text-emerald-600">
            Inventory control
          </p>
          <h1 className="mt-2 text-2xl font-black tracking-tight text-slate-950 md:text-3xl">
            Minimum Stock per Gudang
          </h1>
          <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-500">
            Atur batas stok menipis dalam Base UOM untuk setiap pasangan Product
            dan Gudang. Pengaturan ini hanya memicu notifikasi dan tidak membuat
            stok, request, atau order otomatis.
          </p>
        </div>
        <div className="flex gap-2">
          <button
            onClick={() => void refresh()}
            className="inline-flex items-center gap-2 rounded-xl border border-slate-200 bg-white px-4 py-3 text-sm font-bold text-slate-600"
          >
            <RefreshCcw className={`h-4 w-4 ${loading ? 'animate-spin' : ''}`} />
            Muat ulang
          </button>
          {canManage && (
            <button
              disabled={!hasAvailablePair}
              onClick={() => setEditing('create')}
              className="inline-flex items-center gap-2 rounded-xl bg-emerald-500 px-4 py-3 text-sm font-bold text-white disabled:cursor-not-allowed disabled:opacity-50"
            >
              <Plus className="h-4 w-4" /> Tambah pengaturan
            </button>
          )}
        </div>
      </div>

      {error && (
        <div className="mb-5 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-700">
          {error}
        </div>
      )}
      {!loading && alertCount > 0 && (
        <div className="mb-5 flex items-start gap-3 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-800">
          <BellRing className="mt-0.5 h-5 w-5 shrink-0" />
          <div>
            <p className="font-black">
              Preview konfigurasi: {alertCount} saldo berada di bawah atau sama dengan batas minimum.
            </p>
            <p className="mt-1 leading-6">
              Baris ditandai merah agar threshold mudah diverifikasi. Monitoring
              harian berada di Stock Real; notice Cashier dan inbox baru dibuka pada G4.
            </p>
          </div>
        </div>
      )}
      {!hasAvailablePair && canManage && !loading && (
        <div className="mb-5 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-800">
          Semua pasangan Product stok dan Gudang aktif sudah dikonfigurasi, atau
          belum ada Product dengan Base UOM yang valid.
        </div>
      )}

      <div className="rounded-2xl border border-slate-200 bg-white shadow-sm">
        <div className="flex items-center gap-3 border-b border-slate-100 p-4">
          <Search className="h-4 w-4 text-slate-400" />
          <input
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder="Cari Product, SKU, atau nama Gudang..."
            className="w-full bg-transparent text-sm outline-none"
          />
        </div>
        <div className="overflow-x-auto">
          <table className="w-full min-w-[1000px] text-left text-sm">
            <thead className="bg-slate-50 text-xs uppercase tracking-wider text-slate-500">
              <tr>
                <th className="px-5 py-4">Product</th>
                <th className="px-5 py-4">Gudang</th>
                <th className="px-5 py-4">Minimum Stock</th>
                <th className="px-5 py-4">Stok Aktual</th>
                <th className="px-5 py-4">Kondisi</th>
                <th className="px-5 py-4">Notifikasi</th>
                {canManage && <th className="px-5 py-4 text-right">Aksi</th>}
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {filtered.map((setting) => {
                const product = productById.get(setting.product_id)
                const warehouse = warehouseById.get(setting.warehouse_id)
                const uom = baseUom(product)
                const actual = balanceByPair.get(
                  `${setting.product_id}:${setting.warehouse_id}`,
                ) ?? 0
                const minimum =
                  setting.minimum_stock_base_qty === null
                    ? null
                    : Number(setting.minimum_stock_base_qty)
                const isLow =
                  setting.low_stock_alert_enabled &&
                  minimum !== null &&
                  actual <= minimum
                return (
                  <tr key={setting.id} className={isLow ? 'bg-rose-50/45' : ''}>
                    <td className="px-5 py-4">
                      <p className="font-bold text-slate-900">{product?.name ?? 'Product tidak ditemukan'}</p>
                      <p className="mt-1 text-xs text-slate-400">{product?.sku ?? '-'}</p>
                    </td>
                    <td className="px-5 py-4">
                      <p className="font-semibold text-slate-700">{warehouse?.name ?? 'Gudang tidak ditemukan'}</p>
                      <p className="mt-1 text-xs text-slate-400">{warehouse?.location ?? warehouse?.warehouse_type ?? '-'}</p>
                    </td>
                    <td className="px-5 py-4 font-bold text-slate-800">
                      {setting.minimum_stock_base_qty ?? 'Belum diisi'} {setting.minimum_stock_base_qty !== null ? uom?.name ?? '' : ''}
                    </td>
                    <td className="px-5 py-4 font-black text-slate-900">
                      {actual.toLocaleString('id-ID', { maximumFractionDigits: 6 })} {uom?.name ?? ''}
                    </td>
                    <td className="px-5 py-4">
                      <span className={`inline-flex rounded-full px-2.5 py-1 text-xs font-black ${
                        isLow
                          ? 'bg-rose-100 text-rose-700'
                          : minimum === null
                            ? 'bg-slate-100 text-slate-500'
                            : 'bg-emerald-50 text-emerald-700'
                      }`}>
                        {isLow ? 'Stok menipis' : minimum === null ? 'Belum dinilai' : 'Aman'}
                      </span>
                    </td>
                    <td className="px-5 py-4">
                      <span className={`inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-bold ${setting.low_stock_alert_enabled ? 'bg-emerald-50 text-emerald-700' : 'bg-slate-100 text-slate-500'}`}>
                        <BellRing className="h-3.5 w-3.5" />
                        {setting.low_stock_alert_enabled ? 'Aktif' : 'Nonaktif'}
                      </span>
                    </td>
                    {canManage && (
                      <td className="px-5 py-4 text-right">
                        <button
                          disabled={!product?.is_active || !warehouse?.is_active || !uom}
                          onClick={() => setEditing(setting)}
                          title={!product?.is_active || !warehouse?.is_active || !uom ? 'Aktifkan kembali Product, Gudang, dan Base UOM untuk mengubah pengaturan ini.' : 'Edit Minimum Stock'}
                          className="inline-flex items-center gap-2 rounded-lg border border-slate-200 px-3 py-2 text-xs font-bold text-slate-600 hover:border-emerald-200 hover:text-emerald-700 disabled:cursor-not-allowed disabled:opacity-40"
                        >
                          <Edit3 className="h-3.5 w-3.5" /> Edit
                        </button>
                      </td>
                    )}
                  </tr>
                )
              })}
              {!loading && !filtered.length && (
                <tr>
                  <td colSpan={canManage ? 7 : 6} className="p-12 text-center text-sm text-slate-400">
                    Belum ada pengaturan Minimum Stock.
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </div>

      {editing && (
        <MinimumStockEditor
          session={session}
          products={eligibleProducts}
          warehouses={warehouses.filter((warehouse) => warehouse.is_active)}
          configuredPairs={configuredPairs}
          record={editing === 'create' ? undefined : editing}
          close={() => setEditing(null)}
          complete={async () => {
            setEditing(null)
            notify('Pengaturan Minimum Stock berhasil disimpan.')
            await refresh()
          }}
        />
      )}
    </>
  )
}

function MinimumStockEditor({
  session,
  products,
  warehouses,
  configuredPairs,
  record,
  close,
  complete,
}: {
  session: Session
  products: Product[]
  warehouses: WarehouseRow[]
  configuredPairs: Set<string>
  record?: MinimumStockSetting
  close: () => void
  complete: () => Promise<void>
}) {
  useEscapeClose(close)
  const firstPair = (() => {
    for (const product of products) {
      const warehouse = warehouses.find((candidate) =>
        !configuredPairs.has(`${product.id}:${candidate.id}`),
      )
      if (warehouse) return { productId: product.id, warehouseId: warehouse.id }
    }
    return { productId: '', warehouseId: '' }
  })()
  const [productId, setProductId] = useState(record?.product_id ?? firstPair.productId)
  const availableWarehouses = warehouses.filter((warehouse) =>
    record
      ? warehouse.id === record.warehouse_id
      : !configuredPairs.has(`${productId}:${warehouse.id}`),
  )
  const initialWarehouse = record?.warehouse_id ??
    (availableWarehouses.some((warehouse) => warehouse.id === firstPair.warehouseId)
      ? firstPair.warehouseId
      : availableWarehouses[0]?.id ?? '')
  const [warehouseId, setWarehouseId] = useState(initialWarehouse)
  const [minimumQty, setMinimumQty] = useState(
    record?.minimum_stock_base_qty === null ||
    record?.minimum_stock_base_qty === undefined
      ? ''
      : String(record.minimum_stock_base_qty),
  )
  const [alertEnabled, setAlertEnabled] = useState(
    record?.low_stock_alert_enabled ?? true,
  )
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')
  const product = products.find((item) => item.id === productId)
  const base = product
    ? (product.product_uoms ?? []).find((row) =>
        row.uom_id === product.uom_id && Number(row.factor_to_base) === 1,
      )?.uom
    : null

  async function submit(event: React.FormEvent) {
    event.preventDefault()
    setSaving(true)
    setError('')
    try {
      const response = await fetch(
        record ? `/api/master/minimum-stock/${record.id}` : '/api/master/minimum-stock',
        {
          method: record ? 'PATCH' : 'POST',
          headers: { 'Content-Type': 'application/json', ...authHeaders(session) },
          body: JSON.stringify({
            masterVersion: record?.master_version,
            productId,
            warehouseId,
            minimumStockBaseQty: minimumQty || null,
            lowStockAlertEnabled: alertEnabled,
          }),
        },
      )
      const payload = (await response.json()) as { error?: string }
      if (!response.ok) throw new Error(friendlyError(payload.error))
      await complete()
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Gagal menyimpan Minimum Stock.')
    } finally {
      setSaving(false)
    }
  }

  return (
    <div className="fixed inset-0 z-[70] grid place-items-center bg-slate-950/45 p-4 backdrop-blur-sm">
      <div className="max-h-[92vh] w-full max-w-2xl overflow-y-auto rounded-3xl bg-white p-6 shadow-2xl sm:p-8">
        <div className="flex items-start justify-between gap-4">
          <div>
            <h2 className="text-xl font-black text-slate-950">
              {record ? 'Edit Minimum Stock' : 'Tambah Minimum Stock'}
            </h2>
            <p className="mt-2 text-sm leading-6 text-slate-500">
              Quantity selalu disimpan dalam Base UOM Product. Product dan Gudang
              tidak dapat diganti setelah pengaturan dibuat.
            </p>
          </div>
          <button onClick={close} className="rounded-xl bg-slate-100 p-2 text-slate-500" aria-label="Tutup">
            <X className="h-4 w-4" />
          </button>
        </div>
        <form onSubmit={submit} className="mt-7 space-y-5">
          <label className="block text-sm font-bold text-slate-700">
            Product
            <select
              required
              disabled={Boolean(record)}
              value={productId}
              onChange={(event) => {
                const nextProductId = event.target.value
                setProductId(nextProductId)
                const firstWarehouse = warehouses.find((warehouse) =>
                  !configuredPairs.has(`${nextProductId}:${warehouse.id}`),
                )
                setWarehouseId(firstWarehouse?.id ?? '')
              }}
              className="mt-2 w-full rounded-xl border border-slate-200 bg-white px-4 py-3 disabled:bg-slate-100"
            >
              {products.map((item) => (
                <option key={item.id} value={item.id}>{item.name} ({item.sku})</option>
              ))}
            </select>
          </label>
          <label className="block text-sm font-bold text-slate-700">
            Gudang
            <select
              required
              disabled={Boolean(record)}
              value={warehouseId}
              onChange={(event) => setWarehouseId(event.target.value)}
              className="mt-2 w-full rounded-xl border border-slate-200 bg-white px-4 py-3 disabled:bg-slate-100"
            >
              {availableWarehouses.map((warehouse) => (
                <option key={warehouse.id} value={warehouse.id}>{warehouse.name}</option>
              ))}
            </select>
          </label>
          <label className="block text-sm font-bold text-slate-700">
            Minimum Stock ({base?.name ?? 'Base UOM'})
            <input
              type="number"
              min="0"
              step={base?.allow_decimal ? 10 ** -(base.decimal_precision || 1) : 1}
              required={alertEnabled}
              value={minimumQty}
              onChange={(event) => setMinimumQty(event.target.value)}
              placeholder="Contoh: 10"
              className="mt-2 w-full rounded-xl border border-slate-200 px-4 py-3 outline-none focus:border-emerald-500"
            />
            <span className="mt-2 block text-xs font-normal text-slate-500">
              Notifikasi muncul ketika stok Gudang berada di atau di bawah batas ini.
            </span>
          </label>
          <label className="flex items-start gap-3 rounded-2xl border border-slate-200 p-4">
            <input
              type="checkbox"
              checked={alertEnabled}
              onChange={(event) => setAlertEnabled(event.target.checked)}
              className="mt-0.5 h-4 w-4 accent-emerald-500"
            />
            <span>
              <span className="block text-sm font-bold text-slate-800">Aktifkan notifikasi stok menipis</span>
              <span className="mt-1 block text-xs leading-5 text-slate-500">Tidak membuat Stock Request atau Supplier Order otomatis.</span>
            </span>
          </label>
          {error && <div className="rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-700">{error}</div>}
          <div className="flex justify-end gap-3 border-t border-slate-100 pt-5">
            <button type="button" onClick={close} className="rounded-xl border border-slate-200 px-4 py-2.5 text-sm font-bold text-slate-600">Batal</button>
            <button disabled={saving || !productId || !warehouseId} className="inline-flex items-center gap-2 rounded-xl bg-emerald-500 px-5 py-2.5 text-sm font-bold text-white disabled:opacity-50">
              {saving && <Loader2 className="h-4 w-4 animate-spin" />}
              Simpan pengaturan
            </button>
          </div>
        </form>
      </div>
    </div>
  )
}
