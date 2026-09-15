'use client'

import { Fragment, useCallback, useEffect, useMemo, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import {
  AlertTriangle,
  Boxes,
  ChevronDown,
  ChevronUp,
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
  id: string | null
  product_id: string
  warehouse_id: string
  stock_qty: number | string
  reserved_out_base_qty: number | string
  pos_reserved_out_base_qty?: number | string
  backoffice_reserved_out_base_qty?: number | string
  available_to_sell_base_qty: number | string
  updated_at: string
  fifo_value: number | string
  minimum_stock_base_qty: number | string | null
  low_stock_alert_enabled: boolean
  last_movement_type: string | null
  last_movement_at: string | null
}

type ReservationAllocation = {
  source: 'POS' | 'BACKOFFICE'
  reservation_line_id: string
  product_id: string
  warehouse_id: string
  sales_order_no: string
  customer_code: string
  customer_name: string
  reservation_status: string
  reserved_out_base_qty: number | string
  shortage_base_qty: number | string
  scheduled_date: string | null
  delivery_orders: Array<{
    id: string
    deliveryNo: string
    status: string
    kind?: string
  }>
}

type OverviewPayload = {
  reservationReadModelVersion?: number
  balances?: Balance[]
  reservationAllocations?: ReservationAllocation[]
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
  const [expandedPair, setExpandedPair] = useState('')
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
    const stockPayload = payloads[1] as OverviewPayload
    if (!stockPayload.reservationReadModelVersion) {
      throw new Error(
        'Read model Reserved Out belum tersedia. Jalankan migration ODR-6B.1 terlebih dahulu.',
      )
    }
    setProducts((payloads[0] as { data?: Product[] }).data ?? [])
    setOverview(stockPayload)
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
    // eslint-disable-next-line react-hooks/set-state-in-effect -- load owns the initial async state update
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
  const allocationsByPair = useMemo(() => {
    const grouped = new Map<string, ReservationAllocation[]>()
    for (const allocation of overview.reservationAllocations ?? []) {
      const key = `${allocation.product_id}:${allocation.warehouse_id}`
      grouped.set(key, [...(grouped.get(key) ?? []), allocation])
    }
    return grouped
  }, [overview.reservationAllocations])
  const normalized = query.trim().toLocaleLowerCase('id-ID')
  const rows = (overview.balances ?? [])
    .map((balance) => {
      const key = `${balance.product_id}:${balance.warehouse_id}`
      const product = productById.get(balance.product_id)
      const warehouse = warehouseById.get(balance.warehouse_id)
      const onHand = Number(balance.stock_qty) || 0
      const reserved = Number(balance.reserved_out_base_qty) || 0
      const posReserved = Number(balance.pos_reserved_out_base_qty) || 0
      const backofficeReserved =
        Number(balance.backoffice_reserved_out_base_qty) || 0
      const available = Number(balance.available_to_sell_base_qty) || 0
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
        reserved,
        posReserved,
        backofficeReserved,
        allocations: allocationsByPair.get(key) ?? [],
        available,
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
                  <Fragment key={row.key}>
                    <tr className={row.isLow ? 'bg-rose-50/45' : ''}>
                    <td className="px-5 py-4">
                      <p className="font-black text-slate-900">{row.product?.name ?? 'Product tidak ditemukan'}</p>
                      <p className="mt-1 text-xs text-slate-400">{row.product?.sku ?? '-'}</p>
                    </td>
                    <td className="px-5 py-4">
                      <p className="font-bold text-slate-700">{row.warehouse?.name ?? 'Gudang tidak ditemukan'}</p>
                      <p className="mt-1 text-xs text-slate-400">{row.warehouse?.location ?? row.warehouse?.warehouse_type ?? '-'}</p>
                    </td>
                    <td className="px-5 py-4 font-black text-slate-900">{qty(row.onHand)} {uom}</td>
                    <td className="px-5 py-4">
                      {row.reserved > 0 ? (
                        <button
                          type="button"
                          onClick={() => setExpandedPair((current) =>
                            current === row.key ? '' : row.key)}
                          className="inline-flex items-center gap-2 rounded-full bg-amber-100 px-2.5 py-1 text-xs font-black text-amber-800"
                          aria-expanded={expandedPair === row.key}
                        >
                          {qty(row.reserved)} {uom}
                          {expandedPair === row.key
                            ? <ChevronUp className="h-3.5 w-3.5" />
                            : <ChevronDown className="h-3.5 w-3.5" />}
                        </button>
                      ) : (
                        <span className="rounded-full bg-slate-100 px-2.5 py-1 text-xs font-black text-slate-500">
                          0 {uom}
                        </span>
                      )}
                    </td>
                    <td className={`px-5 py-4 font-black ${
                      row.available < 0 ? 'text-rose-700' : 'text-slate-900'
                    }`}>
                      {qty(row.available)} {uom}
                    </td>
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
                    {expandedPair === row.key && row.reserved > 0 && (
                      <tr className="bg-amber-50/45">
                        <td colSpan={8} className="px-5 py-4">
                          <ReservationAllocationDetail
                            allocations={row.allocations}
                            posReserved={row.posReserved}
                            backofficeReserved={row.backofficeReserved}
                            uom={uom}
                          />
                        </td>
                      </tr>
                    )}
                  </Fragment>
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
        Reserved Out berasal dari Sales Order POS dan Backoffice yang belum
        dilepas atau dipenuhi. Available dihitung server-side sebagai On Hand
        dikurangi seluruh Reserved Out. Konfirmasi Order tidak mengurangi On
        Hand; pengurangan Stock dan FIFO baru terjadi ketika Surat Jalan
        di-dispatch.
      </p>
    </>
  )
}

function ReservationAllocationDetail({
  allocations,
  posReserved,
  backofficeReserved,
  uom,
}: {
  allocations: ReservationAllocation[]
  posReserved: number
  backofficeReserved: number
  uom: string
}) {
  return (
    <div className="rounded-2xl border border-amber-200 bg-white p-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <p className="font-black text-slate-900">Detail Reserved Out</p>
          <p className="mt-1 text-xs text-slate-500">
            POS {qty(posReserved)} {uom} - Backoffice {qty(backofficeReserved)} {uom}
          </p>
        </div>
        <span className="text-xs font-bold text-slate-500">
          {allocations.length} alokasi aktif
        </span>
      </div>
      {allocations.length ? (
        <div className="mt-4 grid gap-3 xl:grid-cols-2">
          {allocations.map((allocation) => (
            <div
              key={`${allocation.source}:${allocation.reservation_line_id}`}
              className="rounded-xl border border-slate-200 p-4"
            >
              <div className="flex flex-wrap items-start justify-between gap-3">
                <div>
                  <div className="flex flex-wrap items-center gap-2">
                    <span className={`rounded-full px-2 py-0.5 text-[11px] font-black ${
                      allocation.source === 'BACKOFFICE'
                        ? 'bg-blue-100 text-blue-700'
                        : 'bg-emerald-100 text-emerald-700'
                    }`}>
                      {allocation.source === 'BACKOFFICE' ? 'Backoffice' : 'POS'}
                    </span>
                    <span className="text-xs font-bold text-slate-500">
                      {allocation.reservation_status}
                    </span>
                  </div>
                  <p className="mt-2 font-black text-slate-900">
                    {allocation.sales_order_no}
                  </p>
                  <p className="mt-1 text-sm text-slate-600">
                    {allocation.customer_name} - {allocation.customer_code}
                  </p>
                </div>
                <p className="font-black text-amber-800">
                  {qty(Number(allocation.reserved_out_base_qty) || 0)} {uom}
                </p>
              </div>
              <div className="mt-3 flex flex-wrap gap-x-5 gap-y-1 text-xs text-slate-500">
                <span>Rencana {allocation.scheduled_date
                  ? new Date(`${allocation.scheduled_date}T00:00:00`).toLocaleDateString('id-ID')
                  : '-'}</span>
                <span>Kekurangan {qty(Number(allocation.shortage_base_qty) || 0)} {uom}</span>
                <span>
                  SJ {allocation.delivery_orders.length
                    ? allocation.delivery_orders.map((delivery) =>
                        `${delivery.deliveryNo} (${delivery.status})`).join(', ')
                    : 'belum tersedia'}
                </span>
              </div>
            </div>
          ))}
        </div>
      ) : (
        <p className="mt-4 rounded-xl bg-slate-50 p-3 text-sm text-slate-500">
          Breakdown sumber belum tersedia pada read model database ini.
        </p>
      )}
    </div>
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
