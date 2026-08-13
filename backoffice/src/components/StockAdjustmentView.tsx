'use client'

import { useCallback, useEffect, useMemo, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import {
  CheckCircle2,
  ClipboardPenLine,
  Eye,
  FilePlus2,
  Loader2,
  Pencil,
  Plus,
  RefreshCcw,
  Send,
  Trash2,
  TriangleAlert,
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
type Reason = {
  id: string
  reason_name: string
  direction_allowed: 'INCREASE' | 'DECREASE' | 'BOTH'
  finance_treatment: string
  is_active: boolean
}
type AdjustmentDocument = {
  id: string
  document_no: string
  warehouse_id: string
  adjustment_date: string
  status: 'DRAFT' | 'POSTED' | 'CANCELED'
  notes: string | null
  line_count: number
  total_gain_quantity_base: number | string
  total_loss_quantity_base: number | string
  total_gain_value: number | string
  total_loss_value: number | string
  master_version: number
  posted_at: string | null
  canceled_at: string | null
}
type AdjustmentLine = {
  id: string
  document_id: string
  line_no: number
  product_id: string
  reason_id: string
  system_quantity_snapshot: number | string
  final_physical_quantity: number | string
  calculated_difference: number | string
  unit_cost_base: number | string
  total_value: number | string
  cost_override_reason: string | null
  fifo_layer_count: number
  product_sku_snapshot: string
  product_name_snapshot: string
  base_uom_name_snapshot: string
  reason_name_snapshot: string
  notes: string | null
}
type Allocation = {
  id: number
  document_id: string
  line_id: string
  direction: 'GAIN' | 'LOSS'
  quantity_base: number | string
  unit_cost_base: number | string
  total_value: number | string
}
type Balance = {
  product_id: string
  warehouse_id: string
  stock_qty: number | string
}
type Movement = {
  id: string
  product_id: string
  qty_change: number | string
  balance_after_base_qty: number | string | null
}
type Payload = {
  data?: AdjustmentDocument[]
  lines?: AdjustmentLine[]
  allocations?: Allocation[]
  balances?: Balance[]
  movements?: Movement[]
  reasons?: Reason[]
  error?: string
}
type FormLine = {
  key: string
  productId: string
  reasonId: string
  finalPhysicalQuantity: string
  unitCostBase: string
  costOverrideReason: string
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
function newLine(): FormLine {
  return {
    key: crypto.randomUUID(),
    productId: '',
    reasonId: '',
    finalPhysicalQuantity: '',
    unitCostBase: '',
    costOverrideReason: '',
    notes: '',
  }
}
function friendlyError(code?: string) {
  const messages: Record<string, string> = {
    STOCK_ADJUSTMENT_OPERATOR_REQUIRED:
      'Role atau cakupan Gudang Anda tidak diizinkan membuat Penyesuaian Stok.',
    STOCK_ADJUSTMENT_DATE_INVALID: 'Tanggal penyesuaian tidak valid.',
    STOCK_ADJUSTMENT_FUTURE_DATE_NOT_ALLOWED:
      'Tanggal penyesuaian tidak boleh melewati hari ini.',
    STOCK_ADJUSTMENT_LINES_REQUIRED: 'Tambahkan minimal satu Product.',
    STOCK_ADJUSTMENT_DUPLICATE_PRODUCT:
      'Satu Product hanya boleh muncul sekali dalam dokumen.',
    STOCK_ADJUSTMENT_FINAL_QUANTITY_INVALID:
      'Stok fisik akhir harus berupa angka nol atau lebih.',
    STOCK_ADJUSTMENT_FINAL_QUANTITY_MUST_BE_NONNEGATIVE:
      'Stok fisik akhir tidak boleh negatif.',
    STOCK_ADJUSTMENT_NO_DIFFERENCE:
      'Stok fisik akhir sama dengan stok sistem. Tidak ada penyesuaian.',
    STOCK_ADJUSTMENT_REASON_DIRECTION_MISMATCH:
      'Alasan yang dipilih tidak sesuai arah stok bertambah/berkurang.',
    ACTIVE_STOCK_ADJUSTMENT_REASON_NOT_FOUND:
      'Alasan penyesuaian sudah tidak aktif atau tidak tersedia.',
    ACTIVE_STOCK_PRODUCT_WITH_BASE_UOM_NOT_FOUND:
      'Product stok atau Base UOM sudah tidak aktif.',
    STOCK_ADJUSTMENT_BASE_UOM_REQUIRES_INTEGER:
      'Base UOM Product ini hanya menerima bilangan bulat.',
    STOCK_ADJUSTMENT_BASE_UOM_PRECISION_EXCEEDED:
      'Jumlah desimal melebihi presisi Base UOM.',
    STOCK_ADJUSTMENT_COST_OVERRIDE_REASON_REQUIRED:
      'Isi alasan perubahan biaya jika biaya per Base UOM diisi manual.',
    STOCK_ADJUSTMENT_STOCK_CHANGED:
      'Stok berubah setelah Draft dibuat. Edit dan simpan ulang Draft sebelum Posting.',
    INSUFFICIENT_STOCK: 'Stok aktual tidak cukup untuk selisih keluar.',
    INSUFFICIENT_FIFO_STOCK: 'Layer FIFO tidak cukup atau tidak sinkron.',
    STOCK_ADJUSTMENT_NOT_FOUND: 'Dokumen Penyesuaian Stok tidak ditemukan.',
    FINAL_STOCK_ADJUSTMENT_IMMUTABLE:
      'Dokumen yang sudah final tidak dapat diubah.',
    CANCELED_STOCK_ADJUSTMENT_IMMUTABLE:
      'Dokumen yang dibatalkan tidak dapat diposting.',
    MASTER_VERSION_CONFLICT:
      'Dokumen berubah di tab lain. Muat ulang lalu ulangi tindakan.',
    FORBIDDEN: 'Role Anda tidak diizinkan mengakses Penyesuaian Stok.',
  }
  return messages[code ?? ''] ?? code ?? 'Operasi Penyesuaian Stok gagal.'
}

export function StockAdjustmentView({
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
  const [payload, setPayload] = useState<Payload>({})
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [editing, setEditing] = useState<AdjustmentDocument | 'create' | null>(
    null,
  )
  const [posting, setPosting] = useState<AdjustmentDocument | null>(null)
  const [canceling, setCanceling] = useState<AdjustmentDocument | null>(null)
  const [detail, setDetail] = useState<AdjustmentDocument | null>(null)

  const load = useCallback(async () => {
    const response = await fetch('/api/inventory/stock-adjustments', {
      headers: authHeaders(session),
    })
    const result = (await response.json()) as Payload & {
      products?: Product[]
      warehouses?: Warehouse[]
    }
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
      setError(
        caught instanceof Error
          ? caught.message
          : 'Gagal memuat Penyesuaian Stok.',
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
              : 'Gagal memuat Penyesuaian Stok.',
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
  const drafts = (payload.data ?? []).filter((row) => row.status === 'DRAFT').length
  const posted = (payload.data ?? []).filter(
    (row) => row.status === 'POSTED',
  ).length
  const canCreate = capabilities.includes('CREATE_DRAFT')
  const canEdit = capabilities.includes('EDIT_DRAFT')
  const canPost = capabilities.includes('POST')
  const canCancel = capabilities.includes('CANCEL_FINAL')
  const canOperate = canCreate || canEdit || canPost || canCancel

  return (
    <>
      <div className="mb-7 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <p className="text-xs font-bold uppercase tracking-[.16em] text-emerald-600">
            Inventory operation
          </p>
          <h1 className="mt-2 text-2xl font-black tracking-tight text-slate-950 md:text-3xl">
            Penyesuaian Stok
          </h1>
          <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-500">
            Isi hasil hitung fisik akhir. Sistem membandingkannya dengan stok
            sekarang dan menentukan selisih masuk atau keluar secara otomatis.
            Draft belum mengubah stok.
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
              <FilePlus2 className="h-4 w-4" /> Buat Penyesuaian
            </button>
          )}
        </div>
      </div>

      {!canOperate && (
        <div className="mb-5 rounded-2xl border border-blue-200 bg-blue-50 p-4 text-sm text-blue-800">
          Anda memiliki akses baca. Mutation hanya tersedia untuk Owner/Admin
          Company atau Store Manager pada Gudang Store dalam assignment.
        </div>
      )}
      {error && (
        <div className="mb-5 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-700">
          {error}
        </div>
      )}

      <div className="mb-5 grid gap-4 sm:grid-cols-3">
        <Summary label="Total dokumen" value={String((payload.data ?? []).length)} />
        <Summary label="Draft" value={String(drafts)} />
        <Summary label="Sudah diposting" value={String(posted)} />
      </div>

      <div className="overflow-x-auto rounded-2xl border border-slate-200 bg-white shadow-sm">
        <table className="w-full min-w-[1050px] text-left text-sm">
          <thead className="bg-slate-50 text-xs uppercase tracking-wider text-slate-500">
            <tr>
              <th className="px-5 py-4">Dokumen</th>
              <th className="px-5 py-4">Tanggal</th>
              <th className="px-5 py-4">Gudang</th>
              <th className="px-5 py-4">Selisih</th>
              <th className="px-5 py-4">Status</th>
              <th className="px-5 py-4 text-right">Aksi</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {(payload.data ?? []).map((document) => (
              <tr key={document.id}>
                <td className="px-5 py-4">
                  <p className="font-black text-slate-900">{document.document_no}</p>
                  <p className="mt-1 text-xs text-slate-400">
                    {document.line_count} Product · {document.notes || 'Tanpa catatan'}
                  </p>
                </td>
                <td className="px-5 py-4 text-slate-700">
                  {new Date(
                    `${document.adjustment_date}T00:00:00`,
                  ).toLocaleDateString('id-ID')}
                </td>
                <td className="px-5 py-4 font-bold text-slate-700">
                  {warehouseById.get(document.warehouse_id)?.name ??
                    'Gudang tidak tersedia'}
                </td>
                <td className="px-5 py-4">
                  <p className="font-bold text-emerald-700">
                    Masuk +{qty(document.total_gain_quantity_base)}
                  </p>
                  <p className="mt-1 text-xs font-bold text-rose-600">
                    Keluar -{qty(document.total_loss_quantity_base)}
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
                    {document.status === 'DRAFT' &&
                      (canEdit || canPost || canCancel) && (
                      <>
                        {canEdit && <button
                          onClick={() => setEditing(document)}
                          className="rounded-xl border border-slate-200 p-2 text-blue-600"
                          aria-label={`Edit ${document.document_no}`}
                        >
                          <Pencil className="h-4 w-4" />
                        </button>}
                        {canPost && <button
                          onClick={() => setPosting(document)}
                          className="rounded-xl bg-emerald-500 p-2 text-white"
                          aria-label={`Posting ${document.document_no}`}
                        >
                          <Send className="h-4 w-4" />
                        </button>}
                        {canCancel && <button
                          onClick={() => setCanceling(document)}
                          className="rounded-xl border border-rose-200 p-2 text-rose-600"
                          aria-label={`Batalkan ${document.document_no}`}
                        >
                          <XCircle className="h-4 w-4" />
                        </button>}
                      </>
                    )}
                  </div>
                </td>
              </tr>
            ))}
            {!loading && !(payload.data ?? []).length && (
              <tr>
                <td colSpan={6} className="px-5 py-12 text-center text-slate-400">
                  Belum ada dokumen Penyesuaian Stok.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      {editing && (
        <AdjustmentForm
          session={session}
          document={editing === 'create' ? null : editing}
          documentLines={
            editing === 'create'
              ? []
              : (payload.lines ?? []).filter((row) => row.document_id === editing.id)
          }
          products={activeProducts}
          warehouses={activeWarehouses}
          reasons={(payload.reasons ?? []).filter((reason) => reason.is_active)}
          balances={payload.balances ?? []}
          close={() => setEditing(null)}
          complete={async () => {
            setEditing(null)
            await refresh()
            notify('Draft Penyesuaian Stok berhasil disimpan.')
          }}
        />
      )}
      {(posting || canceling) && (
        <ActionDialog
          session={session}
          document={(posting ?? canceling)!}
          action={posting ? 'post' : 'cancel'}
          warehouseName={
            warehouseById.get((posting ?? canceling)!.warehouse_id)?.name ??
            'Gudang'
          }
          close={() => {
            setPosting(null)
            setCanceling(null)
          }}
          complete={async () => {
            const action = posting ? 'diposting' : 'dibatalkan'
            setPosting(null)
            setCanceling(null)
            await refresh()
            notify(`Penyesuaian Stok berhasil ${action}.`)
          }}
        />
      )}
      {detail && (
        <AdjustmentDetail
          document={detail}
          warehouseName={warehouseById.get(detail.warehouse_id)?.name ?? 'Gudang'}
          lines={(payload.lines ?? []).filter(
            (row) => row.document_id === detail.id,
          )}
          allocations={(payload.allocations ?? []).filter(
            (row) => row.document_id === detail.id,
          )}
          movements={payload.movements ?? []}
          productById={productById}
          close={() => setDetail(null)}
        />
      )}
    </>
  )
}

function AdjustmentForm({
  session,
  document,
  documentLines,
  products,
  warehouses,
  reasons,
  balances,
  close,
  complete,
}: {
  session: Session
  document: AdjustmentDocument | null
  documentLines: AdjustmentLine[]
  products: Product[]
  warehouses: Warehouse[]
  reasons: Reason[]
  balances: Balance[]
  close: () => void
  complete: () => Promise<void>
}) {
  useEscapeClose(close)
  const [warehouseId, setWarehouseId] = useState(document?.warehouse_id ?? '')
  const [adjustmentDate, setAdjustmentDate] = useState(
    document?.adjustment_date ?? new Date().toLocaleDateString('en-CA'),
  )
  const [notes, setNotes] = useState(document?.notes ?? '')
  const [lines, setLines] = useState<FormLine[]>(
    documentLines.length
      ? documentLines.map((line) => ({
          key: line.id,
          productId: line.product_id,
          reasonId: line.reason_id,
          finalPhysicalQuantity: String(line.final_physical_quantity),
          unitCostBase:
            Number(line.calculated_difference) > 0
              ? String(line.unit_cost_base)
              : '',
          costOverrideReason: line.cost_override_reason ?? '',
          notes: line.notes ?? '',
        }))
      : [newLine()],
  )
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')

  const stock = (productId: string) =>
    Number(
      balances.find(
        (row) =>
          row.product_id === productId && row.warehouse_id === warehouseId,
      )?.stock_qty ?? 0,
    )
  const updateLine = (key: string, patch: Partial<FormLine>) =>
    setLines((current) =>
      current.map((line) => (line.key === key ? { ...line, ...patch } : line)),
    )
  const selected = new Set(lines.map((line) => line.productId).filter(Boolean))

  async function submit(event: React.FormEvent) {
    event.preventDefault()
    setSaving(true)
    setError('')
    try {
      for (const line of lines) {
        const difference = Number(line.finalPhysicalQuantity) - stock(line.productId)
        if (difference === 0) {
          throw new Error(
            'Ada Product dengan stok fisik sama seperti stok sistem. Hapus baris tersebut.',
          )
        }
        const reason = reasons.find((item) => item.id === line.reasonId)
        if (
          (difference > 0 && reason?.direction_allowed === 'DECREASE') ||
          (difference < 0 && reason?.direction_allowed === 'INCREASE')
        ) {
          throw new Error('Alasan tidak sesuai dengan arah selisih stok.')
        }
        if (difference > 0 && line.unitCostBase && !line.costOverrideReason.trim()) {
          throw new Error('Biaya manual wajib disertai alasan perubahan biaya.')
        }
      }
      const response = await fetch(
        document
          ? `/api/inventory/stock-adjustments/${document.id}`
          : '/api/inventory/stock-adjustments',
        {
          method: document ? 'PATCH' : 'POST',
          headers: {
            'Content-Type': 'application/json',
            ...authHeaders(session),
          },
          body: JSON.stringify({
            ...(document ? { masterVersion: document.master_version } : {}),
            warehouseId,
            adjustmentDate,
            notes,
            lines: lines.map((line) => {
              const difference =
                Number(line.finalPhysicalQuantity) - stock(line.productId)
              return {
                productId: line.productId,
                reasonId: line.reasonId,
                finalPhysicalQuantity: line.finalPhysicalQuantity,
                unitCostBase: difference > 0 ? line.unitCostBase || null : null,
                costOverrideReason:
                  difference > 0 ? line.costOverrideReason || null : null,
                notes: line.notes || null,
              }
            }),
          }),
        },
      )
      const result = (await response.json()) as { error?: string }
      if (!response.ok) throw new Error(friendlyError(result.error))
      await complete()
    } catch (caught) {
      setError(
        caught instanceof Error ? caught.message : 'Gagal menyimpan Draft.',
      )
    } finally {
      setSaving(false)
    }
  }

  return (
    <div className="fixed inset-0 z-[70] grid place-items-center bg-slate-950/45 p-4 backdrop-blur-sm">
      <div className="max-h-[94vh] w-full max-w-6xl overflow-y-auto rounded-3xl bg-white p-6 shadow-2xl sm:p-8">
        <div className="flex items-start justify-between gap-4">
          <div>
            <h2 className="text-xl font-black text-slate-950">
              {document ? `Edit ${document.document_no}` : 'Buat Penyesuaian Stok'}
            </h2>
            <p className="mt-2 text-sm leading-6 text-slate-500">
              Pilih Gudang lalu isi jumlah yang benar-benar ditemukan secara
              fisik. Selisih dihitung otomatis.
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
        <form onSubmit={submit} className="mt-6 space-y-6">
          <div className="grid gap-4 md:grid-cols-2">
            <label className="text-sm font-bold text-slate-700">
              Gudang yang dihitung
              <select
                required
                value={warehouseId}
                onChange={(event) => setWarehouseId(event.target.value)}
                className="mt-2 w-full rounded-xl border border-slate-200 bg-white px-4 py-3"
              >
                <option value="">Pilih Gudang</option>
                {warehouses.map((warehouse) => (
                  <option key={warehouse.id} value={warehouse.id}>
                    {warehouse.name}
                  </option>
                ))}
              </select>
            </label>
            <label className="text-sm font-bold text-slate-700">
              Tanggal penyesuaian
              <input
                required
                type="date"
                max={new Date().toLocaleDateString('en-CA')}
                value={adjustmentDate}
                onChange={(event) => setAdjustmentDate(event.target.value)}
                className="mt-2 w-full rounded-xl border border-slate-200 px-4 py-3"
              />
            </label>
          </div>
          <label className="block text-sm font-bold text-slate-700">
            Catatan dokumen (opsional)
            <input
              value={notes}
              onChange={(event) => setNotes(event.target.value)}
              placeholder="Contoh: koreksi hasil pemeriksaan harian"
              className="mt-2 w-full rounded-xl border border-slate-200 px-4 py-3"
            />
          </label>

          <div className="rounded-2xl border border-blue-200 bg-blue-50 p-4 text-sm leading-6 text-blue-900">
            <strong>Contoh:</strong> stok sistem 10 Ketul, hasil fisik 7 Ketul.
            Isi <strong>7</strong> pada Stok fisik akhir; sistem menghasilkan
            selisih keluar 3 Ketul. Jangan isi -3.
          </div>

          <div className="space-y-4">
            <div className="flex items-center justify-between">
              <div>
                <h3 className="font-black text-slate-900">Hasil hitung fisik</h3>
                <p className="mt-1 text-xs text-slate-500">
                  Semua quantity menggunakan nama Base UOM Product.
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
              const systemStock = stock(line.productId)
              const finalQty = Number(line.finalPhysicalQuantity)
              const difference =
                line.productId && line.finalPhysicalQuantity !== ''
                  ? finalQty - systemStock
                  : null
              const choices = products.filter(
                (item) => item.id === line.productId || !selected.has(item.id),
              )
              const allowedReasons = reasons.filter(
                (reason) =>
                  difference === null ||
                  difference === 0 ||
                  reason.direction_allowed === 'BOTH' ||
                  (difference > 0 && reason.direction_allowed === 'INCREASE') ||
                  (difference < 0 && reason.direction_allowed === 'DECREASE'),
              )
              return (
                <div
                  key={line.key}
                  className="rounded-2xl border border-slate-200 bg-slate-50 p-4"
                >
                  <div className="grid gap-4 lg:grid-cols-[1.5fr_1fr_1fr_1.3fr_auto]">
                    <label className="text-sm font-bold text-slate-700">
                      Product
                      <select
                        required
                        value={line.productId}
                        onChange={(event) =>
                          updateLine(line.key, {
                            productId: event.target.value,
                            reasonId: '',
                            finalPhysicalQuantity: '',
                            unitCostBase: '',
                            costOverrideReason: '',
                          })
                        }
                        className="mt-2 w-full rounded-xl border border-slate-200 bg-white px-3 py-3"
                      >
                        <option value="">Pilih Product</option>
                        {choices.map((item) => (
                          <option key={item.id} value={item.id}>
                            {item.name} ({item.sku})
                          </option>
                        ))}
                      </select>
                    </label>
                    <div className="text-sm font-bold text-slate-700">
                      Stok sistem
                      <div className="mt-2 rounded-xl border border-slate-200 bg-white px-3 py-3">
                        {line.productId
                          ? `${qty(systemStock)} ${uom?.name ?? ''}`
                          : '-'}
                      </div>
                    </div>
                    <label className="text-sm font-bold text-slate-700">
                      Stok fisik akhir
                      <input
                        required
                        type="number"
                        min="0"
                        step={
                          uom?.allow_decimal
                            ? 10 ** -(uom.decimal_precision || 1)
                            : 1
                        }
                        value={line.finalPhysicalQuantity}
                        onChange={(event) =>
                          updateLine(line.key, {
                            finalPhysicalQuantity: event.target.value,
                            reasonId: '',
                          })
                        }
                        className="mt-2 w-full rounded-xl border border-slate-200 bg-white px-3 py-3"
                      />
                    </label>
                    <label className="text-sm font-bold text-slate-700">
                      Alasan
                      <select
                        required
                        value={line.reasonId}
                        onChange={(event) =>
                          updateLine(line.key, { reasonId: event.target.value })
                        }
                        className="mt-2 w-full rounded-xl border border-slate-200 bg-white px-3 py-3"
                      >
                        <option value="">Pilih alasan</option>
                        {allowedReasons.map((reason) => (
                          <option key={reason.id} value={reason.id}>
                            {reason.reason_name}
                          </option>
                        ))}
                      </select>
                    </label>
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
                  <div
                    className={`mt-4 rounded-xl border p-3 text-sm font-bold ${
                      difference === null || difference === 0
                        ? 'border-slate-200 bg-white text-slate-500'
                        : difference > 0
                          ? 'border-emerald-200 bg-emerald-50 text-emerald-700'
                          : 'border-rose-200 bg-rose-50 text-rose-700'
                    }`}
                  >
                    {difference === null
                      ? 'Pilih Product dan isi stok fisik akhir.'
                      : difference === 0
                        ? 'Tidak ada selisih — baris ini tidak dapat disimpan.'
                        : difference > 0
                          ? `Stok bertambah +${qty(difference)} ${uom?.name ?? ''}`
                          : `Stok berkurang -${qty(Math.abs(difference))} ${uom?.name ?? ''}`}
                  </div>
                  {difference !== null && difference > 0 && (
                    <div className="mt-4 grid gap-4 md:grid-cols-2">
                      <label className="text-sm font-bold text-slate-700">
                        Biaya per {uom?.name ?? 'Base UOM'} (opsional)
                        <input
                          type="number"
                          min="0"
                          step="0.000001"
                          value={line.unitCostBase}
                          onChange={(event) =>
                            updateLine(line.key, {
                              unitCostBase: event.target.value,
                            })
                          }
                          placeholder="Kosongkan untuk biaya terbaru sistem"
                          className="mt-2 w-full rounded-xl border border-slate-200 bg-white px-3 py-3"
                        />
                      </label>
                      <label className="text-sm font-bold text-slate-700">
                        Alasan biaya manual
                        <input
                          value={line.costOverrideReason}
                          onChange={(event) =>
                            updateLine(line.key, {
                              costOverrideReason: event.target.value,
                            })
                          }
                          required={Boolean(line.unitCostBase)}
                          placeholder="Wajib jika biaya diisi manual"
                          className="mt-2 w-full rounded-xl border border-slate-200 bg-white px-3 py-3"
                        />
                      </label>
                    </div>
                  )}
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
              disabled={saving || !warehouseId || !lines.length}
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
  warehouseName,
  close,
  complete,
}: {
  session: Session
  document: AdjustmentDocument
  action: 'post' | 'cancel'
  warehouseName: string
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
        `/api/inventory/stock-adjustments/${document.id}/${action}`,
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
        caught instanceof Error ? caught.message : 'Tindakan Adjustment gagal.',
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
              {posting ? 'Posting Penyesuaian Stok?' : 'Batalkan Draft?'}
            </h2>
            <p className="mt-2 text-sm text-slate-500">
              {document.document_no} · {warehouseName}
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
            ? 'Posting bersifat final. Saldo akan menjadi jumlah fisik akhir; FIFO, Kartu Stok, dan event Finance HOLD dibuat secara atomic.'
            : 'Pembatalan hanya mengubah status Draft dan tidak menyentuh stok.'}
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
              ? 'Saya sudah memeriksa Gudang, stok sistem, hasil fisik akhir, alasan, dan biaya gain bila ada.'
              : 'Saya yakin Draft ini boleh dibatalkan.'}
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

function AdjustmentDetail({
  document,
  warehouseName,
  lines,
  allocations,
  movements,
  productById,
  close,
}: {
  document: AdjustmentDocument
  warehouseName: string
  lines: AdjustmentLine[]
  allocations: Allocation[]
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
              <ClipboardPenLine className="h-5 w-5 text-emerald-600" />
              <h2 className="text-xl font-black text-slate-950">
                {document.document_no}
              </h2>
            </div>
            <p className="mt-2 text-sm text-slate-500">
              {warehouseName} · <StatusBadge status={document.status} />
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
            Final: saldo, FIFO, Kartu Stok, dan event Finance HOLD sudah terbentuk.
          </div>
        )}
        {document.status === 'DRAFT' && (
          <div className="mt-5 flex items-center gap-3 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-900">
            <TriangleAlert className="h-5 w-5" />
            Draft belum mengubah saldo. Posting akan menolak jika stok sistem
            berubah sejak Draft disimpan.
          </div>
        )}
        <div className="mt-6 overflow-x-auto rounded-2xl border border-slate-200">
          <table className="w-full min-w-[1150px] text-left text-sm">
            <thead className="bg-slate-50 text-xs uppercase tracking-wider text-slate-500">
              <tr>
                <th className="px-4 py-3">Product</th>
                <th className="px-4 py-3">Stok sistem</th>
                <th className="px-4 py-3">Stok fisik akhir</th>
                <th className="px-4 py-3">Selisih</th>
                <th className="px-4 py-3">Alasan</th>
                <th className="px-4 py-3">FIFO</th>
                <th className="px-4 py-3">Nilai</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {lines.map((line) => {
                const difference = Number(line.calculated_difference)
                const lineAllocations = allocations.filter(
                  (row) => row.line_id === line.id,
                )
                const movement = movements.find(
                  (row) => row.product_id === line.product_id,
                )
                return (
                  <tr key={line.id}>
                    <td className="px-4 py-4">
                      <p className="font-black text-slate-900">
                        {productById.get(line.product_id)?.name ??
                          line.product_name_snapshot}
                      </p>
                      <p className="mt-1 text-xs text-slate-400">
                        {line.base_uom_name_snapshot}
                      </p>
                    </td>
                    <td className="px-4 py-4">
                      {qty(line.system_quantity_snapshot)}
                    </td>
                    <td className="px-4 py-4 font-black">
                      {qty(line.final_physical_quantity)}
                    </td>
                    <td
                      className={`px-4 py-4 font-black ${
                        difference > 0 ? 'text-emerald-700' : 'text-rose-700'
                      }`}
                    >
                      {difference > 0 ? '+' : '-'}
                      {qty(Math.abs(difference))}
                    </td>
                    <td className="px-4 py-4">{line.reason_name_snapshot}</td>
                    <td className="px-4 py-4">
                      {document.status === 'POSTED'
                        ? `${lineAllocations.length} layer`
                        : 'Saat Posting'}
                    </td>
                    <td className="px-4 py-4">
                      <p className="font-bold">{rupiah(line.total_value)}</p>
                      {movement?.balance_after_base_qty !== null &&
                        movement?.balance_after_base_qty !== undefined && (
                          <p className="mt-1 text-xs text-slate-400">
                            Saldo akhir {qty(movement.balance_after_base_qty)}
                          </p>
                        )}
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
        <div className="mt-5 grid gap-4 sm:grid-cols-2">
          <Summary
            label="Nilai stock gain"
            value={rupiah(document.total_gain_value)}
          />
          <Summary
            label="Nilai stock loss"
            value={rupiah(document.total_loss_value)}
          />
        </div>
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

function StatusBadge({ status }: { status: AdjustmentDocument['status'] }) {
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
