'use client'

import { useCallback, useEffect, useMemo, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import {
  CheckCircle2,
  Eye,
  FilePlus2,
  Loader2,
  PackagePlus,
  Pencil,
  Plus,
  RefreshCcw,
  Send,
  Trash2,
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
  warehouse_id: string
  effective_date: string
  status: 'DRAFT' | 'POSTED'
  notes: string | null
  line_count: number
  total_quantity_base: number | string
  total_cost: number | string
  master_version: number
  posted_at: string | null
}

type OpeningLine = {
  id: string
  document_id: string
  line_no: number
  product_id: string
  base_uom_id: string
  quantity_base: number | string
  unit_cost_base: number | string
  total_cost: number | string
  product_name_snapshot: string
  base_uom_name_snapshot: string
  zero_cost_reason: string | null
  notes: string | null
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
  reference_table: string
  reference_id: string
}

type Batch = {
  id: string
  product_id: string
  warehouse_id: string
  qty_purchased: number | string
  qty_remaining: number | string
  cogs_unit: number | string
  opening_stock_line_id: string
}

type MovementPair = {
  product_id: string
  warehouse_id: string
}

type OpeningPayload = {
  data?: OpeningDocument[]
  lines?: OpeningLine[]
  products?: Product[]
  warehouses?: Warehouse[]
  balances?: Balance[]
  movements?: Movement[]
  batches?: Batch[]
  movementPairs?: MovementPair[]
  error?: string
}

type FormLine = {
  key: string
  productId: string
  quantityBase: string
  unitCostBase: string
  zeroCostReason: string
  notes: string
}

function authHeaders(session: Session) {
  return { Authorization: `Bearer ${session.access_token}` }
}

function rupiah(value: number | string) {
  return new Intl.NumberFormat('id-ID', {
    style: 'currency',
    currency: 'IDR',
    maximumFractionDigits: 2,
  }).format(Number(value) || 0)
}

function quantity(value: number | string) {
  return new Intl.NumberFormat('id-ID', { maximumFractionDigits: 6 }).format(
    Number(value) || 0,
  )
}

function friendlyError(code?: string) {
  const messages: Record<string, string> = {
    OPENING_STOCK_PREPARER_REQUIRED:
      'Role Anda tidak diizinkan menyiapkan Stok Awal.',
    OPENING_STOCK_POSTER_REQUIRED:
      'Hanya Owner, Admin Company, atau Super Admin yang dapat melakukan Posting.',
    ACTIVE_WAREHOUSE_NOT_FOUND: 'Gudang tidak aktif atau tidak dapat diakses.',
    ACTIVE_STOCK_PRODUCT_WITH_BASE_UOM_NOT_FOUND:
      'Product stok atau Base UOM sudah tidak aktif.',
    OPENING_STOCK_DUPLICATE_PRODUCT:
      'Satu Product hanya boleh muncul sekali dalam dokumen.',
    OPENING_STOCK_QUANTITY_INVALID: 'Quantity Stok Awal harus lebih dari nol.',
    OPENING_STOCK_QUANTITY_MUST_BE_POSITIVE:
      'Quantity Stok Awal harus lebih dari nol.',
    OPENING_STOCK_QUANTITY_TOO_LARGE: 'Quantity Stok Awal terlalu besar.',
    OPENING_STOCK_UNIT_COST_INVALID: 'HPP per Base UOM tidak valid.',
    OPENING_STOCK_ZERO_COST_REASON_REQUIRED:
      'Isi alasan apabila HPP Stok Awal bernilai nol.',
    OPENING_STOCK_BASE_UOM_REQUIRES_INTEGER:
      'Base UOM Product ini hanya menerima quantity bilangan bulat.',
    OPENING_STOCK_BASE_UOM_PRECISION_EXCEEDED:
      'Jumlah desimal quantity melebihi presisi Base UOM Product.',
    OPENING_STOCK_MOVEMENT_ALREADY_EXISTS:
      'Product dan Gudang ini sudah mempunyai riwayat stok sehingga tidak dapat diberi Stok Awal.',
    OPENING_STOCK_NOT_FOUND: 'Dokumen Stok Awal tidak ditemukan.',
    POSTED_OPENING_STOCK_IMMUTABLE: 'Dokumen ini sudah pernah diposting.',
    OPENING_STOCK_ALREADY_POSTED: 'Dokumen ini sudah pernah diposting.',
    OPENING_STOCK_FUTURE_DATE_NOT_ALLOWED:
      'Tanggal efektif Stok Awal tidak boleh melewati hari ini.',
    OPENING_STOCK_ACCOUNT_NOT_RESOLVED:
      'Akun Finance untuk Stok Awal belum siap. Lengkapi konfigurasi Finance terlebih dahulu.',
    MASTER_VERSION_CONFLICT:
      'Dokumen sudah berubah di tab lain. Muat ulang lalu ulangi tindakan.',
    CUSTOM_PERMISSION_DENIED:
      'Akses Stok Awal untuk tindakan ini dibatasi oleh pengaturan user.',
    FORBIDDEN: 'Role Anda tidak diizinkan mengakses Stok Awal.',
  }
  return messages[code ?? ''] ?? code ?? 'Operasi Stok Awal gagal.'
}

function newLine(productId = ''): FormLine {
  return {
    key: crypto.randomUUID(),
    productId,
    quantityBase: '',
    unitCostBase: '',
    zeroCostReason: '',
    notes: '',
  }
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

export function OpeningStockView({
  session,
  companyId,
  capabilities,
  notify,
}: {
  session: Session
  companyId: string
  capabilities: string[]
  notify: (message: string) => void
}) {
  const [products, setProducts] = useState<Product[]>([])
  const [warehouses, setWarehouses] = useState<Warehouse[]>([])
  const [payload, setPayload] = useState<OpeningPayload>({})
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [editing, setEditing] = useState<OpeningDocument | 'create' | null>(null)
  const [posting, setPosting] = useState<OpeningDocument | null>(null)
  const [detail, setDetail] = useState<OpeningDocument | null>(null)

  const load = useCallback(async () => {
    const response = await fetch('/api/inventory/opening-stock', {
      headers: authHeaders(session),
    })
    const result = (await response.json()) as OpeningPayload
    if (!response.ok) throw new Error(friendlyError(result.error))
    setProducts(result.products ?? [])
    setWarehouses(result.warehouses ?? [])
    setPayload(result)
  }, [session])

  const refresh = useCallback(async () => {
    setLoading(true)
    setError('')
    try {
      await load()
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Gagal memuat Stok Awal.')
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
          setError(caught instanceof Error ? caught.message : 'Gagal memuat Stok Awal.')
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
  const eligibleProducts = products.filter(
    (product) => product.is_active && !product.is_bundle && Boolean(baseUom(product)),
  )
  const movementPairs = new Set(
    (payload.movementPairs ?? []).map(
      (movement) => `${movement.product_id}:${movement.warehouse_id}`,
    ),
  )
  const canCreate = capabilities.includes('CREATE_DRAFT')
  const canEdit = capabilities.includes('EDIT_DRAFT')
  const canPost = capabilities.includes('POST')

  return (
    <>
      <div className="mb-7 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <p className="text-xs font-bold uppercase tracking-[.16em] text-emerald-600">
            Inventory initialization
          </p>
          <h1 className="mt-2 text-2xl font-black tracking-tight text-slate-950 md:text-3xl">
            Stok Awal
          </h1>
          <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-500">
            Catat saldo awal Product per Gudang dalam Base UOM beserta HPP-nya.
            Simpan Draft belum mengubah stok. Stok aktual dan FIFO baru terbentuk
            setelah dokumen diposting.
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
          {canCreate && (
            <button
              onClick={() => setEditing('create')}
              className="inline-flex items-center gap-2 rounded-xl bg-emerald-500 px-4 py-3 text-sm font-bold text-white"
            >
              <FilePlus2 className="h-4 w-4" /> Buat Draft
            </button>
          )}
        </div>
      </div>

      <div className="mb-5 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm leading-6 text-amber-900">
        Posting bersifat final. Setelah ada riwayat stok, koreksi berikutnya harus
        melalui Stock Adjustment, bukan membuat Stok Awal baru.
      </div>
      {error && (
        <div className="mb-5 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-700">
          {error}
        </div>
      )}

      <div className="overflow-x-auto rounded-2xl border border-slate-200 bg-white shadow-sm">
        <table className="w-full min-w-[900px] text-left text-sm">
          <thead className="bg-slate-50 text-xs uppercase tracking-wider text-slate-500">
            <tr>
              <th className="px-5 py-4">Dokumen</th>
              <th className="px-5 py-4">Tanggal</th>
              <th className="px-5 py-4">Gudang</th>
              <th className="px-5 py-4">Isi</th>
              <th className="px-5 py-4">Status</th>
              <th className="px-5 py-4 text-right">Aksi</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {(payload.data ?? []).map((document) => (
              <tr key={document.id}>
                <td className="px-5 py-4">
                  <p className="font-bold text-slate-900">{document.document_no}</p>
                  <p className="mt-1 text-xs text-slate-400">
                    {document.notes || 'Tanpa catatan'}
                  </p>
                </td>
                <td className="px-5 py-4 text-slate-700">
                  {new Date(`${document.effective_date}T00:00:00`).toLocaleDateString('id-ID')}
                </td>
                <td className="px-5 py-4 font-semibold text-slate-700">
                  {warehouseById.get(document.warehouse_id)?.name ?? 'Gudang tidak ditemukan'}
                </td>
                <td className="px-5 py-4">
                  <p className="font-semibold text-slate-700">{document.line_count} Product</p>
                  <p className="mt-1 text-xs text-slate-400">{rupiah(document.total_cost)}</p>
                </td>
                <td className="px-5 py-4">
                  <span className={`inline-flex rounded-full px-2.5 py-1 text-xs font-bold ${
                    document.status === 'POSTED'
                      ? 'bg-emerald-50 text-emerald-700'
                      : 'bg-amber-50 text-amber-700'
                  }`}>
                    {document.status === 'POSTED' ? 'Sudah diposting' : 'Draft'}
                  </span>
                </td>
                <td className="px-5 py-4">
                  <div className="flex justify-end gap-2">
                    <button
                      onClick={() => setDetail(document)}
                      className="inline-flex items-center gap-1.5 rounded-lg border border-slate-200 px-3 py-2 text-xs font-bold text-slate-600"
                    >
                      <Eye className="h-3.5 w-3.5" /> Lihat
                    </button>
                    {document.status === 'DRAFT' && canEdit && (
                      <button
                        onClick={() => setEditing(document)}
                        className="inline-flex items-center gap-1.5 rounded-lg border border-slate-200 px-3 py-2 text-xs font-bold text-slate-600"
                      >
                        <Pencil className="h-3.5 w-3.5" /> Edit
                      </button>
                    )}
                    {document.status === 'DRAFT' && canPost && (
                      <button
                        onClick={() => setPosting(document)}
                        className="inline-flex items-center gap-1.5 rounded-lg bg-emerald-500 px-3 py-2 text-xs font-bold text-white"
                      >
                        <Send className="h-3.5 w-3.5" /> Posting
                      </button>
                    )}
                  </div>
                </td>
              </tr>
            ))}
            {!loading && !(payload.data ?? []).length && (
              <tr>
                <td colSpan={6} className="p-12 text-center text-sm text-slate-400">
                  Belum ada dokumen Stok Awal.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      {editing && (
        <OpeningEditor
          session={session}
          products={eligibleProducts}
          warehouses={warehouses.filter((warehouse) => warehouse.is_active)}
          movementPairs={movementPairs}
          document={editing === 'create' ? undefined : editing}
          existingLines={editing === 'create'
            ? []
            : (payload.lines ?? []).filter((line) => line.document_id === editing.id)}
          close={() => setEditing(null)}
          complete={async () => {
            setEditing(null)
            notify('Draft Stok Awal berhasil disimpan. Stok belum berubah sebelum Posting.')
            await refresh()
          }}
        />
      )}
      {posting && (
        <PostingDialog
          session={session}
          document={posting}
          warehouseName={warehouseById.get(posting.warehouse_id)?.name ?? 'Gudang'}
          close={() => setPosting(null)}
          complete={async () => {
            setPosting(null)
            notify('Stok Awal berhasil diposting dan sudah menjadi stok aktual.')
            await refresh()
          }}
        />
      )}
      {detail && (
        <OpeningDetail
          document={detail}
          warehouseName={warehouseById.get(detail.warehouse_id)?.name ?? 'Gudang'}
          lines={(payload.lines ?? []).filter((line) => line.document_id === detail.id)}
          balances={payload.balances ?? []}
          movements={payload.movements ?? []}
          batches={payload.batches ?? []}
          productById={productById}
          close={() => setDetail(null)}
        />
      )}
    </>
  )
}

function OpeningEditor({
  session,
  products,
  warehouses,
  movementPairs,
  document,
  existingLines,
  close,
  complete,
}: {
  session: Session
  products: Product[]
  warehouses: Warehouse[]
  movementPairs: Set<string>
  document?: OpeningDocument
  existingLines: OpeningLine[]
  close: () => void
  complete: () => Promise<void>
}) {
  useEscapeClose(close)
  const [warehouseId, setWarehouseId] = useState(document?.warehouse_id ?? warehouses[0]?.id ?? '')
  const [effectiveDate, setEffectiveDate] = useState(
    document?.effective_date ?? new Date().toLocaleDateString('en-CA'),
  )
  const [notes, setNotes] = useState(document?.notes ?? '')
  const [lines, setLines] = useState<FormLine[]>(
    existingLines.length
      ? existingLines.map((line) => ({
          key: line.id,
          productId: line.product_id,
          quantityBase: String(line.quantity_base),
          unitCostBase: String(line.unit_cost_base),
          zeroCostReason: line.zero_cost_reason ?? '',
          notes: line.notes ?? '',
        }))
      : [newLine()],
  )
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')
  const selectedProducts = new Set(lines.map((line) => line.productId).filter(Boolean))

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
        document ? `/api/inventory/opening-stock/${document.id}` : '/api/inventory/opening-stock',
        {
          method: document ? 'PATCH' : 'POST',
          headers: { 'Content-Type': 'application/json', ...authHeaders(session) },
          body: JSON.stringify({
            masterVersion: document?.master_version,
            warehouseId,
            effectiveDate,
            notes: notes.trim() || null,
            lines: lines.map((line) => ({
              productId: line.productId,
              quantityBase: line.quantityBase,
              unitCostBase: line.unitCostBase,
              zeroCostReason: line.zeroCostReason.trim() || null,
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
              {document ? `Edit ${document.document_no}` : 'Buat Draft Stok Awal'}
            </h2>
            <p className="mt-2 text-sm leading-6 text-slate-500">
              Quantity dan HPP diisi per Base UOM Product. Menyimpan form ini
              belum menambah stok.
            </p>
          </div>
          <button onClick={close} className="rounded-xl bg-slate-100 p-2 text-slate-500" aria-label="Tutup">
            <X className="h-4 w-4" />
          </button>
        </div>
        <form onSubmit={submit} className="mt-7 space-y-6">
          <div className="grid gap-4 md:grid-cols-2">
            <label className="text-sm font-bold text-slate-700">
              Gudang
              <select
                required
                disabled={Boolean(document)}
                value={warehouseId}
                onChange={(event) => setWarehouseId(event.target.value)}
                className="mt-2 w-full rounded-xl border border-slate-200 bg-white px-4 py-3 disabled:bg-slate-100"
              >
                {warehouses.map((warehouse) => (
                  <option key={warehouse.id} value={warehouse.id}>{warehouse.name}</option>
                ))}
              </select>
            </label>
            <label className="text-sm font-bold text-slate-700">
              Tanggal efektif
              <input
                type="date"
                required
                max={new Date().toLocaleDateString('en-CA')}
                value={effectiveDate}
                onChange={(event) => setEffectiveDate(event.target.value)}
                className="mt-2 w-full rounded-xl border border-slate-200 px-4 py-3"
              />
            </label>
          </div>
          <label className="block text-sm font-bold text-slate-700">
            Catatan dokumen (opsional)
            <input
              value={notes}
              onChange={(event) => setNotes(event.target.value)}
              className="mt-2 w-full rounded-xl border border-slate-200 px-4 py-3"
              placeholder="Contoh: saldo hasil stock opname sebelum go-live"
            />
          </label>

          <div className="space-y-4">
            <div className="flex items-center justify-between">
              <div>
                <h3 className="font-black text-slate-900">Product dan saldo awal</h3>
                <p className="mt-1 text-xs text-slate-500">
                  Product yang sudah memiliki movement pada Gudang ini tidak dapat dipilih.
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
              const choices = products.filter(
                (item) =>
                  item.id === line.productId ||
                  (!selectedProducts.has(item.id) &&
                    !movementPairs.has(`${item.id}:${warehouseId}`)),
              )
              return (
                <div key={line.key} className="rounded-2xl border border-slate-200 bg-slate-50 p-4">
                  <div className="grid gap-4 lg:grid-cols-[1.7fr_1fr_1fr_auto]">
                    <label className="text-sm font-bold text-slate-700">
                      Product
                      <select
                        required
                        value={line.productId}
                        onChange={(event) => updateLine(line.key, { productId: event.target.value })}
                        className="mt-2 w-full rounded-xl border border-slate-200 bg-white px-3 py-3"
                      >
                        <option value="">Pilih Product</option>
                        {choices.map((item) => (
                          <option key={item.id} value={item.id}>{item.name} ({item.sku})</option>
                        ))}
                      </select>
                    </label>
                    <label className="text-sm font-bold text-slate-700">
                      Qty ({uom?.name ?? 'Base UOM'})
                      <input
                        required
                        type="number"
                        min="0"
                        step={uom?.allow_decimal ? 10 ** -(uom.decimal_precision || 1) : 1}
                        value={line.quantityBase}
                        onChange={(event) => updateLine(line.key, { quantityBase: event.target.value })}
                        className="mt-2 w-full rounded-xl border border-slate-200 bg-white px-3 py-3"
                      />
                    </label>
                    <label className="text-sm font-bold text-slate-700">
                      HPP per {uom?.name ?? 'Base UOM'}
                      <input
                        required
                        type="number"
                        min="0"
                        step="0.000001"
                        value={line.unitCostBase}
                        onChange={(event) => updateLine(line.key, { unitCostBase: event.target.value })}
                        className="mt-2 w-full rounded-xl border border-slate-200 bg-white px-3 py-3"
                      />
                    </label>
                    <button
                      type="button"
                      disabled={lines.length === 1}
                      onClick={() => setLines((current) => current.filter((item) => item.key !== line.key))}
                      className="mt-7 grid h-11 w-11 place-items-center rounded-xl text-rose-500 disabled:opacity-30"
                      aria-label={`Hapus baris ${index + 1}`}
                    >
                      <Trash2 className="h-4 w-4" />
                    </button>
                  </div>
                  {Number(line.unitCostBase) === 0 && line.unitCostBase !== '' && (
                    <label className="mt-4 block text-sm font-bold text-slate-700">
                      Alasan HPP nol
                      <input
                        required
                        value={line.zeroCostReason}
                        onChange={(event) => updateLine(line.key, { zeroCostReason: event.target.value })}
                        placeholder="Contoh: barang bonus dari Supplier"
                        className="mt-2 w-full rounded-xl border border-amber-200 bg-white px-3 py-3"
                      />
                    </label>
                  )}
                </div>
              )
            })}
          </div>
          {error && <div className="rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-700">{error}</div>}
          <div className="flex justify-end gap-3 border-t border-slate-100 pt-5">
            <button type="button" onClick={close} className="rounded-xl border border-slate-200 px-4 py-2.5 text-sm font-bold text-slate-600">Batal</button>
            <button disabled={saving || !warehouseId || !lines.length} className="inline-flex items-center gap-2 rounded-xl bg-emerald-500 px-5 py-2.5 text-sm font-bold text-white disabled:opacity-50">
              {saving && <Loader2 className="h-4 w-4 animate-spin" />}
              Simpan Draft
            </button>
          </div>
        </form>
      </div>
    </div>
  )
}

function PostingDialog({
  session,
  document,
  warehouseName,
  close,
  complete,
}: {
  session: Session
  document: OpeningDocument
  warehouseName: string
  close: () => void
  complete: () => Promise<void>
}) {
  useEscapeClose(close)
  const [confirmed, setConfirmed] = useState(false)
  const [idempotencyKey] = useState(() => crypto.randomUUID())
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')

  async function post() {
    setSaving(true)
    setError('')
    try {
      const response = await fetch(`/api/inventory/opening-stock/${document.id}/post`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', ...authHeaders(session) },
        body: JSON.stringify({
          masterVersion: document.master_version,
          idempotencyKey,
        }),
      })
      const result = (await response.json()) as { error?: string }
      if (!response.ok) throw new Error(friendlyError(result.error))
      await complete()
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Posting Stok Awal gagal.')
    } finally {
      setSaving(false)
    }
  }

  return (
    <div className="fixed inset-0 z-[80] grid place-items-center bg-slate-950/50 p-4 backdrop-blur-sm">
      <div className="w-full max-w-xl rounded-3xl bg-white p-7 shadow-2xl">
        <div className="flex items-start justify-between gap-4">
          <div>
            <h2 className="text-xl font-black text-slate-950">Posting Stok Awal?</h2>
            <p className="mt-2 text-sm leading-6 text-slate-500">
              {document.document_no} · {warehouseName} · {document.line_count} Product
            </p>
          </div>
          <button onClick={close} className="rounded-xl bg-slate-100 p-2 text-slate-500" aria-label="Tutup">
            <X className="h-4 w-4" />
          </button>
        </div>
        <div className="mt-5 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm leading-6 text-amber-900">
          Posting akan membuat stok aktual, Stock Movement, FIFO layer, dan event
          Finance. Dokumen tidak dapat diedit setelah diposting.
        </div>
        <label className="mt-5 flex items-start gap-3 rounded-2xl border border-slate-200 p-4">
          <input
            type="checkbox"
            checked={confirmed}
            onChange={(event) => setConfirmed(event.target.checked)}
            className="mt-1 h-4 w-4 accent-emerald-500"
          />
          <span className="text-sm font-semibold leading-6 text-slate-700">
            Saya sudah memeriksa Gudang, Product, quantity, dan HPP serta memahami
            bahwa koreksi berikutnya harus melalui Stock Adjustment.
          </span>
        </label>
        {error && <div className="mt-4 rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-700">{error}</div>}
        <div className="mt-6 flex justify-end gap-3">
          <button onClick={close} className="rounded-xl border border-slate-200 px-4 py-2.5 text-sm font-bold text-slate-600">Batal</button>
          <button
            disabled={!confirmed || saving}
            onClick={() => void post()}
            className="inline-flex items-center gap-2 rounded-xl bg-emerald-500 px-5 py-2.5 text-sm font-bold text-white disabled:opacity-50"
          >
            {saving ? <Loader2 className="h-4 w-4 animate-spin" /> : <Send className="h-4 w-4" />}
            Posting sekarang
          </button>
        </div>
      </div>
    </div>
  )
}

function OpeningDetail({
  document,
  warehouseName,
  lines,
  balances,
  movements,
  batches,
  productById,
  close,
}: {
  document: OpeningDocument
  warehouseName: string
  lines: OpeningLine[]
  balances: Balance[]
  movements: Movement[]
  batches: Batch[]
  productById: Map<string, Product>
  close: () => void
}) {
  useEscapeClose(close)
  return (
    <div className="fixed inset-0 z-[70] grid place-items-center bg-slate-950/45 p-4 backdrop-blur-sm">
      <div className="max-h-[94vh] w-full max-w-5xl overflow-y-auto rounded-3xl bg-white p-6 shadow-2xl sm:p-8">
        <div className="flex items-start justify-between gap-4">
          <div>
            <div className="flex items-center gap-2">
              <PackagePlus className="h-5 w-5 text-emerald-600" />
              <h2 className="text-xl font-black text-slate-950">{document.document_no}</h2>
            </div>
            <p className="mt-2 text-sm text-slate-500">
              {warehouseName} · {document.status === 'POSTED' ? 'Sudah diposting' : 'Draft'}
            </p>
          </div>
          <button onClick={close} className="rounded-xl bg-slate-100 p-2 text-slate-500" aria-label="Tutup">
            <X className="h-4 w-4" />
          </button>
        </div>
        {document.status === 'POSTED' && (
          <div className="mt-5 flex items-center gap-3 rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-sm text-emerald-800">
            <CheckCircle2 className="h-5 w-5" />
            Saldo aktual, movement, dan FIFO sudah terbentuk.
          </div>
        )}
        <div className="mt-6 overflow-x-auto rounded-2xl border border-slate-200">
          <table className="w-full min-w-[900px] text-left text-sm">
            <thead className="bg-slate-50 text-xs uppercase tracking-wider text-slate-500">
              <tr>
                <th className="px-4 py-3">Product</th>
                <th className="px-4 py-3">Stok awal</th>
                <th className="px-4 py-3">HPP</th>
                <th className="px-4 py-3">Stok aktual</th>
                <th className="px-4 py-3">Movement</th>
                <th className="px-4 py-3">FIFO tersisa</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {lines.map((line) => {
                const product = productById.get(line.product_id)
                const balance = balances.find(
                  (row) =>
                    row.product_id === line.product_id &&
                    row.warehouse_id === document.warehouse_id,
                )
                const movement = movements.find(
                  (row) =>
                    row.reference_table === 'opening_stock_documents' &&
                    row.reference_id === document.id &&
                    row.product_id === line.product_id,
                )
                const batch = batches.find(
                  (row) => row.opening_stock_line_id === line.id,
                )
                return (
                  <tr key={line.id}>
                    <td className="px-4 py-4">
                      <p className="font-bold text-slate-900">{product?.name ?? line.product_name_snapshot}</p>
                      <p className="mt-1 text-xs text-slate-400">{line.base_uom_name_snapshot}</p>
                    </td>
                    <td className="px-4 py-4 font-bold text-slate-800">
                      {quantity(line.quantity_base)} {line.base_uom_name_snapshot}
                    </td>
                    <td className="px-4 py-4">
                      <p>{rupiah(line.unit_cost_base)}</p>
                      <p className="mt-1 text-xs text-slate-400">Total {rupiah(line.total_cost)}</p>
                    </td>
                    <td className="px-4 py-4 font-bold text-slate-800">
                      {balance ? `${quantity(balance.stock_qty)} ${line.base_uom_name_snapshot}` : '-'}
                    </td>
                    <td className="px-4 py-4">
                      {movement ? `${quantity(movement.qty_change)} · ${movement.movement_type}` : '-'}
                    </td>
                    <td className="px-4 py-4">
                      {batch ? `${quantity(batch.qty_remaining)} · ${rupiah(batch.cogs_unit)}` : '-'}
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
        <div className="mt-6 flex justify-end">
          <button onClick={close} className="rounded-xl border border-slate-200 px-5 py-2.5 text-sm font-bold text-slate-600">Tutup</button>
        </div>
      </div>
    </div>
  )
}
