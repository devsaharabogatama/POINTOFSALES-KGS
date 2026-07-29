'use client'

import { useCallback, useEffect, useMemo, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import {
  ArrowDownToLine,
  ArrowUpFromLine,
  Boxes,
  FileClock,
  RefreshCcw,
  Search,
} from 'lucide-react'

type Movement = {
  id: string
  product_id: string
  warehouse_id: string
  qty_change: number | string
  movement_type: string
  reference_table: string
  reference_id: string
  created_at: string
  base_uom_name_snapshot: string | null
  balance_after_base_qty: number | string | null
  actor_id: string | null
  posted_at: string | null
  movement_status: string | null
  notes: string | null
}

type Product = {
  id: string
  sku: string
  name: string
  is_active: boolean
}

type Warehouse = {
  id: string
  name: string
  warehouse_type: string | null
  location: string | null
  is_active: boolean
}

type OpeningDocument = {
  id: string
  document_no: string
  status: string
}

type TransferDocument = {
  id: string
  document_no: string
  status: string
}
type AdjustmentDocument = {
  id: string
  document_no: string
  status: string
}

type Actor = {
  id: string
  name: string
}

type Payload = {
  data?: Movement[]
  products?: Product[]
  warehouses?: Warehouse[]
  openingDocuments?: OpeningDocument[]
  transferDocuments?: TransferDocument[]
  adjustmentDocuments?: AdjustmentDocument[]
  actors?: Actor[]
  error?: string
}

const movementLabels: Record<string, string> = {
  OPENING_BALANCE: 'Stok Awal',
  SALE: 'Penjualan',
  PURCHASE: 'Pembelian',
  ADJUSTMENT: 'Penyesuaian',
  TRANSFER_IN: 'Transfer Masuk',
  TRANSFER_OUT: 'Transfer Keluar',
  SALES_RETURN: 'Retur Penjualan',
  PURCHASE_RETURN: 'Retur Pembelian',
  OPNAME_GAIN: 'Selisih Opname Masuk',
  OPNAME_LOSS: 'Selisih Opname Keluar',
  REVERSAL: 'Pembalikan',
}

function authHeaders(session: Session) {
  return { Authorization: `Bearer ${session.access_token}` }
}

function qty(value: number) {
  return value.toLocaleString('id-ID', { maximumFractionDigits: 6 })
}

function sourceTypeLabel(referenceTable: string) {
  const normalized = referenceTable.toUpperCase()
  if (normalized === 'OPENING_STOCK_DOCUMENTS') return 'Dokumen Stok Awal'
  if (normalized.includes('SALE')) return 'Dokumen Penjualan'
  if (normalized.includes('PURCHASE')) return 'Dokumen Pembelian'
  if (normalized.includes('TRANSFER')) return 'Dokumen Transfer'
  if (normalized.includes('OPNAME')) return 'Dokumen Stock Opname'
  if (normalized.includes('ADJUST')) return 'Dokumen Penyesuaian'
  return 'Dokumen sumber'
}

export function StockMovementView({
  session,
  companyId,
}: {
  session: Session
  companyId: string
}) {
  const [payload, setPayload] = useState<Payload>({})
  const [query, setQuery] = useState('')
  const [warehouseId, setWarehouseId] = useState('')
  const [movementType, setMovementType] = useState('')
  const [dateFrom, setDateFrom] = useState('')
  const [dateTo, setDateTo] = useState('')
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')

  const load = useCallback(async () => {
    const response = await fetch('/api/inventory/stock-movements', {
      headers: authHeaders(session),
    })
    const nextPayload = (await response.json()) as Payload
    if (!response.ok) {
      throw new Error(nextPayload.error ?? 'Gagal memuat Kartu Stok.')
    }
    setPayload(nextPayload)
  }, [session])

  const refresh = useCallback(async () => {
    setLoading(true)
    setError('')
    try {
      await load()
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Gagal memuat Kartu Stok.')
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
          setError(caught instanceof Error ? caught.message : 'Gagal memuat Kartu Stok.')
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
    () => new Map((payload.products ?? []).map((product) => [product.id, product])),
    [payload.products],
  )
  const warehouseById = useMemo(
    () => new Map((payload.warehouses ?? []).map((warehouse) => [warehouse.id, warehouse])),
    [payload.warehouses],
  )
  const openingDocumentById = useMemo(
    () =>
      new Map(
        (payload.openingDocuments ?? []).map((document) => [document.id, document]),
      ),
    [payload.openingDocuments],
  )
  const transferDocumentById = useMemo(
    () =>
      new Map(
        (payload.transferDocuments ?? []).map((document) => [
          document.id,
          document,
        ]),
      ),
    [payload.transferDocuments],
  )
  const adjustmentDocumentById = useMemo(
    () =>
      new Map(
        (payload.adjustmentDocuments ?? []).map((document) => [
          document.id,
          document,
        ]),
      ),
    [payload.adjustmentDocuments],
  )
  const actorById = useMemo(
    () => new Map((payload.actors ?? []).map((actor) => [actor.id, actor.name])),
    [payload.actors],
  )

  const normalized = query.trim().toLocaleLowerCase('id-ID')
  const rows = (payload.data ?? []).filter((movement) => {
    if (warehouseId && movement.warehouse_id !== warehouseId) return false
    if (movementType && movement.movement_type !== movementType) return false
    const occurredAt = new Date(movement.posted_at ?? movement.created_at)
    if (dateFrom && occurredAt < new Date(`${dateFrom}T00:00:00`)) return false
    if (dateTo && occurredAt > new Date(`${dateTo}T23:59:59.999`)) return false
    if (!normalized) return true

    const product = productById.get(movement.product_id)
    const warehouse = warehouseById.get(movement.warehouse_id)
    const openingDocument = openingDocumentById.get(movement.reference_id)
    const transferDocument = transferDocumentById.get(movement.reference_id)
    const adjustmentDocument = adjustmentDocumentById.get(movement.reference_id)
    return [
      product?.sku ?? '',
      product?.name ?? '',
      warehouse?.name ?? '',
      openingDocument?.document_no ?? '',
      transferDocument?.document_no ?? '',
      adjustmentDocument?.document_no ?? '',
      movementLabels[movement.movement_type] ?? movement.movement_type,
      movement.notes ?? '',
    ].some((value) => value.toLocaleLowerCase('id-ID').includes(normalized))
  })

  const movementTypes = Array.from(
    new Set((payload.data ?? []).map((movement) => movement.movement_type)),
  ).sort()
  const pairCount = new Set(
    (payload.data ?? []).map(
      (movement) => `${movement.product_id}:${movement.warehouse_id}`,
    ),
  ).size
  const sourceCount = new Set(
    (payload.data ?? []).map(
      (movement) => `${movement.reference_table}:${movement.reference_id}`,
    ),
  ).size

  return (
    <>
      <div className="mb-7 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <p className="text-xs font-bold uppercase tracking-[.16em] text-emerald-600">
            Ledger Inventory
          </p>
          <h1 className="mt-2 text-2xl font-black tracking-tight text-slate-950 md:text-3xl">
            Stock Movement / Kartu Stok
          </h1>
          <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-500">
            Riwayat perubahan stok final per Product dan Gudang. Data ini hanya
            dapat dibaca; koreksi dilakukan melalui dokumen sumber, bukan dengan
            mengubah movement.
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
        <Summary icon={FileClock} label="Movement final" value={String((payload.data ?? []).length)} />
        <Summary icon={Boxes} label="Product–Gudang" value={String(pairCount)} />
        <Summary icon={FileClock} label="Dokumen sumber" value={String(sourceCount)} />
      </div>

      <div className="rounded-2xl border border-slate-200 bg-white shadow-sm">
        <div className="grid gap-3 border-b border-slate-100 p-4 lg:grid-cols-[1fr_210px_210px_160px_160px]">
          <label className="flex items-center gap-3 rounded-xl border border-slate-200 px-4">
            <Search className="h-4 w-4 text-slate-400" />
            <input
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              placeholder="Cari Product, Gudang, atau dokumen..."
              className="w-full bg-transparent py-3 text-sm outline-none"
            />
          </label>
          <select
            value={warehouseId}
            onChange={(event) => setWarehouseId(event.target.value)}
            className="rounded-xl border border-slate-200 bg-white px-4 py-3 text-sm font-semibold text-slate-700"
          >
            <option value="">Semua Gudang</option>
            {(payload.warehouses ?? []).map((warehouse) => (
              <option key={warehouse.id} value={warehouse.id}>{warehouse.name}</option>
            ))}
          </select>
          <select
            value={movementType}
            onChange={(event) => setMovementType(event.target.value)}
            className="rounded-xl border border-slate-200 bg-white px-4 py-3 text-sm font-semibold text-slate-700"
          >
            <option value="">Semua Jenis</option>
            {movementTypes.map((type) => (
              <option key={type} value={type}>{movementLabels[type] ?? type}</option>
            ))}
          </select>
          <input
            type="date"
            value={dateFrom}
            aria-label="Tanggal mulai"
            onChange={(event) => setDateFrom(event.target.value)}
            className="rounded-xl border border-slate-200 bg-white px-4 py-3 text-sm text-slate-700"
          />
          <input
            type="date"
            value={dateTo}
            aria-label="Tanggal akhir"
            onChange={(event) => setDateTo(event.target.value)}
            className="rounded-xl border border-slate-200 bg-white px-4 py-3 text-sm text-slate-700"
          />
        </div>

        <div className="overflow-x-auto">
          <table className="w-full min-w-[1500px] text-left text-sm">
            <thead className="bg-slate-50 text-xs uppercase tracking-wider text-slate-500">
              <tr>
                <th className="px-5 py-4">Waktu Posting</th>
                <th className="px-5 py-4">Product</th>
                <th className="px-5 py-4">Gudang</th>
                <th className="px-5 py-4">Masuk</th>
                <th className="px-5 py-4">Keluar</th>
                <th className="px-5 py-4">Saldo Setelah</th>
                <th className="px-5 py-4">Jenis</th>
                <th className="px-5 py-4">Dokumen Sumber</th>
                <th className="px-5 py-4">Pencatat</th>
                <th className="px-5 py-4">Catatan</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {rows.map((movement) => {
                const product = productById.get(movement.product_id)
                const warehouse = warehouseById.get(movement.warehouse_id)
                const openingDocument = openingDocumentById.get(movement.reference_id)
                const transferDocument = transferDocumentById.get(
                  movement.reference_id,
                )
                const adjustmentDocument = adjustmentDocumentById.get(
                  movement.reference_id,
                )
                const change = Number(movement.qty_change) || 0
                const uom = movement.base_uom_name_snapshot ?? ''
                const actor =
                  movement.actor_id === session.user.id
                    ? 'Anda'
                    : movement.actor_id
                      ? actorById.get(movement.actor_id) ?? 'User berwenang'
                      : 'Sistem'
                return (
                  <tr key={movement.id}>
                    <td className="px-5 py-4">
                      <p className="font-bold text-slate-700">
                        {new Date(movement.posted_at ?? movement.created_at).toLocaleString('id-ID')}
                      </p>
                      <p className="mt-1 text-xs text-emerald-600">
                        {movement.movement_status === 'POSTED' ? 'Final' : movement.movement_status ?? 'Final'}
                      </p>
                    </td>
                    <td className="px-5 py-4">
                      <p className="font-black text-slate-900">{product?.name ?? 'Product tidak tersedia'}</p>
                      <p className="mt-1 text-xs text-slate-400">{product?.sku ?? '-'}</p>
                    </td>
                    <td className="px-5 py-4">
                      <p className="font-bold text-slate-700">{warehouse?.name ?? 'Gudang tidak tersedia'}</p>
                      <p className="mt-1 text-xs text-slate-400">{warehouse?.location ?? warehouse?.warehouse_type ?? '-'}</p>
                    </td>
                    <td className="px-5 py-4 font-black text-emerald-700">
                      {change > 0 ? <span className="inline-flex items-center gap-1"><ArrowDownToLine className="h-4 w-4" />{qty(change)} {uom}</span> : '-'}
                    </td>
                    <td className="px-5 py-4 font-black text-rose-700">
                      {change < 0 ? <span className="inline-flex items-center gap-1"><ArrowUpFromLine className="h-4 w-4" />{qty(Math.abs(change))} {uom}</span> : '-'}
                    </td>
                    <td className="px-5 py-4 font-black text-slate-900">
                      {movement.balance_after_base_qty === null
                        ? 'Snapshot belum tersedia'
                        : `${qty(Number(movement.balance_after_base_qty))} ${uom}`}
                    </td>
                    <td className="px-5 py-4">
                      <span className="rounded-full bg-blue-50 px-2.5 py-1 text-xs font-bold text-blue-700">
                        {movementLabels[movement.movement_type] ?? movement.movement_type}
                      </span>
                    </td>
                    <td className="px-5 py-4">
                      <p className="font-bold text-slate-700">
                        {openingDocument?.document_no ??
                          transferDocument?.document_no ??
                          adjustmentDocument?.document_no ??
                          sourceTypeLabel(movement.reference_table)}
                      </p>
                      <p className="mt-1 text-xs text-slate-400">
                        {sourceTypeLabel(movement.reference_table)}
                      </p>
                    </td>
                    <td className="px-5 py-4 font-bold text-slate-700">{actor}</td>
                    <td className="max-w-[260px] px-5 py-4 text-slate-500">
                      {movement.notes?.trim() || '-'}
                    </td>
                  </tr>
                )
              })}
              {!loading && !rows.length && (
                <tr>
                  <td colSpan={10} className="p-12 text-center text-sm text-slate-400">
                    Tidak ada Stock Movement yang sesuai filter. Movement baru
                    muncul setelah dokumen stok berhasil diposting.
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
      <p className="mt-4 text-xs leading-5 text-slate-500">
        Kartu Stok bersifat append-only. Nama Product, Gudang, Base UOM, saldo
        setelah movement, sumber, actor, dan waktu berasal dari ledger final.
      </p>
    </>
  )
}

function Summary({
  icon: Icon,
  label,
  value,
}: {
  icon: typeof Boxes
  label: string
  value: string
}) {
  return (
    <div className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
      <div className="flex items-center gap-3">
        <span className="grid h-10 w-10 place-items-center rounded-xl bg-emerald-50 text-emerald-600">
          <Icon className="h-5 w-5" />
        </span>
        <div>
          <p className="text-xs font-bold uppercase tracking-wider text-slate-400">{label}</p>
          <p className="mt-1 text-xl font-black text-slate-900">{value}</p>
        </div>
      </div>
    </div>
  )
}
