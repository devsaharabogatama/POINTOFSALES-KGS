'use client'

import { useCallback, useEffect, useMemo, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import {
  AlertTriangle,
  Boxes,
  RefreshCcw,
  Search,
  Warehouse as WarehouseIcon,
} from 'lucide-react'

type ProductUom = {
  uom_id: string
  factor_to_base: number | string
  is_active: boolean
  uom: {
    id: string
    name: string
    is_active: boolean
  } | null
}

type Product = {
  id: string
  sku: string
  name: string
  category: { category_name: string } | null
  uom_id: string
  is_bundle: boolean
  is_active: boolean
  product_uoms: ProductUom[] | null
}

type Warehouse = {
  id: string
  name: string
  warehouse_type: string | null
  location: string | null
  is_active: boolean
}

type Balance = {
  id: string
  product_id: string
  warehouse_id: string
  stock_qty: number | string
  updated_at: string
  fifo_value: number | string
  minimum_stock_base_qty: number | string | null
  low_stock_alert_enabled: boolean
  last_movement_type: string | null
  last_movement_at: string | null
}

type OverviewPayload = {
  balances?: Balance[]
  warehouses?: Warehouse[]
  error?: string
}

function authHeaders(session: Session) {
  return { Authorization: `Bearer ${session.access_token}` }
}

function qty(value: number) {
  return value.toLocaleString('id-ID', { maximumFractionDigits: 6 })
}

function rupiah(value: number) {
  return new Intl.NumberFormat('id-ID', {
    style: 'currency',
    currency: 'IDR',
    maximumFractionDigits: 0,
  }).format(value)
}

function baseUomName(product?: Product) {
  if (!product) return ''
  return (product.product_uoms ?? []).find(
    (row) =>
      row.uom_id === product.uom_id &&
      Number(row.factor_to_base) === 1 &&
      row.is_active &&
      row.uom?.is_active,
  )?.uom?.name ?? ''
}

export function StockRealView({
  session,
  companyId,
}: {
  session: Session
  companyId: string
}) {
  const [products, setProducts] = useState<Product[]>([])
  const [overview, setOverview] = useState<OverviewPayload>({})
  const [query, setQuery] = useState('')
  const [warehouseId, setWarehouseId] = useState('')
  const [onlyLow, setOnlyLow] = useState(false)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')

  const load = useCallback(async () => {
    const responses = await Promise.all([
      fetch('/api/master/product-references?includeInactive=true', {
        headers: authHeaders(session),
      }),
      fetch('/api/inventory/stock-overview', {
        headers: authHeaders(session),
      }),
    ])
    const payloads = await Promise.all(responses.map((response) => response.json()))
    const failed = responses.findIndex((response) => !response.ok)
    if (failed >= 0) {
      throw new Error(
        (payloads[failed] as { error?: string }).error ??
          'Gagal memuat Stock Real.',
      )
    }
    setProducts((payloads[0] as { data?: Product[] }).data ?? [])
    setOverview(payloads[1] as OverviewPayload)
  }, [session])

  const refresh = useCallback(async () => {
    setLoading(true)
    setError('')
    try {
      await load()
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Gagal memuat Stock Real.')
    } finally {
      setLoading(false)
    }
  }, [load])

  useEffect(() => {
    let cancelled = false
    // eslint-disable-next-line react-hooks/set-state-in-effect -- tenant data follows active Company
    load()
      .catch((caught) => {
        if (!cancelled) {
          setError(caught instanceof Error ? caught.message : 'Gagal memuat Stock Real.')
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
    () => new Map((overview.warehouses ?? []).map((warehouse) => [warehouse.id, warehouse])),
    [overview.warehouses],
  )
  const normalized = query.trim().toLocaleLowerCase('id-ID')
  const rows = (overview.balances ?? [])
    .map((balance) => {
      const key = `${balance.product_id}:${balance.warehouse_id}`
      const product = productById.get(balance.product_id)
      const warehouse = warehouseById.get(balance.warehouse_id)
      const onHand = Number(balance.stock_qty) || 0
      const minimum =
        balance.minimum_stock_base_qty === null ||
        balance.minimum_stock_base_qty === undefined
          ? null
          : Number(balance.minimum_stock_base_qty)
      const isLow =
        Boolean(balance.low_stock_alert_enabled) &&
        minimum !== null &&
        onHand <= minimum
      return {
        key,
        product,
        warehouse,
        onHand,
        minimum,
        isLow,
        valuation: Number(balance.fifo_value) || 0,
        lastMovementType: balance.last_movement_type,
        lastMovementAt: balance.last_movement_at,
      }
    })
    .filter((row) => {
      if (warehouseId && row.warehouse?.id !== warehouseId) return false
      if (onlyLow && !row.isLow) return false
      if (!normalized) return true
      return [
        row.product?.sku ?? '',
        row.product?.name ?? '',
        row.product?.category?.category_name ?? '',
        row.warehouse?.name ?? '',
      ].some((value) => value.toLocaleLowerCase('id-ID').includes(normalized))
    })

  const lowCount = (overview.balances ?? []).filter((balance) => {
    return (
      balance.low_stock_alert_enabled &&
      balance.minimum_stock_base_qty !== null &&
      Number(balance.stock_qty) <= Number(balance.minimum_stock_base_qty)
    )
  }).length
  const totalValuation = (overview.balances ?? []).reduce(
    (total, balance) => total + Number(balance.fifo_value),
    0,
  )

  return (
    <>
      <div className="mb-7 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <p className="text-xs font-bold uppercase tracking-[.16em] text-emerald-600">
            Inventory read model
          </p>
          <h1 className="mt-2 text-2xl font-black tracking-tight text-slate-950 md:text-3xl">
            Stock Real / Saat Ini
          </h1>
          <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-500">
            Saldo materialized per Product dan Gudang. Semua quantity disimpan
            dalam Base UOM dan hanya berubah melalui dokumen stok yang diposting.
          </p>
        </div>
        <button
          onClick={() => void refresh()}
          className="inline-flex items-center gap-2 rounded-xl border border-slate-200 bg-white px-4 py-3 text-sm font-bold text-slate-600"
        >
          <RefreshCcw className={`h-4 w-4 ${loading ? 'animate-spin' : ''}`} />
          Muat ulang
        </button>
      </div>

      {error && (
        <div className="mb-5 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-700">
          {error}
        </div>
      )}

      <div className="mb-5 grid gap-4 md:grid-cols-3">
        <Summary
          icon={Boxes}
          label="Pasangan dengan saldo"
          value={String((overview.balances ?? []).length)}
        />
        <Summary
          icon={AlertTriangle}
          label="Di bawah minimum"
          value={String(lowCount)}
          warning={lowCount > 0}
        />
        <Summary
          icon={WarehouseIcon}
          label="Nilai persediaan FIFO"
          value={rupiah(totalValuation)}
        />
      </div>

      <div className="rounded-2xl border border-slate-200 bg-white shadow-sm">
        <div className="grid gap-3 border-b border-slate-100 p-4 md:grid-cols-[1fr_240px_auto]">
          <label className="flex items-center gap-3 rounded-xl border border-slate-200 px-4">
            <Search className="h-4 w-4 text-slate-400" />
            <input
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              placeholder="Cari Product, SKU, kategori, atau Gudang..."
              className="w-full bg-transparent py-3 text-sm outline-none"
            />
          </label>
          <select
            value={warehouseId}
            onChange={(event) => setWarehouseId(event.target.value)}
            className="rounded-xl border border-slate-200 bg-white px-4 py-3 text-sm font-semibold text-slate-700"
          >
            <option value="">Semua Gudang</option>
            {(overview.warehouses ?? []).map((warehouse) => (
              <option key={warehouse.id} value={warehouse.id}>{warehouse.name}</option>
            ))}
          </select>
          <label className="flex items-center gap-2 rounded-xl border border-slate-200 px-4 py-3 text-sm font-bold text-slate-700">
            <input
              type="checkbox"
              checked={onlyLow}
              onChange={(event) => setOnlyLow(event.target.checked)}
              className="h-4 w-4 accent-rose-500"
            />
            Hanya stok menipis
          </label>
        </div>
        <div className="overflow-x-auto">
          <table className="w-full min-w-[1250px] text-left text-sm">
            <thead className="bg-slate-50 text-xs uppercase tracking-wider text-slate-500">
              <tr>
                <th className="px-5 py-4">Product</th>
                <th className="px-5 py-4">Gudang</th>
                <th className="px-5 py-4">On Hand</th>
                <th className="px-5 py-4">Reserved</th>
                <th className="px-5 py-4">Available</th>
                <th className="px-5 py-4">Minimum</th>
                <th className="px-5 py-4">Nilai FIFO</th>
                <th className="px-5 py-4">Movement terakhir</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {rows.map((row) => {
                const uom = baseUomName(row.product)
                return (
                  <tr key={row.key} className={row.isLow ? 'bg-rose-50/45' : ''}>
                    <td className="px-5 py-4">
                      <p className="font-black text-slate-900">{row.product?.name ?? 'Product tidak ditemukan'}</p>
                      <p className="mt-1 text-xs text-slate-400">{row.product?.sku ?? '-'}</p>
                    </td>
                    <td className="px-5 py-4">
                      <p className="font-bold text-slate-700">{row.warehouse?.name ?? 'Gudang tidak ditemukan'}</p>
                      <p className="mt-1 text-xs text-slate-400">{row.warehouse?.location ?? row.warehouse?.warehouse_type ?? '-'}</p>
                    </td>
                    <td className="px-5 py-4 font-black text-slate-900">{qty(row.onHand)} {uom}</td>
                    <td className="px-5 py-4"><span className="rounded-full bg-slate-100 px-2.5 py-1 text-xs font-bold text-slate-500">Belum aktif</span></td>
                    <td className="px-5 py-4 font-black text-slate-900">{qty(row.onHand)} {uom}</td>
                    <td className="px-5 py-4">
                      {row.minimum === null
                        ? <span className="text-slate-400">Belum diatur</span>
                        : <span className={row.isLow ? 'font-black text-rose-700' : 'font-bold text-slate-700'}>{qty(row.minimum)} {uom}{row.isLow ? ' · Menipis' : ''}</span>}
                    </td>
                    <td className="px-5 py-4 font-bold text-slate-700">{rupiah(row.valuation)}</td>
                    <td className="px-5 py-4">
                      {row.lastMovementType && row.lastMovementAt
                        ? <>
                            <p className="font-bold text-slate-700">{row.lastMovementType}</p>
                            <p className="mt-1 text-xs text-slate-400">{new Date(row.lastMovementAt).toLocaleString('id-ID')}</p>
                          </>
                        : <span className="text-slate-400">Belum ada movement</span>}
                    </td>
                  </tr>
                )
              })}
              {!loading && !rows.length && (
                <tr>
                  <td colSpan={8} className="p-12 text-center text-sm text-slate-400">
                    Tidak ada saldo yang sesuai filter. Product tanpa dokumen stok
                    posted belum memiliki baris Stock Real.
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
      <p className="mt-4 text-xs leading-5 text-slate-500">
        Reserved belum diaktifkan sampai kontrak order/reservation G4 tersedia.
        Karena itu Available saat ini sama dengan On Hand. Detail ledger akan
        tersedia pada langkah roadmap berikutnya: Stock Movement / Kartu Stok.
      </p>
    </>
  )
}

function Summary({
  icon: Icon,
  label,
  value,
  warning = false,
}: {
  icon: typeof Boxes
  label: string
  value: string
  warning?: boolean
}) {
  return (
    <div className={`rounded-2xl border bg-white p-5 shadow-sm ${
      warning ? 'border-rose-200' : 'border-slate-200'
    }`}>
      <div className="flex items-center gap-3">
        <span className={`grid h-10 w-10 place-items-center rounded-xl ${
          warning ? 'bg-rose-50 text-rose-600' : 'bg-emerald-50 text-emerald-600'
        }`}>
          <Icon className="h-5 w-5" />
        </span>
        <div>
          <p className="text-xs font-bold uppercase tracking-wider text-slate-400">{label}</p>
          <p className={`mt-1 text-xl font-black ${warning ? 'text-rose-700' : 'text-slate-900'}`}>{value}</p>
        </div>
      </div>
    </div>
  )
}
