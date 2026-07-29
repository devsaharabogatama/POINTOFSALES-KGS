'use client'

import { useCallback, useEffect, useMemo, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import {
  ArrowRight,
  ArrowRightLeft,
  CheckCircle2,
  Eye,
  FilePlus2,
  Loader2,
  Pencil,
  Plus,
  RefreshCcw,
  Send,
  Trash2,
  X,
  XCircle,
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

type Warehouse = {
  id: string
  name: string
  warehouse_type: string | null
  location: string | null
  is_active: boolean
}

type TransferDocument = {
  id: string
  document_no: string
  source_warehouse_id: string
  destination_warehouse_id: string
  transfer_date: string
  status: 'DRAFT' | 'POSTED' | 'CANCELED'
  notes: string | null
  line_count: number
  total_quantity_base: number | string
  total_cost: number | string
  master_version: number
  posted_at: string | null
  canceled_at: string | null
}

type TransferLine = {
  id: string
  document_id: string
  line_no: number
  product_id: string
  quantity_base: number | string
  transferred_cost: number | string
  fifo_layer_count: number
  product_sku_snapshot: string
  product_name_snapshot: string
  base_uom_name_snapshot: string
  notes: string | null
}

type Allocation = {
  id: number
  document_id: string
  line_id: string
  quantity_base: number | string
  unit_cost_base: number | string
  total_cost: number | string
}

type Balance = {
  product_id: string
  warehouse_id: string
  stock_qty: number | string
}

type Movement = {
  id: string
  product_id: string
  warehouse_id: string
  qty_change: number | string
  movement_type: string
  reference_id: string
  balance_after_base_qty: number | string | null
}

type Payload = {
  data?: TransferDocument[]
  lines?: TransferLine[]
  allocations?: Allocation[]
  balances?: Balance[]
  movements?: Movement[]
  error?: string
}

type FormLine = {
  key: string
  productId: string
  quantityBase: string
  notes: string
}

function authHeaders(session: Session) {
  return { Authorization: `Bearer ${session.access_token}` }
}

function qty(value: number | string) {
  return new Intl.NumberFormat('id-ID', { maximumFractionDigits: 6 }).format(
    Number(value) || 0,
  )
}

function rupiah(value: number | string) {
  return new Intl.NumberFormat('id-ID', {
    style: 'currency',
    currency: 'IDR',
    maximumFractionDigits: 2,
  }).format(Number(value) || 0)
}

function baseUom(product?: Product) {
  if (!product) return null
  return (product.product_uoms ?? []).find(
    (row) =>
      row.is_active &&
      row.uom?.is_active &&
      row.uom_id === product.uom_id &&
      Number(row.factor_to_base) === 1,
  )?.uom ?? null
}

function newLine(productId = ''): FormLine {
  return {
    key: crypto.randomUUID(),
    productId,
    quantityBase: '',
    notes: '',
  }
}

function friendlyError(code?: string) {
  const messages: Record<string, string> = {
    STOCK_TRANSFER_OPERATOR_REQUIRED:
      'Role Anda hanya dapat melihat Transfer Stok.',
    STOCK_TRANSFER_WAREHOUSES_MUST_DIFFER:
      'Gudang asal dan Gudang tujuan harus berbeda.',
    ACTIVE_TRANSFER_WAREHOUSE_NOT_FOUND:
      'Gudang asal atau tujuan sudah tidak aktif.',
    STOCK_TRANSFER_DATE_INVALID: 'Tanggal transfer tidak valid.',
    STOCK_TRANSFER_FUTURE_DATE_NOT_ALLOWED:
      'Tanggal transfer tidak boleh melewati hari ini.',
    STOCK_TRANSFER_LINES_REQUIRED: 'Tambahkan minimal satu Product.',
    STOCK_TRANSFER_DUPLICATE_PRODUCT:
      'Satu Product hanya boleh muncul sekali dalam dokumen.',
    STOCK_TRANSFER_QUANTITY_INVALID:
      'Quantity transfer harus lebih dari nol.',
    STOCK_TRANSFER_QUANTITY_MUST_BE_POSITIVE:
      'Quantity transfer harus lebih dari nol.',
    STOCK_TRANSFER_QUANTITY_TOO_LARGE: 'Quantity transfer terlalu besar.',
    ACTIVE_STOCK_PRODUCT_WITH_BASE_UOM_NOT_FOUND:
      'Product stok atau Base UOM sudah tidak aktif.',
    STOCK_TRANSFER_BASE_UOM_REQUIRES_INTEGER:
      'Base UOM Product ini hanya menerima bilangan bulat.',
    STOCK_TRANSFER_BASE_UOM_PRECISION_EXCEEDED:
      'Jumlah desimal melebihi presisi Base UOM Product.',
    INSUFFICIENT_STOCK:
      'Stok aktual di Gudang asal tidak cukup. Muat ulang lalu periksa quantity.',
    INSUFFICIENT_FIFO_STOCK:
      'Layer FIFO di Gudang asal tidak cukup atau tidak sinkron.',
    STOCK_TRANSFER_TRANSACTION_CATEGORY_NOT_FOUND:
      'Kategori transaksi Stock Transfer belum siap.',
    STOCK_TRANSFER_NOT_FOUND: 'Dokumen Transfer Stok tidak ditemukan.',
    FINAL_STOCK_TRANSFER_IMMUTABLE:
      'Dokumen yang sudah final tidak dapat diubah.',
    CANCELED_STOCK_TRANSFER_IMMUTABLE:
      'Dokumen yang dibatalkan tidak dapat diposting.',
    STOCK_TRANSFER_ALREADY_POSTED: 'Dokumen ini sudah diposting.',
    MASTER_VERSION_CONFLICT:
      'Dokumen berubah di tab lain. Muat ulang lalu ulangi tindakan.',
    FORBIDDEN: 'Role Anda tidak diizinkan mengakses Transfer Stok.',
  }
  return messages[code ?? ''] ?? code ?? 'Operasi Transfer Stok gagal.'
}

export function StockTransferView({
  session,
  companyId,
  canOperate,
  notify,
}: {
  session: Session
  companyId: string
  canOperate: boolean
  notify: (message: string) => void
}) {
  const [products, setProducts] = useState<Product[]>([])
  const [warehouses, setWarehouses] = useState<Warehouse[]>([])
  const [payload, setPayload] = useState<Payload>({})
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [editing, setEditing] = useState<TransferDocument | 'create' | null>(null)
  const [posting, setPosting] = useState<TransferDocument | null>(null)
  const [canceling, setCanceling] = useState<TransferDocument | null>(null)
  const [detail, setDetail] = useState<TransferDocument | null>(null)

  const load = useCallback(async () => {
    const responses = await Promise.all([
      fetch('/api/master/products?includeInactive=true', {
        headers: authHeaders(session),
      }),
      fetch('/api/master/warehouses?includeInactive=true', {
        headers: authHeaders(session),
      }),
      fetch('/api/inventory/stock-transfers', {
        headers: authHeaders(session),
      }),
    ])
    const results = await Promise.all(responses.map((response) => response.json()))
    const failed = responses.findIndex((response) => !response.ok)
    if (failed >= 0) {
      throw new Error(friendlyError((results[failed] as { error?: string }).error))
    }
    setProducts((results[0] as { data?: Product[] }).data ?? [])
    setWarehouses((results[1] as { data?: Warehouse[] }).data ?? [])
    setPayload(results[2] as Payload)
  }, [session])

  const refresh = useCallback(async () => {
    setLoading(true)
    setError('')
    try {
      await load()
    } catch (caught) {
      setError(
        caught instanceof Error ? caught.message : 'Gagal memuat Transfer Stok.',
      )
    } finally {
      setLoading(false)
    }
  }, [load])

  useEffect(() => {
    let canceled = false
    // eslint-disable-next-line react-hooks/set-state-in-effect -- tenant data follows active Company
    load()
      .catch((caught) => {
        if (!canceled) {
          setError(
            caught instanceof Error
              ? caught.message
              : 'Gagal memuat Transfer Stok.',
          )
        }
      })
      .finally(() => {
        if (!canceled) setLoading(false)
      })
    return () => {
      canceled = true
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
  const activeProducts = products.filter(
    (product) => product.is_active && !product.is_bundle && Boolean(baseUom(product)),
  )
  const activeWarehouses = warehouses.filter((warehouse) => warehouse.is_active)
  const draftCount = (payload.data ?? []).filter(
    (document) => document.status === 'DRAFT',
  ).length
  const postedCount = (payload.data ?? []).filter(
    (document) => document.status === 'POSTED',
  ).length

  return (
    <>
      <div className="mb-7 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <p className="text-xs font-bold uppercase tracking-[.16em] text-emerald-600">
            Inventory operation
          </p>
          <h1 className="mt-2 text-2xl font-black tracking-tight text-slate-950 md:text-3xl">
            Transfer Stok
          </h1>
          <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-500">
            Pindahkan stok aktual antar-Gudang menggunakan Base UOM. Draft belum
            mengubah stok; Posting mengurangi Gudang asal, menambah Gudang tujuan,
            dan mempertahankan nilai FIFO.
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
          {canOperate && (
            <button
              onClick={() => setEditing('create')}
              className="inline-flex items-center gap-2 rounded-xl bg-emerald-500 px-4 py-3 text-sm font-bold text-white"
            >
              <FilePlus2 className="h-4 w-4" /> Buat Transfer
            </button>
          )}
        </div>
      </div>

      {!canOperate && (
        <div className="mb-5 rounded-2xl border border-blue-200 bg-blue-50 p-4 text-sm text-blue-800">
          Anda memiliki akses baca. Pembuatan, Posting, dan pembatalan Transfer
          Stok dilakukan oleh Owner, Admin Company, atau Admin Gudang.
        </div>
      )}
      {error && (
        <div className="mb-5 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-700">
          {error}
        </div>
      )}

      <div className="mb-5 grid gap-4 sm:grid-cols-3">
        <Summary label="Total dokumen" value={String((payload.data ?? []).length)} />
        <Summary label="Draft" value={String(draftCount)} />
        <Summary label="Sudah diposting" value={String(postedCount)} />
      </div>

      <div className="overflow-x-auto rounded-2xl border border-slate-200 bg-white shadow-sm">
        <table className="w-full min-w-[1100px] text-left text-sm">
          <thead className="bg-slate-50 text-xs uppercase tracking-wider text-slate-500">
            <tr>
              <th className="px-5 py-4">Dokumen</th>
              <th className="px-5 py-4">Tanggal</th>
              <th className="px-5 py-4">Dari Gudang</th>
              <th className="px-5 py-4">Ke Gudang</th>
              <th className="px-5 py-4">Isi</th>
              <th className="px-5 py-4">Status</th>
              <th className="px-5 py-4 text-right">Aksi</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {(payload.data ?? []).map((document) => (
              <tr key={document.id}>
                <td className="px-5 py-4">
                  <p className="font-black text-slate-900">{document.document_no}</p>
                  <p className="mt-1 max-w-[220px] truncate text-xs text-slate-400">
                    {document.notes || 'Tanpa catatan'}
                  </p>
                </td>
                <td className="px-5 py-4 text-slate-700">
                  {new Date(`${document.transfer_date}T00:00:00`).toLocaleDateString(
                    'id-ID',
                  )}
                </td>
                <td className="px-5 py-4 font-bold text-slate-700">
                  {warehouseById.get(document.source_warehouse_id)?.name ??
                    'Gudang tidak tersedia'}
                </td>
                <td className="px-5 py-4 font-bold text-slate-700">
                  {warehouseById.get(document.destination_warehouse_id)?.name ??
                    'Gudang tidak tersedia'}
                </td>
                <td className="px-5 py-4">
                  <p className="font-bold text-slate-700">
                    {document.line_count} Product
                  </p>
                  <p className="mt-1 text-xs text-slate-400">
                    Total Base Qty {qty(document.total_quantity_base)}
                  </p>
                </td>
                <td className="px-5 py-4">
                  <StatusBadge status={document.status} />
                </td>
                <td className="px-5 py-4">
                  <div className="flex justify-end gap-2">
                    <button
                      onClick={() => setDetail(document)}
                      className="rounded-xl border border-slate-200 p-2 text-slate-600"
                      aria-label={`Lihat ${document.document_no}`}
                    >
                      <Eye className="h-4 w-4" />
                    </button>
                    {canOperate && document.status === 'DRAFT' && (
                      <>
                        <button
                          onClick={() => setEditing(document)}
                          className="rounded-xl border border-slate-200 p-2 text-blue-600"
                          aria-label={`Edit ${document.document_no}`}
                        >
                          <Pencil className="h-4 w-4" />
                        </button>
                        <button
                          onClick={() => setPosting(document)}
                          className="rounded-xl bg-emerald-500 p-2 text-white"
                          aria-label={`Posting ${document.document_no}`}
                        >
                          <Send className="h-4 w-4" />
                        </button>
                        <button
                          onClick={() => setCanceling(document)}
                          className="rounded-xl border border-rose-200 p-2 text-rose-600"
                          aria-label={`Batalkan ${document.document_no}`}
                        >
                          <XCircle className="h-4 w-4" />
                        </button>
                      </>
                    )}
                  </div>
                </td>
              </tr>
            ))}
            {!loading && !(payload.data ?? []).length && (
              <tr>
                <td colSpan={7} className="p-12 text-center text-sm text-slate-400">
                  Belum ada dokumen Transfer Stok.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      {editing && (
        <TransferEditor
          session={session}
          products={activeProducts}
          warehouses={activeWarehouses}
          balances={payload.balances ?? []}
          document={editing === 'create' ? undefined : editing}
          existingLines={
            editing === 'create'
              ? []
              : (payload.lines ?? []).filter(
                  (line) => line.document_id === editing.id,
                )
          }
          close={() => setEditing(null)}
          complete={async () => {
            setEditing(null)
            notify('Draft Transfer Stok berhasil disimpan.')
            await refresh()
          }}
        />
      )}
      {posting && (
        <ActionDialog
          session={session}
          document={posting}
          action="post"
          warehouseLabel={`${warehouseById.get(posting.source_warehouse_id)?.name ?? 'Gudang asal'} → ${warehouseById.get(posting.destination_warehouse_id)?.name ?? 'Gudang tujuan'}`}
          close={() => setPosting(null)}
          complete={async () => {
            setPosting(null)
            notify('Transfer berhasil diposting. Saldo dan FIFO sudah berpindah.')
            await refresh()
          }}
        />
      )}
      {canceling && (
        <ActionDialog
          session={session}
          document={canceling}
          action="cancel"
          warehouseLabel={`${warehouseById.get(canceling.source_warehouse_id)?.name ?? 'Gudang asal'} → ${warehouseById.get(canceling.destination_warehouse_id)?.name ?? 'Gudang tujuan'}`}
          close={() => setCanceling(null)}
          complete={async () => {
            setCanceling(null)
            notify('Draft Transfer Stok berhasil dibatalkan.')
            await refresh()
          }}
        />
      )}
      {detail && (
        <TransferDetail
          document={detail}
          sourceName={
            warehouseById.get(detail.source_warehouse_id)?.name ?? 'Gudang asal'
          }
          destinationName={
            warehouseById.get(detail.destination_warehouse_id)?.name ??
            'Gudang tujuan'
          }
          lines={(payload.lines ?? []).filter(
            (line) => line.document_id === detail.id,
          )}
          allocations={(payload.allocations ?? []).filter(
            (allocation) => allocation.document_id === detail.id,
          )}
          balances={payload.balances ?? []}
          movements={(payload.movements ?? []).filter(
            (movement) => movement.reference_id === detail.id,
          )}
          productById={productById}
          close={() => setDetail(null)}
        />
      )}
    </>
  )
}

function TransferEditor({
  session,
  products,
  warehouses,
  balances,
  document,
  existingLines,
  close,
  complete,
}: {
  session: Session
  products: Product[]
  warehouses: Warehouse[]
  balances: Balance[]
  document?: TransferDocument
  existingLines: TransferLine[]
  close: () => void
  complete: () => Promise<void>
}) {
  useEscapeClose(close)
  const [sourceWarehouseId, setSourceWarehouseId] = useState(
    document?.source_warehouse_id ?? warehouses[0]?.id ?? '',
  )
  const [destinationWarehouseId, setDestinationWarehouseId] = useState(
    document?.destination_warehouse_id ??
      warehouses.find((warehouse) => warehouse.id !== warehouses[0]?.id)?.id ??
      '',
  )
  const [transferDate, setTransferDate] = useState(
    document?.transfer_date ?? new Date().toLocaleDateString('en-CA'),
  )
  const [notes, setNotes] = useState(document?.notes ?? '')
  const [lines, setLines] = useState<FormLine[]>(
    existingLines.length
      ? existingLines.map((line) => ({
          key: line.id,
          productId: line.product_id,
          quantityBase: String(line.quantity_base),
          notes: line.notes ?? '',
        }))
      : [newLine()],
  )
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')
  const selectedProducts = new Set(lines.map((line) => line.productId).filter(Boolean))

  function stock(productId: string) {
    return Number(
      balances.find(
        (balance) =>
          balance.product_id === productId &&
          balance.warehouse_id === sourceWarehouseId,
      )?.stock_qty ?? 0,
    )
  }

  function updateLine(key: string, patch: Partial<FormLine>) {
    setLines((current) =>
      current.map((line) => (line.key === key ? { ...line, ...patch } : line)),
    )
  }

  async function submit(event: React.FormEvent) {
    event.preventDefault()
    setSaving(true)
    setError('')
    try {
      const response = await fetch(
        document
          ? `/api/inventory/stock-transfers/${document.id}`
          : '/api/inventory/stock-transfers',
        {
          method: document ? 'PATCH' : 'POST',
          headers: {
            'Content-Type': 'application/json',
            ...authHeaders(session),
          },
          body: JSON.stringify({
            masterVersion: document?.master_version,
            sourceWarehouseId,
            destinationWarehouseId,
            transferDate,
            notes: notes.trim() || null,
            lines: lines.map((line) => ({
              productId: line.productId,
              quantityBase: line.quantityBase,
              notes: line.notes.trim() || null,
            })),
          }),
        },
      )
      const result = (await response.json()) as { error?: string }
      if (!response.ok) throw new Error(friendlyError(result.error))
      await complete()
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Gagal menyimpan Draft.')
    } finally {
      setSaving(false)
    }
  }

  return (
    <div className="fixed inset-0 z-[70] grid place-items-center bg-slate-950/45 p-4 backdrop-blur-sm">
      <div className="max-h-[94vh] w-full max-w-5xl overflow-y-auto rounded-3xl bg-white p-6 shadow-2xl sm:p-8">
        <div className="flex items-start justify-between gap-4">
          <div>
            <h2 className="text-xl font-black text-slate-950">
              {document ? `Edit ${document.document_no}` : 'Buat Transfer Stok'}
            </h2>
            <p className="mt-2 text-sm leading-6 text-slate-500">
              Pilih asal, tujuan, lalu isi quantity dalam Base UOM Product.
              Menyimpan Draft belum memindahkan stok.
            </p>
          </div>
          <button
            onClick={close}
            className="rounded-xl bg-slate-100 p-2 text-slate-500"
            aria-label="Tutup"
          >
            <X className="h-4 w-4" />
          </button>
        </div>
        <form onSubmit={submit} className="mt-7 space-y-6">
          <div className="grid gap-4 lg:grid-cols-[1fr_auto_1fr]">
            <label className="text-sm font-bold text-slate-700">
              Dari Gudang
              <select
                required
                value={sourceWarehouseId}
                onChange={(event) => setSourceWarehouseId(event.target.value)}
                className="mt-2 w-full rounded-xl border border-slate-200 bg-white px-4 py-3"
              >
                <option value="">Pilih Gudang asal</option>
                {warehouses.map((warehouse) => (
                  <option key={warehouse.id} value={warehouse.id}>
                    {warehouse.name}
                  </option>
                ))}
              </select>
            </label>
            <ArrowRight className="mt-10 hidden h-5 w-5 text-slate-400 lg:block" />
            <label className="text-sm font-bold text-slate-700">
              Ke Gudang
              <select
                required
                value={destinationWarehouseId}
                onChange={(event) => setDestinationWarehouseId(event.target.value)}
                className="mt-2 w-full rounded-xl border border-slate-200 bg-white px-4 py-3"
              >
                <option value="">Pilih Gudang tujuan</option>
                {warehouses
                  .filter((warehouse) => warehouse.id !== sourceWarehouseId)
                  .map((warehouse) => (
                    <option key={warehouse.id} value={warehouse.id}>
                      {warehouse.name}
                    </option>
                  ))}
              </select>
            </label>
          </div>
          <div className="grid gap-4 md:grid-cols-2">
            <label className="text-sm font-bold text-slate-700">
              Tanggal transfer
              <input
                required
                type="date"
                max={new Date().toLocaleDateString('en-CA')}
                value={transferDate}
                onChange={(event) => setTransferDate(event.target.value)}
                className="mt-2 w-full rounded-xl border border-slate-200 px-4 py-3"
              />
            </label>
            <label className="text-sm font-bold text-slate-700">
              Catatan dokumen (opsional)
              <input
                value={notes}
                onChange={(event) => setNotes(event.target.value)}
                placeholder="Contoh: pemenuhan stok Gudang Packaging"
                className="mt-2 w-full rounded-xl border border-slate-200 px-4 py-3"
              />
            </label>
          </div>

          <div className="space-y-4">
            <div className="flex items-center justify-between">
              <div>
                <h3 className="font-black text-slate-900">Product yang dipindahkan</h3>
                <p className="mt-1 text-xs text-slate-500">
                  Stok tersedia dibaca dari Gudang asal saat ini. Posting akan
                  memeriksa ulang saldo dan FIFO di server.
                </p>
              </div>
              <button
                type="button"
                onClick={() => setLines((current) => [...current, newLine()])}
                className="inline-flex items-center gap-2 rounded-xl border border-slate-200 px-3 py-2 text-xs font-bold text-slate-600"
              >
                <Plus className="h-3.5 w-3.5" /> Tambah Product
              </button>
            </div>
            {lines.map((line, index) => {
              const product = products.find((item) => item.id === line.productId)
              const uom = baseUom(product)
              const available = stock(line.productId)
              const choices = products.filter(
                (item) =>
                  item.id === line.productId ||
                  (!selectedProducts.has(item.id) && stock(item.id) > 0),
              )
              return (
                <div
                  key={line.key}
                  className="rounded-2xl border border-slate-200 bg-slate-50 p-4"
                >
                  <div className="grid gap-4 lg:grid-cols-[1.7fr_1fr_1fr_auto]">
                    <label className="text-sm font-bold text-slate-700">
                      Product
                      <select
                        required
                        value={line.productId}
                        onChange={(event) =>
                          updateLine(line.key, { productId: event.target.value })
                        }
                        className="mt-2 w-full rounded-xl border border-slate-200 bg-white px-3 py-3"
                      >
                        <option value="">Pilih Product yang memiliki stok</option>
                        {choices.map((item) => (
                          <option key={item.id} value={item.id}>
                            {item.name} ({item.sku})
                          </option>
                        ))}
                      </select>
                    </label>
                    <label className="text-sm font-bold text-slate-700">
                      Qty ({uom?.name ?? 'Base UOM'})
                      <input
                        required
                        type="number"
                        min="0"
                        max={available || undefined}
                        step={
                          uom?.allow_decimal
                            ? 10 ** -(uom.decimal_precision || 1)
                            : 1
                        }
                        value={line.quantityBase}
                        onChange={(event) =>
                          updateLine(line.key, {
                            quantityBase: event.target.value,
                          })
                        }
                        className="mt-2 w-full rounded-xl border border-slate-200 bg-white px-3 py-3"
                      />
                    </label>
                    <div className="text-sm font-bold text-slate-700">
                      Stok tersedia
                      <div className="mt-2 rounded-xl border border-slate-200 bg-white px-3 py-3 text-slate-900">
                        {line.productId
                          ? `${qty(available)} ${uom?.name ?? ''}`
                          : '-'}
                      </div>
                    </div>
                    <button
                      type="button"
                      disabled={lines.length === 1}
                      onClick={() =>
                        setLines((current) =>
                          current.filter((item) => item.key !== line.key),
                        )
                      }
                      className="mt-7 grid h-11 w-11 place-items-center rounded-xl text-rose-500 disabled:opacity-30"
                      aria-label={`Hapus baris ${index + 1}`}
                    >
                      <Trash2 className="h-4 w-4" />
                    </button>
                  </div>
                  <label className="mt-4 block text-sm font-bold text-slate-700">
                    Catatan baris (opsional)
                    <input
                      value={line.notes}
                      onChange={(event) =>
                        updateLine(line.key, { notes: event.target.value })
                      }
                      className="mt-2 w-full rounded-xl border border-slate-200 bg-white px-3 py-3"
                    />
                  </label>
                </div>
              )
            })}
          </div>
          {error && (
            <div className="rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-700">
              {error}
            </div>
          )}
          <div className="flex justify-end gap-3 border-t border-slate-100 pt-5">
            <button
              type="button"
              onClick={close}
              className="rounded-xl border border-slate-200 px-4 py-2.5 text-sm font-bold text-slate-600"
            >
              Batal
            </button>
            <button
              disabled={
                saving ||
                !sourceWarehouseId ||
                !destinationWarehouseId ||
                sourceWarehouseId === destinationWarehouseId ||
                !lines.length
              }
              className="inline-flex items-center gap-2 rounded-xl bg-emerald-500 px-5 py-2.5 text-sm font-bold text-white disabled:opacity-50"
            >
              {saving && <Loader2 className="h-4 w-4 animate-spin" />}
              Simpan Draft
            </button>
          </div>
        </form>
      </div>
    </div>
  )
}

function ActionDialog({
  session,
  document,
  action,
  warehouseLabel,
  close,
  complete,
}: {
  session: Session
  document: TransferDocument
  action: 'post' | 'cancel'
  warehouseLabel: string
  close: () => void
  complete: () => Promise<void>
}) {
  useEscapeClose(close)
  const [confirmed, setConfirmed] = useState(false)
  const [idempotencyKey] = useState(() => crypto.randomUUID())
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')
  const posting = action === 'post'

  async function run() {
    setSaving(true)
    setError('')
    try {
      const response = await fetch(
        `/api/inventory/stock-transfers/${document.id}/${action}`,
        {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            ...authHeaders(session),
          },
          body: JSON.stringify({
            masterVersion: document.master_version,
            ...(posting ? { idempotencyKey } : {}),
          }),
        },
      )
      const result = (await response.json()) as { error?: string }
      if (!response.ok) throw new Error(friendlyError(result.error))
      await complete()
    } catch (caught) {
      setError(
        caught instanceof Error ? caught.message : 'Tindakan Transfer Stok gagal.',
      )
    } finally {
      setSaving(false)
    }
  }

  return (
    <div className="fixed inset-0 z-[80] grid place-items-center bg-slate-950/50 p-4 backdrop-blur-sm">
      <div className="w-full max-w-xl rounded-3xl bg-white p-7 shadow-2xl">
        <div className="flex items-start justify-between gap-4">
          <div>
            <h2 className="text-xl font-black text-slate-950">
              {posting ? 'Posting Transfer Stok?' : 'Batalkan Draft Transfer?'}
            </h2>
            <p className="mt-2 text-sm leading-6 text-slate-500">
              {document.document_no} · {warehouseLabel}
            </p>
          </div>
          <button
            onClick={close}
            className="rounded-xl bg-slate-100 p-2 text-slate-500"
            aria-label="Tutup"
          >
            <X className="h-4 w-4" />
          </button>
        </div>
        <div
          className={`mt-5 rounded-2xl border p-4 text-sm leading-6 ${
            posting
              ? 'border-amber-200 bg-amber-50 text-amber-900'
              : 'border-rose-200 bg-rose-50 text-rose-800'
          }`}
        >
          {posting
            ? 'Posting bersifat final: stok asal berkurang, stok tujuan bertambah, dan layer FIFO dipindahkan. Dokumen tidak dapat diedit setelahnya.'
            : 'Pembatalan hanya mengubah status Draft. Tidak ada saldo, FIFO, atau Kartu Stok yang berubah.'}
        </div>
        <label className="mt-5 flex items-start gap-3 rounded-2xl border border-slate-200 p-4">
          <input
            type="checkbox"
            checked={confirmed}
            onChange={(event) => setConfirmed(event.target.checked)}
            className="mt-1 h-4 w-4 accent-emerald-500"
          />
          <span className="text-sm font-semibold leading-6 text-slate-700">
            {posting
              ? 'Saya sudah memeriksa Gudang asal, Gudang tujuan, Product, quantity, dan stok tersedia.'
              : 'Saya yakin Draft ini tidak akan digunakan dan boleh dibatalkan.'}
          </span>
        </label>
        {error && (
          <div className="mt-4 rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-700">
            {error}
          </div>
        )}
        <div className="mt-6 flex justify-end gap-3">
          <button
            onClick={close}
            className="rounded-xl border border-slate-200 px-4 py-2.5 text-sm font-bold text-slate-600"
          >
            Kembali
          </button>
          <button
            disabled={!confirmed || saving}
            onClick={() => void run()}
            className={`inline-flex items-center gap-2 rounded-xl px-5 py-2.5 text-sm font-bold text-white disabled:opacity-50 ${
              posting ? 'bg-emerald-500' : 'bg-rose-500'
            }`}
          >
            {saving ? (
              <Loader2 className="h-4 w-4 animate-spin" />
            ) : posting ? (
              <Send className="h-4 w-4" />
            ) : (
              <XCircle className="h-4 w-4" />
            )}
            {posting ? 'Posting sekarang' : 'Batalkan Draft'}
          </button>
        </div>
      </div>
    </div>
  )
}

function TransferDetail({
  document,
  sourceName,
  destinationName,
  lines,
  allocations,
  balances,
  movements,
  productById,
  close,
}: {
  document: TransferDocument
  sourceName: string
  destinationName: string
  lines: TransferLine[]
  allocations: Allocation[]
  balances: Balance[]
  movements: Movement[]
  productById: Map<string, Product>
  close: () => void
}) {
  useEscapeClose(close)
  return (
    <div className="fixed inset-0 z-[70] grid place-items-center bg-slate-950/45 p-4 backdrop-blur-sm">
      <div className="max-h-[94vh] w-full max-w-6xl overflow-y-auto rounded-3xl bg-white p-6 shadow-2xl sm:p-8">
        <div className="flex items-start justify-between gap-4">
          <div>
            <div className="flex items-center gap-2">
              <ArrowRightLeft className="h-5 w-5 text-emerald-600" />
              <h2 className="text-xl font-black text-slate-950">
                {document.document_no}
              </h2>
            </div>
            <p className="mt-2 flex flex-wrap items-center gap-2 text-sm text-slate-500">
              <span>{sourceName}</span>
              <ArrowRight className="h-4 w-4" />
              <span>{destinationName}</span>
              <span>·</span>
              <StatusBadge status={document.status} />
            </p>
          </div>
          <button
            onClick={close}
            className="rounded-xl bg-slate-100 p-2 text-slate-500"
            aria-label="Tutup"
          >
            <X className="h-4 w-4" />
          </button>
        </div>
        {document.status === 'POSTED' && (
          <div className="mt-5 flex items-center gap-3 rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-sm text-emerald-800">
            <CheckCircle2 className="h-5 w-5" />
            Transfer final: saldo kedua Gudang, movement berpasangan, dan relokasi
            FIFO sudah terbentuk.
          </div>
        )}
        <div className="mt-6 overflow-x-auto rounded-2xl border border-slate-200">
          <table className="w-full min-w-[1150px] text-left text-sm">
            <thead className="bg-slate-50 text-xs uppercase tracking-wider text-slate-500">
              <tr>
                <th className="px-4 py-3">Product</th>
                <th className="px-4 py-3">Qty Transfer</th>
                <th className="px-4 py-3">Saldo Asal</th>
                <th className="px-4 py-3">Saldo Tujuan</th>
                <th className="px-4 py-3">Movement</th>
                <th className="px-4 py-3">FIFO</th>
                <th className="px-4 py-3">Nilai Transfer</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {lines.map((line) => {
                const product = productById.get(line.product_id)
                const sourceBalance = balances.find(
                  (row) =>
                    row.product_id === line.product_id &&
                    row.warehouse_id === document.source_warehouse_id,
                )
                const destinationBalance = balances.find(
                  (row) =>
                    row.product_id === line.product_id &&
                    row.warehouse_id === document.destination_warehouse_id,
                )
                const lineMovements = movements.filter(
                  (movement) => movement.product_id === line.product_id,
                )
                const lineAllocations = allocations.filter(
                  (allocation) => allocation.line_id === line.id,
                )
                return (
                  <tr key={line.id}>
                    <td className="px-4 py-4">
                      <p className="font-black text-slate-900">
                        {product?.name ?? line.product_name_snapshot}
                      </p>
                      <p className="mt-1 text-xs text-slate-400">
                        {line.base_uom_name_snapshot}
                      </p>
                    </td>
                    <td className="px-4 py-4 font-black text-slate-800">
                      {qty(line.quantity_base)} {line.base_uom_name_snapshot}
                    </td>
                    <td className="px-4 py-4 font-bold text-slate-700">
                      {sourceBalance
                        ? `${qty(sourceBalance.stock_qty)} ${line.base_uom_name_snapshot}`
                        : '-'}
                    </td>
                    <td className="px-4 py-4 font-bold text-slate-700">
                      {destinationBalance
                        ? `${qty(destinationBalance.stock_qty)} ${line.base_uom_name_snapshot}`
                        : '-'}
                    </td>
                    <td className="px-4 py-4">
                      {lineMovements.length
                        ? lineMovements
                            .map(
                              (movement) =>
                                `${movement.movement_type === 'TRANSFER_OUT' ? 'Keluar' : 'Masuk'} ${qty(Math.abs(Number(movement.qty_change)))}`,
                            )
                            .join(' · ')
                        : 'Belum ada'}
                    </td>
                    <td className="px-4 py-4">
                      {document.status === 'POSTED'
                        ? `${lineAllocations.length} layer · ${qty(
                            lineAllocations.reduce(
                              (sum, row) => sum + Number(row.quantity_base),
                              0,
                            ),
                          )} ${line.base_uom_name_snapshot}`
                        : 'Terbentuk saat Posting'}
                    </td>
                    <td className="px-4 py-4 font-bold text-slate-700">
                      {document.status === 'POSTED'
                        ? rupiah(line.transferred_cost)
                        : '-'}
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
        {document.status === 'POSTED' && (
          <div className="mt-4 rounded-2xl bg-slate-50 p-4 text-sm text-slate-600">
            Total nilai FIFO yang berpindah: <strong>{rupiah(document.total_cost)}</strong>.
            Nilai ini bukan harga jual dan tidak diedit user.
          </div>
        )}
        <div className="mt-6 flex justify-end">
          <button
            onClick={close}
            className="rounded-xl border border-slate-200 px-5 py-2.5 text-sm font-bold text-slate-600"
          >
            Tutup
          </button>
        </div>
      </div>
    </div>
  )
}

function StatusBadge({ status }: { status: TransferDocument['status'] }) {
  const style =
    status === 'POSTED'
      ? 'bg-emerald-50 text-emerald-700'
      : status === 'CANCELED'
        ? 'bg-rose-50 text-rose-700'
        : 'bg-amber-50 text-amber-700'
  const label =
    status === 'POSTED'
      ? 'Sudah diposting'
      : status === 'CANCELED'
        ? 'Dibatalkan'
        : 'Draft'
  return (
    <span className={`rounded-full px-2.5 py-1 text-xs font-bold ${style}`}>
      {label}
    </span>
  )
}

function Summary({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
      <p className="text-xs font-bold uppercase tracking-wider text-slate-400">
        {label}
      </p>
      <p className="mt-2 text-2xl font-black text-slate-900">{value}</p>
    </div>
  )
}
