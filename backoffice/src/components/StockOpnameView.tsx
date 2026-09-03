'use client'

import { useCallback, useEffect, useMemo, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import {
  CheckCircle2,
  Eye,
  Loader2,
  RefreshCcw,
  RotateCcw,
  Send,
  X,
  XCircle,
} from 'lucide-react'
import { useEscapeClose } from '@/lib/use-escape-close'

type OpnameStatus =
  | 'DRAFT'
  | 'COUNTING'
  | 'COMPLETED'
  | 'POSTED'
  | 'CANCELED'
  | 'SUBMITTED'
  | 'APPROVED'
type LineStatus =
  | 'PENDING'
  | 'COUNTED'
  | 'RECOUNT_REQUIRED'
  | 'SKIPPED'
  | 'SUPERSEDED'
  | 'POSTED'
type OpnameSession = {
  id: string
  opname_no: string
  warehouse_id: string
  status: OpnameStatus
  notes: string | null
  created_by: string
  created_at: string
  scope_type: 'ALL' | 'CATEGORY' | 'SELECTED'
  count_started_at: string | null
  completed_by: string | null
  completed_at: string | null
  reviewed_by: string | null
  reviewed_at: string | null
  adjustment_document_id: string | null
  posted_by: string | null
  posted_at: string | null
  canceled_by: string | null
  canceled_at: string | null
  master_version: number
}
type OpnameLine = {
  id: string
  opname_id: string
  product_id: string
  line_status: LineStatus
  system_qty_at_start: number | string
  expected_qty_at_count: number | string | null
  physical_qty: number | string
  variance_at_count: number | string | null
  count_started_at: string | null
  counted_at: string | null
  counter_id: string | null
  recount_requested_by: string | null
  recount_requested_at: string | null
  adjustment_line_id: string | null
  product_sku_snapshot: string
  product_name_snapshot: string
  base_uom_name_snapshot: string
  notes: string | null
}
type CountAttempt = {
  id: string
  opname_id: string
  opname_detail_id: string
  attempt_no: number
  physical_qty: number | string
  count_started_at: string
  counted_at: string
  counter_id: string
  movement_count_in_window: number | string
  result_status: 'COUNTED' | 'RECOUNT_REQUIRED'
  notes: string | null
}
type Warehouse = {
  id: string
  name: string
  warehouse_type: string | null
  location: string | null
}
type Adjustment = {
  id: string
  document_no: string
  status: string
  total_gain_quantity_base: number | string
  total_loss_quantity_base: number | string
  total_gain_value: number | string
  total_loss_value: number | string
  posted_at: string | null
}
type Actor = { id: string; name: string }
type Payload = {
  data?: OpnameSession[]
  details?: OpnameLine[]
  attempts?: CountAttempt[]
  warehouses?: Warehouse[]
  adjustments?: Adjustment[]
  actors?: Actor[]
  error?: string
}

function authHeaders(session: Session) {
  return { Authorization: `Bearer ${session.access_token}` }
}
function qty(value: number | string | null) {
  if (value === null) return '-'
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
function dateTime(value: string | null) {
  return value ? new Date(value).toLocaleString('id-ID') : '-'
}
function friendlyError(code?: string) {
  const messages: Record<string, string> = {
    CUSTOM_PERMISSION_DENIED:
      'Akses Stock Opname dibatasi oleh pengaturan user untuk Company ini.',
    STOCK_OPNAME_NOT_FOUND: 'Sesi Stock Opname tidak ditemukan.',
    STOCK_OPNAME_LINE_NOT_FOUND: 'Baris hitungan tidak ditemukan.',
    STOCK_OPNAME_REVIEWER_REQUIRED:
      'Role atau cakupan Gudang Anda tidak diizinkan mereview sesi ini.',
    STOCK_OPNAME_RECOUNT_NOT_ALLOWED:
      'Hitung ulang hanya tersedia untuk hasil yang sudah dihitung.',
    STOCK_OPNAME_UNRESOLVED_LINE:
      'Masih ada Product yang belum dihitung atau wajib dihitung ulang.',
    STOCK_OPNAME_FINAL_STOCK_NEGATIVE:
      'Variance sesi ini akan membuat stok akhir negatif.',
    STOCK_OPNAME_ADJUSTMENT_REASON_NOT_FOUND:
      'Alasan sistem Selisih Stok tidak tersedia.',
    STOCK_OPNAME_IDEMPOTENCY_CONFLICT:
      'Sesi sudah diproses menggunakan permintaan posting berbeda.',
    FINAL_STOCK_OPNAME_IMMUTABLE:
      'Sesi final tidak dapat diubah atau dibatalkan.',
    MASTER_VERSION_CONFLICT:
      'Sesi berubah di tab lain. Muat ulang sebelum mengulangi tindakan.',
    STOCK_ADJUSTMENT_STOCK_CHANGED:
      'Stok berubah saat proses posting. Muat ulang dan periksa sesi.',
    INSUFFICIENT_FIFO_STOCK: 'Layer FIFO tidak cukup atau tidak sinkron.',
    FORBIDDEN: 'Role Anda tidak diizinkan mengakses Stock Opname.',
  }
  return messages[code ?? ''] ?? code ?? 'Operasi Stock Opname gagal.'
}

export function StockOpnameView({
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
  const [payload, setPayload] = useState<Payload>({})
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [statusFilter, setStatusFilter] = useState('ALL')
  const [detail, setDetail] = useState<OpnameSession | null>(null)
  const [action, setAction] = useState<{
    type: 'post' | 'cancel' | 'recount'
    session: OpnameSession
    line?: OpnameLine
  } | null>(null)
  const canReview = capabilities.includes('REVIEW')
  const canPost = capabilities.includes('POST')
  const canCancel = capabilities.includes('CANCEL_FINAL')

  const load = useCallback(async () => {
    const response = await fetch('/api/inventory/stock-opnames', {
      headers: authHeaders(session),
    })
    const result = (await response.json()) as Payload
    if (!response.ok) throw new Error(friendlyError(result.error))
    setPayload(result)
  }, [session])

  const refresh = useCallback(async () => {
    setLoading(true)
    setError('')
    try {
      await load()
    } catch (caught) {
      setError(
        caught instanceof Error ? caught.message : 'Gagal memuat Stock Opname.',
      )
    } finally {
      setLoading(false)
    }
  }, [load])

  useEffect(() => {
    let canceled = false
    // eslint-disable-next-line react-hooks/set-state-in-effect -- load is synchronized to the active Company context
    load()
      .catch((caught) => {
        if (!canceled) {
          setError(
            caught instanceof Error
              ? caught.message
              : 'Gagal memuat Stock Opname.',
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

  const warehouseById = useMemo(
    () => new Map((payload.warehouses ?? []).map((row) => [row.id, row])),
    [payload.warehouses],
  )
  const actorById = useMemo(
    () => new Map((payload.actors ?? []).map((row) => [row.id, row.name])),
    [payload.actors],
  )
  const adjustmentById = useMemo(
    () => new Map((payload.adjustments ?? []).map((row) => [row.id, row])),
    [payload.adjustments],
  )
  const sessions = (payload.data ?? []).filter(
    (row) => statusFilter === 'ALL' || row.status === statusFilter,
  )
  const needsReview = (payload.data ?? []).filter(
    (row) => row.status === 'COMPLETED',
  ).length
  const needsRecount = (payload.details ?? []).filter(
    (row) => row.line_status === 'RECOUNT_REQUIRED',
  ).length
  const posted = (payload.data ?? []).filter(
    (row) => row.status === 'POSTED',
  ).length

  return (
    <>
      <div className="mb-7 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <p className="text-xs font-bold uppercase tracking-[.16em] text-emerald-600">
            Inventory review
          </p>
          <h1 className="mt-2 text-2xl font-black tracking-tight text-slate-950 md:text-3xl">
            Stock Opname
          </h1>
          <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-500">
            Review hasil blind count dari POS. Expected stock dihitung pada waktu
            kasir menghitung; penjualan tetap berjalan dan variance diterapkan ke
            stok terkini saat Posting.
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

      {!canReview && (
        <div className="mb-5 rounded-2xl border border-blue-200 bg-blue-50 p-4 text-sm leading-6 text-blue-800">
          Anda memiliki akses laporan saja. Minta hitung ulang, Posting, dan
          pembatalan hanya tersedia untuk Owner/Admin Company atau Store Manager
          pada Gudang Store dalam assignment.
        </div>
      )}
      <div className="mb-5 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm leading-6 text-amber-900">
        Pembuatan sesi dan input fisik dilakukan dari aplikasi POS dalam mode
        blind count. Saldo sistem, expected, variance, HPP, dan nilai tidak
        ditampilkan kepada kasir.
      </div>
      {error && (
        <div className="mb-5 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-700">
          {error}
        </div>
      )}

      <div className="mb-5 grid gap-4 sm:grid-cols-3">
        <Summary label="Menunggu review" value={String(needsReview)} />
        <Summary label="Wajib hitung ulang" value={String(needsRecount)} />
        <Summary label="Sudah diposting" value={String(posted)} />
      </div>

      <div className="mb-4 flex flex-wrap gap-2">
        {['ALL', 'COUNTING', 'COMPLETED', 'POSTED', 'CANCELED'].map((status) => (
          <button
            key={status}
            onClick={() => setStatusFilter(status)}
            className={`rounded-full px-4 py-2 text-xs font-black ${
              statusFilter === status
                ? 'bg-slate-950 text-white'
                : 'border border-slate-200 bg-white text-slate-600'
            }`}
          >
            {status === 'ALL' ? 'Semua' : statusLabel(status)}
          </button>
        ))}
      </div>

      <div className="overflow-x-auto rounded-2xl border border-slate-200 bg-white shadow-sm">
        <table className="w-full min-w-[1050px] text-left text-sm">
          <thead className="bg-slate-50 text-xs uppercase tracking-wider text-slate-500">
            <tr>
              <th className="px-5 py-4">Sesi</th>
              <th className="px-5 py-4">Gudang</th>
              <th className="px-5 py-4">Scope</th>
              <th className="px-5 py-4">Progress</th>
              <th className="px-5 py-4">Status</th>
              <th className="px-5 py-4 text-right">Aksi</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {sessions.map((row) => {
              const lines = (payload.details ?? []).filter(
                (line) => line.opname_id === row.id,
              )
              const counted = lines.filter((line) =>
                ['COUNTED', 'POSTED'].includes(line.line_status),
              ).length
              const unresolved = lines.filter((line) =>
                ['PENDING', 'RECOUNT_REQUIRED'].includes(line.line_status),
              ).length
              const skipped = lines.filter(
                (line) => line.line_status === 'SKIPPED',
              ).length
              return (
                <tr key={row.id}>
                  <td className="px-5 py-4">
                    <p className="font-black text-slate-900">{row.opname_no}</p>
                    <p className="mt-1 text-xs text-slate-400">
                      {dateTime(row.created_at)} ·{' '}
                      {actorById.get(row.created_by) ?? 'Pengguna'}
                    </p>
                  </td>
                  <td className="px-5 py-4">
                    <p className="font-bold text-slate-800">
                      {warehouseById.get(row.warehouse_id)?.name ??
                        'Gudang tidak tersedia'}
                    </p>
                    <p className="mt-1 text-xs text-slate-400">
                      {warehouseById.get(row.warehouse_id)?.location ||
                        'Lokasi tidak dicatat'}
                    </p>
                  </td>
                  <td className="px-5 py-4 font-bold text-slate-700">
                    {scopeLabel(row.scope_type)}
                  </td>
                  <td className="px-5 py-4">
                    <p className="font-bold text-slate-700">
                      {counted} dihitung
                    </p>
                    {skipped > 0 && (
                      <p className="mt-1 text-xs font-bold text-slate-500">
                        {skipped} dilewati tanpa perubahan stok
                      </p>
                    )}
                    {unresolved > 0 && (
                      <p className="mt-1 text-xs font-bold text-amber-600">
                        {unresolved} perlu tindakan
                      </p>
                    )}
                  </td>
                  <td className="px-5 py-4">
                    <StatusBadge status={row.status} />
                  </td>
                  <td className="px-5 py-4">
                    <div className="flex justify-end gap-2">
                      <button
                        onClick={() => setDetail(row)}
                        className="rounded-xl border border-slate-200 p-2 text-slate-600"
                        aria-label={`Lihat ${row.opname_no}`}
                      >
                        <Eye className="h-4 w-4" />
                      </button>
                      {canPost && row.status === 'COMPLETED' && (
                        <button
                          onClick={() =>
                            setAction({ type: 'post', session: row })
                          }
                          className="rounded-xl bg-emerald-500 p-2 text-white"
                          aria-label={`Posting ${row.opname_no}`}
                        >
                          <Send className="h-4 w-4" />
                        </button>
                      )}
                      {canCancel &&
                        ['DRAFT', 'COUNTING', 'COMPLETED'].includes(
                          row.status,
                        ) && (
                          <button
                            onClick={() =>
                              setAction({ type: 'cancel', session: row })
                            }
                            className="rounded-xl border border-rose-200 p-2 text-rose-600"
                            aria-label={`Batalkan ${row.opname_no}`}
                          >
                            <XCircle className="h-4 w-4" />
                          </button>
                        )}
                    </div>
                  </td>
                </tr>
              )
            })}
            {!loading && sessions.length === 0 && (
              <tr>
                <td colSpan={6} className="px-5 py-12 text-center text-slate-400">
                  Belum ada sesi Stock Opname untuk filter ini.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      {detail && (
        <OpnameDetail
          opname={detail}
          warehouse={warehouseById.get(detail.warehouse_id)}
          adjustment={
            detail.adjustment_document_id
              ? adjustmentById.get(detail.adjustment_document_id)
              : undefined
          }
          lines={(payload.details ?? []).filter(
            (line) => line.opname_id === detail.id,
          )}
          attempts={(payload.attempts ?? []).filter(
            (attempt) => attempt.opname_id === detail.id,
          )}
          actorById={actorById}
          canReview={canReview}
          recount={(line) => setAction({ type: 'recount', session: detail, line })}
          close={() => setDetail(null)}
        />
      )}
      {action && (
        <OpnameActionDialog
          session={session}
          action={action}
          close={() => setAction(null)}
          complete={async () => {
            const label =
              action.type === 'post'
                ? 'diposting'
                : action.type === 'cancel'
                  ? 'dibatalkan'
                  : 'dikirim untuk hitung ulang'
            setAction(null)
            setDetail(null)
            await refresh()
            notify(`Stock Opname berhasil ${label}.`)
          }}
        />
      )}
    </>
  )
}

function OpnameDetail({
  opname,
  warehouse,
  adjustment,
  lines,
  attempts,
  actorById,
  canReview,
  recount,
  close,
}: {
  opname: OpnameSession
  warehouse?: Warehouse
  adjustment?: Adjustment
  lines: OpnameLine[]
  attempts: CountAttempt[]
  actorById: Map<string, string>
  canReview: boolean
  recount: (line: OpnameLine) => void
  close: () => void
}) {
  useEscapeClose(close)
  return (
    <div className="fixed inset-0 z-[70] grid place-items-center bg-slate-950/50 p-4 backdrop-blur-sm">
      <div className="max-h-[94vh] w-full max-w-7xl overflow-y-auto rounded-3xl bg-white p-6 shadow-2xl sm:p-8">
        <div className="flex items-start justify-between gap-4">
          <div>
            <p className="text-xs font-bold uppercase tracking-wider text-emerald-600">
              Report Stock Opname
            </p>
            <h2 className="mt-2 text-2xl font-black text-slate-950">
              {opname.opname_no}
            </h2>
            <p className="mt-2 text-sm text-slate-500">
              {warehouse?.name ?? 'Gudang'} · {scopeLabel(opname.scope_type)} ·{' '}
              dibuat {dateTime(opname.created_at)}
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

        <div className="mt-6 grid gap-4 sm:grid-cols-4">
          <Summary label="Status" value={statusLabel(opname.status)} />
          <Summary label="Mulai hitung" value={dateTime(opname.count_started_at)} />
          <Summary label="Selesai hitung" value={dateTime(opname.completed_at)} />
          <Summary label="Posting" value={dateTime(opname.posted_at)} />
        </div>

        <div className="mt-6 overflow-x-auto rounded-2xl border border-slate-200">
          <table className="w-full min-w-[1250px] text-left text-sm">
            <thead className="bg-slate-50 text-xs uppercase tracking-wider text-slate-500">
              <tr>
                <th className="px-4 py-3">Product</th>
                <th className="px-4 py-3 text-right">Snapshot awal</th>
                <th className="px-4 py-3 text-right">Expected saat hitung</th>
                <th className="px-4 py-3 text-right">Fisik</th>
                <th className="px-4 py-3 text-right">Variance</th>
                <th className="px-4 py-3">Counter / waktu</th>
                <th className="px-4 py-3">Status</th>
                <th className="px-4 py-3 text-right">Aksi</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {lines.map((line) => {
                const variance = Number(line.variance_at_count ?? 0)
                return (
                  <tr key={line.id}>
                    <td className="px-4 py-4">
                      <p className="font-black text-slate-900">
                        {line.product_name_snapshot}
                      </p>
                      <p className="mt-1 text-xs text-slate-400">
                        {line.product_sku_snapshot} · {line.base_uom_name_snapshot}
                      </p>
                    </td>
                    <td className="px-4 py-4 text-right font-semibold">
                      {qty(line.system_qty_at_start)}
                    </td>
                    <td className="px-4 py-4 text-right font-semibold">
                      {qty(line.expected_qty_at_count)}
                    </td>
                    <td className="px-4 py-4 text-right font-black">
                      {line.counted_at ? qty(line.physical_qty) : '-'}
                    </td>
                    <td
                      className={`px-4 py-4 text-right font-black ${
                        variance > 0
                          ? 'text-emerald-600'
                          : variance < 0
                            ? 'text-rose-600'
                            : 'text-slate-600'
                      }`}
                    >
                      {line.variance_at_count === null
                        ? '-'
                        : `${variance > 0 ? '+' : ''}${qty(variance)}`}
                    </td>
                    <td className="px-4 py-4">
                      <p className="font-semibold text-slate-700">
                        {line.counter_id
                          ? actorById.get(line.counter_id) ?? 'Kasir'
                          : '-'}
                      </p>
                      <p className="mt-1 text-xs text-slate-400">
                        {dateTime(line.counted_at)}
                      </p>
                    </td>
                    <td className="px-4 py-4">
                      <LineStatusBadge status={line.line_status} />
                    </td>
                    <td className="px-4 py-4 text-right">
                      {canReview &&
                        opname.status === 'COMPLETED' &&
                        line.line_status === 'COUNTED' && (
                          <button
                            onClick={() => recount(line)}
                            className="inline-flex items-center gap-2 rounded-xl border border-amber-200 px-3 py-2 text-xs font-black text-amber-700"
                          >
                            <RotateCcw className="h-3.5 w-3.5" /> Hitung ulang
                          </button>
                        )}
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>

        {attempts.length > 0 && (
          <div className="mt-6 rounded-2xl border border-slate-200 p-5">
            <h3 className="font-black text-slate-900">Riwayat percobaan hitung</h3>
            <div className="mt-4 grid gap-3 md:grid-cols-2">
              {attempts.map((attempt) => {
                const line = lines.find(
                  (item) => item.id === attempt.opname_detail_id,
                )
                return (
                  <div
                    key={attempt.id}
                    className="rounded-xl border border-slate-100 bg-slate-50 p-4 text-sm"
                  >
                    <p className="font-black text-slate-800">
                      {line?.product_name_snapshot ?? 'Product'} · Percobaan{' '}
                      {attempt.attempt_no}
                    </p>
                    <p className="mt-2 text-slate-600">
                      Hasil {qty(attempt.physical_qty)}{' '}
                      {line?.base_uom_name_snapshot ?? ''} ·{' '}
                      {dateTime(attempt.counted_at)}
                    </p>
                    <p className="mt-1 text-xs text-slate-500">
                      {Number(attempt.movement_count_in_window) > 0
                        ? `${attempt.movement_count_in_window} movement dalam window — wajib recount`
                        : 'Tidak ada movement dalam window'}
                    </p>
                  </div>
                )
              })}
            </div>
          </div>
        )}

        {adjustment && (
          <div className="mt-6 rounded-2xl border border-emerald-200 bg-emerald-50 p-5 text-sm text-emerald-900">
            <p className="font-black">
              Adjustment {adjustment.document_no} · {adjustment.status}
            </p>
            <p className="mt-2">
              Gain +{qty(adjustment.total_gain_quantity_base)} (
              {rupiah(adjustment.total_gain_value)}) · Loss -
              {qty(adjustment.total_loss_quantity_base)} (
              {rupiah(adjustment.total_loss_value)})
            </p>
          </div>
        )}

        <div className="mt-6 flex justify-end">
          <button
            onClick={close}
            className="rounded-xl border border-slate-200 px-4 py-2.5 text-sm font-bold text-slate-600"
          >
            Tutup
          </button>
        </div>
      </div>
    </div>
  )
}

function OpnameActionDialog({
  session,
  action,
  close,
  complete,
}: {
  session: Session
  action: {
    type: 'post' | 'cancel' | 'recount'
    session: OpnameSession
    line?: OpnameLine
  }
  close: () => void
  complete: () => Promise<void>
}) {
  useEscapeClose(close)
  const [confirmed, setConfirmed] = useState(false)
  const [idempotencyKey] = useState(() => crypto.randomUUID())
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')
  const isPost = action.type === 'post'

  async function run() {
    setSaving(true)
    setError('')
    try {
      const response = await fetch(
        `/api/inventory/stock-opnames/${action.session.id}/${action.type}`,
        {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            ...authHeaders(session),
          },
          body: JSON.stringify({
            masterVersion: action.session.master_version,
            ...(isPost ? { idempotencyKey } : {}),
            ...(action.type === 'recount'
              ? { detailId: action.line?.id }
              : {}),
          }),
        },
      )
      const result = (await response.json()) as { error?: string }
      if (!response.ok) throw new Error(friendlyError(result.error))
      await complete()
    } catch (caught) {
      setError(
        caught instanceof Error ? caught.message : 'Tindakan Opname gagal.',
      )
    } finally {
      setSaving(false)
    }
  }

  const title =
    action.type === 'post'
      ? 'Posting Stock Opname?'
      : action.type === 'cancel'
        ? 'Batalkan sesi Stock Opname?'
        : 'Minta hitung ulang?'
  return (
    <div className="fixed inset-0 z-[80] grid place-items-center bg-slate-950/50 p-4 backdrop-blur-sm">
      <div className="w-full max-w-xl rounded-3xl bg-white p-7 shadow-2xl">
        <div className="flex items-start justify-between gap-4">
          <div>
            <h2 className="text-xl font-black text-slate-950">{title}</h2>
            <p className="mt-2 text-sm text-slate-500">
              {action.session.opname_no}
              {action.line ? ` · ${action.line.product_name_snapshot}` : ''}
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
        <div className="mt-5 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm leading-6 text-amber-900">
          {isPost
            ? 'Posting bersifat final. Variance diterapkan ke stok terkini melalui satu Adjustment atomic; FIFO, Kartu Stok, dan Finance HOLD ikut diperbarui.'
            : action.type === 'recount'
              ? 'Angka kasir tidak diubah oleh reviewer. Product dikembalikan ke POS sebagai blind count baru dengan time window baru.'
              : 'Sesi dibatalkan tanpa mengubah stok. Sesi final tidak dapat dibatalkan.'}
        </div>
        <label className="mt-5 flex items-start gap-3 rounded-2xl border border-slate-200 p-4">
          <input
            type="checkbox"
            checked={confirmed}
            onChange={(event) => setConfirmed(event.target.checked)}
            className="mt-1 h-4 w-4 accent-emerald-500"
          />
          <span className="text-sm font-semibold leading-6 text-slate-700">
            Saya sudah memeriksa sesi, Gudang, status line, waktu hitung, dan
            dampak tindakan ini.
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
            className="inline-flex items-center gap-2 rounded-xl bg-emerald-500 px-5 py-2.5 text-sm font-black text-white disabled:opacity-50"
          >
            {saving ? (
              <Loader2 className="h-4 w-4 animate-spin" />
            ) : action.type === 'recount' ? (
              <RotateCcw className="h-4 w-4" />
            ) : isPost ? (
              <CheckCircle2 className="h-4 w-4" />
            ) : (
              <XCircle className="h-4 w-4" />
            )}
            Konfirmasi
          </button>
        </div>
      </div>
    </div>
  )
}

function Summary({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
      <p className="text-xs font-bold uppercase tracking-wider text-slate-400">
        {label}
      </p>
      <p className="mt-2 text-xl font-black text-slate-900">{value}</p>
    </div>
  )
}
function StatusBadge({ status }: { status: OpnameStatus }) {
  const style =
    status === 'POSTED'
      ? 'bg-emerald-100 text-emerald-700'
      : status === 'COMPLETED'
        ? 'bg-blue-100 text-blue-700'
        : status === 'CANCELED'
          ? 'bg-rose-100 text-rose-700'
          : 'bg-amber-100 text-amber-700'
  return (
    <span className={`rounded-full px-3 py-1 text-xs font-black ${style}`}>
      {statusLabel(status)}
    </span>
  )
}
function LineStatusBadge({ status }: { status: LineStatus }) {
  const style =
    status === 'POSTED' || status === 'COUNTED'
      ? 'bg-emerald-100 text-emerald-700'
      : status === 'RECOUNT_REQUIRED'
        ? 'bg-amber-100 text-amber-800'
        : status === 'SKIPPED'
          ? 'bg-slate-100 text-slate-600'
        : status === 'SUPERSEDED'
          ? 'bg-slate-200 text-slate-600'
          : 'bg-blue-100 text-blue-700'
  return (
    <span className={`rounded-full px-3 py-1 text-xs font-black ${style}`}>
      {lineStatusLabel(status)}
    </span>
  )
}
function statusLabel(status: string) {
  const labels: Record<string, string> = {
    DRAFT: 'Draft',
    COUNTING: 'Sedang dihitung',
    COMPLETED: 'Menunggu review',
    POSTED: 'Sudah diposting',
    CANCELED: 'Dibatalkan',
    SUBMITTED: 'Dikirim',
    APPROVED: 'Disetujui',
  }
  return labels[status] ?? status
}
function lineStatusLabel(status: LineStatus) {
  const labels: Record<LineStatus, string> = {
    PENDING: 'Belum dihitung',
    COUNTED: 'Sudah dihitung',
    RECOUNT_REQUIRED: 'Wajib hitung ulang',
    SKIPPED: 'Dilewati',
    SUPERSEDED: 'Digantikan hasil baru',
    POSTED: 'Sudah diposting',
  }
  return labels[status]
}
function scopeLabel(scope: OpnameSession['scope_type']) {
  return scope === 'ALL'
    ? 'Semua Product'
    : scope === 'CATEGORY'
      ? 'Per kategori'
      : 'Product terpilih'
}
