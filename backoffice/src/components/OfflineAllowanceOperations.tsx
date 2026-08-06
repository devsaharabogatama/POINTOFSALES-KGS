'use client'

import { useCallback, useEffect, useMemo, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import {
  CircleAlert,
  PackageCheck,
  RefreshCcw,
  ShieldAlert,
  Unlock,
  X,
} from 'lucide-react'
import { useEscapeClose } from '@/lib/use-escape-close'

type CashierSession = {
  id: string
  session_code: string
  cashier_id: string
  store_id: string
  pos_id: string
  sales_warehouse_id: string
  opened_at: string
  status: 'OPEN'
}
type Allowance = {
  id: string
  store_id: string
  warehouse_id: string
  terminal_id: string
  cashier_session_id: string
  cashier_id: string
  product_id: string
  base_uom_id: string
  allocated_base_qty: number
  consumed_base_qty: number
  allocation_percent_snapshot: number
  stock_qty_snapshot: number
  unreserved_qty_snapshot: number
  status: 'ACTIVE' | 'CONSUMED' | 'RELEASED' | 'REVOKED'
  released_at: string | null
  released_by: string | null
  release_reason: string | null
  master_version: number
  created_at: string
  updated_at: string
}
type Product = {
  id: string
  name: string
  sku: string
  uom_id: string
}
type Stock = {
  product_id: string
  warehouse_id: string
  stock_qty: number
  updated_at: string
}
type Named = { id: string; name: string }
type Payload = {
  actorId: string
  roleCode: string
  featureEnabled: boolean
  sessions: CashierSession[]
  allowances: Allowance[]
  products: Product[]
  stocks: Stock[]
  uoms: Array<Named & { allow_decimal: boolean; decimal_precision: number }>
  stores: Array<{ id: string; store_name: string }>
  terminals: Array<{ id: string; pos_name: string }>
  warehouses: Named[]
  actors: Named[]
}
type ActionRequest =
  | {
      action: 'ISSUE'
      title: string
      description: string
      cashierSessionId: string
      productId: string
    }
  | {
      action: 'RELEASE' | 'FORCE_REVOKE'
      title: string
      description: string
      allowanceId: string
      masterVersion: number
    }

function authHeaders(session: Session) {
  return { Authorization: `Bearer ${session.access_token}` }
}

function friendlyError(code?: string) {
  const messages: Record<string, string> = {
    OFFLINE_ALLOWANCE_MANAGER_REQUIRED:
      'Role Anda tidak memiliki akses operasional allowance Offline.',
    OFFLINE_POS_FEATURE_DISABLED:
      'POS Offline masih nonaktif. Allowance baru belum dapat diterbitkan.',
    OPEN_CASHIER_SESSION_REQUIRED:
      'Sesi Kasir sudah tidak terbuka. Muat ulang data.',
    OFFLINE_ALLOWANCE_SESSION_ACCESS_DENIED:
      'Anda tidak memiliki akses ke sesi Kasir tersebut.',
    OFFLINE_TERMINAL_NOT_ENABLED:
      'Terminal belum diizinkan pada kebijakan Offline POS.',
    OFFLINE_COMPANY_POLICY_NOT_ENABLED:
      'Kebijakan allowance Company belum aktif.',
    ACTIVE_STOCK_PRODUCT_WITH_BASE_UOM_NOT_FOUND:
      'Produk aktif atau Base UOM tidak lagi valid.',
    OFFLINE_ALLOWANCE_STOCK_UNAVAILABLE:
      'Stok yang belum dicadangkan tidak mencukupi.',
    OFFLINE_ALLOWANCE_QUANTITY_UNAVAILABLE:
      'Persentase policy menghasilkan allowance yang tidak dapat diterbitkan.',
    OFFLINE_ALLOWANCE_NOT_FOUND:
      'Allowance tidak ditemukan pada Company aktif.',
    MASTER_VERSION_CONFLICT:
      'Allowance telah berubah. Muat ulang sebelum mencoba lagi.',
    OFFLINE_QUEUE_RESOLUTION_REQUIRED:
      'Masih ada transaksi Offline yang harus diselesaikan sebelum release.',
    OFFLINE_ALLOWANCE_FORCE_REVOKE_FORBIDDEN:
      'Role Anda tidak boleh mencabut allowance sesi tersebut.',
    OFFLINE_ALLOWANCE_REVOKE_REASON_REQUIRED:
      'Alasan pencabutan wajib diisi.',
    OFFLINE_ALLOWANCE_RELEASE_FORBIDDEN:
      'Release biasa hanya dapat dilakukan oleh Kasir pemilik allowance.',
    CONSUMED_OFFLINE_ALLOWANCE_CANNOT_RELEASE:
      'Allowance yang sudah terpakai tidak dapat dirilis biasa.',
    OFFLINE_ALLOWANCE_REASON_TOO_LONG:
      'Alasan maksimal 500 karakter.',
    ACTIVE_COMPANY_NOT_FOUND: 'Pilih Company aktif terlebih dahulu.',
  }
  return messages[code ?? ''] ?? code ?? 'Operasi allowance Offline gagal.'
}

function quantity(value: number, precision = 6) {
  return Number(value).toLocaleString('id-ID', {
    maximumFractionDigits: precision,
  })
}

const statusLabels: Record<Allowance['status'], string> = {
  ACTIVE: 'Aktif',
  CONSUMED: 'Terpakai',
  RELEASED: 'Dirilis',
  REVOKED: 'Dicabut',
}

export function OfflineAllowanceOperations({
  session,
  companyId,
  featureEnabled,
  notify,
}: {
  session: Session
  companyId: string
  featureEnabled: boolean
  notify: (message: string | null) => void
}) {
  const [payload, setPayload] = useState<Payload | null>(null)
  const [sessionId, setSessionId] = useState('')
  const [productId, setProductId] = useState('')
  const [statusFilter, setStatusFilter] = useState('ACTIVE')
  const [pending, setPending] = useState<ActionRequest | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')

  const refresh = useCallback(async () => {
    setLoading(true)
    setError('')
    try {
      const response = await fetch('/api/platform/offline-allowances', {
        headers: authHeaders(session),
        cache: 'no-store',
      })
      const body = (await response.json()) as {
        data?: Payload
        error?: string
      }
      if (!response.ok || !body.data) {
        throw new Error(friendlyError(body.error))
      }
      setPayload(body.data)
      setSessionId((current) =>
        body.data?.sessions.some((item) => item.id === current)
          ? current
          : (body.data?.sessions[0]?.id ?? ''),
      )
    } catch (caught) {
      setError(
        caught instanceof Error
          ? caught.message
          : 'Gagal memuat allowance Offline.',
      )
    } finally {
      setLoading(false)
    }
  }, [session])

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- active Company defines allowance scope
    void refresh()
  }, [companyId, refresh])

  const maps = useMemo(() => ({
    products: new Map((payload?.products ?? []).map((item) => [item.id, item])),
    uoms: new Map((payload?.uoms ?? []).map((item) => [item.id, item])),
    stores: new Map((payload?.stores ?? []).map((item) => [item.id, item])),
    terminals: new Map(
      (payload?.terminals ?? []).map((item) => [item.id, item]),
    ),
    warehouses: new Map(
      (payload?.warehouses ?? []).map((item) => [item.id, item]),
    ),
    actors: new Map((payload?.actors ?? []).map((item) => [item.id, item])),
  }), [payload])

  const activeSession = payload?.sessions.find((item) => item.id === sessionId)
  const eligibleProducts = useMemo(() => {
    if (!payload || !activeSession) return []
    const stockByProduct = new Map(
      payload.stocks
        .filter(
          (stock) =>
            stock.warehouse_id === activeSession.sales_warehouse_id &&
            Number(stock.stock_qty) > 0,
        )
        .map((stock) => [stock.product_id, stock]),
    )
    const alreadyActive = new Set(
      payload.allowances
        .filter(
          (allowance) =>
            allowance.cashier_session_id === activeSession.id &&
            allowance.status === 'ACTIVE',
        )
        .map((allowance) => allowance.product_id),
    )
    return payload.products
      .filter(
        (product) =>
          stockByProduct.has(product.id) && !alreadyActive.has(product.id),
      )
      .map((product) => ({ product, stock: stockByProduct.get(product.id)! }))
  }, [activeSession, payload])

  const effectiveProductId = eligibleProducts.some(
    (item) => item.product.id === productId,
  )
    ? productId
    : (eligibleProducts[0]?.product.id ?? '')

  const visibleAllowances = (payload?.allowances ?? []).filter(
    (allowance) =>
      statusFilter === 'ALL' || allowance.status === statusFilter,
  )

  return (
    <section className="mt-8 border-t border-slate-200 pt-8">
      <div className="mb-5 flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <p className="text-xs font-bold uppercase tracking-[.16em] text-violet-600">
            Operasional Offline
          </p>
          <h2 className="mt-2 text-xl font-black text-slate-950">
            Cadangan Stok per Sesi
          </h2>
          <p className="mt-1 max-w-3xl text-sm leading-6 text-slate-500">
            Terbitkan cadangan berdasarkan policy untuk satu sesi dan produk.
            Cadangan bukan pengurangan stok dan belum membuka checkout Offline.
          </p>
        </div>
        <button
          type="button"
          onClick={() => void refresh()}
          className="inline-flex items-center justify-center gap-2 rounded-xl border border-slate-200 bg-white px-4 py-2.5 text-sm font-bold text-slate-600"
        >
          <RefreshCcw className={`h-4 w-4 ${loading ? 'animate-spin' : ''}`} />
          Muat ulang
        </button>
      </div>

      {!featureEnabled && (
        <div className="mb-5 flex gap-3 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm leading-6 text-amber-900">
          <CircleAlert className="mt-0.5 h-5 w-5 shrink-0" />
          <span>
            <b>Penerbitan allowance terkunci.</b> Entitlement Offline POS masih
            nonaktif. Allowance lama tetap dapat direview dan diselesaikan.
          </span>
        </div>
      )}
      {error && (
        <div className="mb-5 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-700">
          {error}
        </div>
      )}

      <article className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
        <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_auto] lg:items-end">
          <label className="block">
            <span className="mb-1.5 block text-xs font-bold uppercase tracking-wide text-slate-500">
              Sesi Kasir terbuka
            </span>
            <select
              value={sessionId}
              onChange={(event) => setSessionId(event.target.value)}
              className="input"
            >
              {!payload?.sessions.length && <option value="">Tidak ada sesi terbuka</option>}
              {(payload?.sessions ?? []).map((item) => (
                <option key={item.id} value={item.id}>
                  {item.session_code} · {maps.actors.get(item.cashier_id)?.name ?? 'Kasir'} · {maps.stores.get(item.store_id)?.store_name ?? 'Toko'}
                </option>
              ))}
            </select>
          </label>
          <label className="block">
            <span className="mb-1.5 block text-xs font-bold uppercase tracking-wide text-slate-500">
              Produk dengan stok tersedia
            </span>
            <select
              value={effectiveProductId}
              onChange={(event) => setProductId(event.target.value)}
              className="input"
            >
              {!eligibleProducts.length && <option value="">Tidak ada produk eligible</option>}
              {eligibleProducts.map(({ product, stock }) => (
                <option key={product.id} value={product.id}>
                  {product.name} · stok {quantity(Number(stock.stock_qty), maps.uoms.get(product.uom_id)?.decimal_precision)}
                  {' '}{maps.uoms.get(product.uom_id)?.name ?? ''}
                </option>
              ))}
            </select>
          </label>
          <button
            type="button"
            disabled={!featureEnabled || !sessionId || !effectiveProductId}
            onClick={() => {
              const selectedSession = payload?.sessions.find(
                (item) => item.id === sessionId,
              )
              const product = maps.products.get(effectiveProductId)
              if (!selectedSession || !product) return
              setPending({
                action: 'ISSUE',
                title: 'Terbitkan cadangan stok?',
                description:
                  `${product.name} akan dicadangkan untuk sesi ${selectedSession.session_code}. Jumlah final dihitung ulang server dari policy dan stok belum dicadangkan.`,
                cashierSessionId: sessionId,
                productId: effectiveProductId,
              })
            }}
            className="inline-flex min-h-11 items-center justify-center gap-2 rounded-xl bg-violet-600 px-4 py-3 text-sm font-bold text-white disabled:cursor-not-allowed disabled:opacity-40"
          >
            <PackageCheck className="h-4 w-4" />
            Terbitkan allowance
          </button>
        </div>
        {activeSession && (
          <p className="mt-3 text-xs leading-5 text-slate-500">
            Terminal {maps.terminals.get(activeSession.pos_id)?.pos_name ?? '—'}
            {' · '}Gudang {maps.warehouses.get(activeSession.sales_warehouse_id)?.name ?? '—'}
          </p>
        )}
      </article>

      <div className="mt-5 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h3 className="font-black text-slate-950">Riwayat allowance</h3>
          <p className="mt-1 text-sm text-slate-500">
            Release biasa hanya untuk allowance milik sendiri; sesi orang lain
            harus dicabut dengan alasan dan audit.
          </p>
        </div>
        <select
          value={statusFilter}
          onChange={(event) => setStatusFilter(event.target.value)}
          className="input sm:w-52"
          aria-label="Filter status allowance"
        >
          <option value="ACTIVE">Aktif</option>
          <option value="CONSUMED">Terpakai</option>
          <option value="RELEASED">Dirilis</option>
          <option value="REVOKED">Dicabut</option>
          <option value="ALL">Semua status</option>
        </select>
      </div>

      <div className="mt-3 space-y-3">
        {visibleAllowances.map((allowance) => {
          const product = maps.products.get(allowance.product_id)
          const baseUom = maps.uoms.get(allowance.base_uom_id)
          const remaining =
            Number(allowance.allocated_base_qty) -
            Number(allowance.consumed_base_qty)
          const ownAllowance = allowance.cashier_id === payload?.actorId
          return (
            <article
              key={allowance.id}
              className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"
            >
              <div className="flex flex-col gap-4 lg:flex-row lg:items-center">
                <div className="min-w-0 flex-1">
                  <div className="flex flex-wrap items-center gap-2">
                    <h4 className="font-bold text-slate-950">
                      {product?.name ?? 'Produk tidak dikenali'}
                    </h4>
                    <span className={`rounded-full px-2.5 py-1 text-xs font-bold ${
                      allowance.status === 'ACTIVE'
                        ? 'bg-emerald-50 text-emerald-700'
                        : allowance.status === 'REVOKED'
                          ? 'bg-rose-50 text-rose-700'
                          : 'bg-slate-100 text-slate-600'
                    }`}>
                      {statusLabels[allowance.status]}
                    </span>
                  </div>
                  <p className="mt-1 text-sm text-slate-600">
                    Sesi {payload?.sessions.find((item) => item.id === allowance.cashier_session_id)?.session_code ?? 'sudah ditutup'}
                    {' · '}{maps.actors.get(allowance.cashier_id)?.name ?? 'Kasir'}
                    {' · '}{maps.stores.get(allowance.store_id)?.store_name ?? 'Toko'}
                  </p>
                  <p className="mt-2 text-sm font-semibold text-slate-900">
                    Dialokasikan {quantity(Number(allowance.allocated_base_qty), baseUom?.decimal_precision)}
                    {' · '}Terpakai {quantity(Number(allowance.consumed_base_qty), baseUom?.decimal_precision)}
                    {' · '}Sisa {quantity(remaining, baseUom?.decimal_precision)} {baseUom?.name ?? ''}
                  </p>
                  <p className="mt-1 text-xs text-slate-500">
                    Snapshot stok {quantity(Number(allowance.stock_qty_snapshot), baseUom?.decimal_precision)}
                    {' · '}policy {quantity(Number(allowance.allocation_percent_snapshot) * 100, 4)}%
                    {' · '}{new Date(allowance.created_at).toLocaleString('id-ID')}
                  </p>
                  {allowance.release_reason && (
                    <p className="mt-2 rounded-lg bg-slate-50 px-3 py-2 text-xs text-slate-600">
                      Alasan: {allowance.release_reason}
                    </p>
                  )}
                </div>
                {allowance.status === 'ACTIVE' && (
                  <button
                    type="button"
                    onClick={() => setPending({
                      action: ownAllowance ? 'RELEASE' : 'FORCE_REVOKE',
                      title: ownAllowance
                        ? 'Rilis cadangan stok?'
                        : 'Cabut paksa cadangan stok?',
                      description: ownAllowance
                        ? 'Sisa cadangan dikembalikan menjadi stok yang tidak dicadangkan. Queue Offline aktif tetap dapat memblokir release.'
                        : 'Transaksi Offline nonfinal pada sesi ini akan diinvalidasi. Alasan wajib dan tindakan dicatat pada audit.',
                      allowanceId: allowance.id,
                      masterVersion: allowance.master_version,
                    })}
                    className={`inline-flex min-h-11 items-center justify-center gap-2 rounded-xl px-4 py-2.5 text-sm font-bold ${
                      ownAllowance
                        ? 'border border-slate-200 text-slate-700'
                        : 'border border-rose-200 text-rose-700'
                    }`}
                  >
                    {ownAllowance
                      ? <Unlock className="h-4 w-4" />
                      : <ShieldAlert className="h-4 w-4" />}
                    {ownAllowance ? 'Release' : 'Force revoke'}
                  </button>
                )}
              </div>
            </article>
          )
        })}
        {!loading && !visibleAllowances.length && (
          <div className="rounded-2xl border border-dashed border-slate-300 p-8 text-center text-sm text-slate-400">
            Belum ada allowance dengan status tersebut.
          </div>
        )}
      </div>

      {pending && (
        <AllowanceActionDialog
          session={session}
          request={pending}
          close={() => setPending(null)}
          complete={async (message) => {
            setPending(null)
            await refresh()
            notify(message)
          }}
        />
      )}
    </section>
  )
}

function AllowanceActionDialog({
  session,
  request,
  close,
  complete,
}: {
  session: Session
  request: ActionRequest
  close: () => void
  complete: (message: string) => Promise<void>
}) {
  useEscapeClose(close)
  const [reason, setReason] = useState('')
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')
  const force = request.action === 'FORCE_REVOKE'

  async function confirm() {
    if (force && !reason.trim()) return
    setSaving(true)
    setError('')
    try {
      const response = await fetch('/api/platform/offline-allowances', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          ...authHeaders(session),
        },
        body: JSON.stringify({
          ...request,
          reason: reason.trim() || null,
        }),
      })
      const body = (await response.json()) as { error?: string }
      if (!response.ok) throw new Error(friendlyError(body.error))
      await complete(
        request.action === 'ISSUE'
          ? 'Allowance berhasil diterbitkan.'
          : request.action === 'RELEASE'
            ? 'Allowance berhasil dirilis.'
            : 'Allowance berhasil dicabut dan dicatat pada audit.',
      )
    } catch (caught) {
      setError(
        caught instanceof Error
          ? caught.message
          : 'Operasi allowance Offline gagal.',
      )
    } finally {
      setSaving(false)
    }
  }

  return (
    <div className="fixed inset-0 z-[95] grid place-items-center overflow-y-auto bg-slate-950/55 p-4 backdrop-blur-sm">
      <section
        role="dialog"
        aria-modal="true"
        aria-labelledby="offline-allowance-dialog-title"
        className="w-full max-w-lg rounded-3xl bg-white shadow-2xl"
      >
        <header className="flex items-start justify-between border-b border-slate-100 p-6">
          <div>
            <p className="text-xs font-bold uppercase tracking-[.14em] text-violet-600">
              Konfirmasi allowance
            </p>
            <h2
              id="offline-allowance-dialog-title"
              className="mt-2 text-xl font-black text-slate-950"
            >
              {request.title}
            </h2>
          </div>
          <button
            type="button"
            onClick={close}
            className="grid h-10 w-10 place-items-center rounded-xl border border-slate-200 text-slate-500"
            aria-label="Tutup"
          >
            <X className="h-5 w-5" />
          </button>
        </header>
        <div className="space-y-4 p-6">
          <p className="text-sm leading-6 text-slate-600">
            {request.description}
          </p>
          {force && (
            <label className="block">
              <span className="mb-1.5 block text-xs font-bold uppercase tracking-wide text-slate-500">
                Alasan pencabutan
              </span>
              <textarea
                autoFocus
                required
                rows={3}
                maxLength={500}
                value={reason}
                onChange={(event) => setReason(event.target.value)}
                className="input min-h-24"
                placeholder="Jelaskan hasil pemeriksaan fisik atau alasan operasional"
              />
            </label>
          )}
          {error && (
            <div className="rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-700">
              {error}
            </div>
          )}
          <footer className="flex justify-end gap-3 pt-2">
            <button
              type="button"
              onClick={close}
              disabled={saving}
              className="rounded-xl border border-slate-200 px-4 py-2.5 text-sm font-bold text-slate-600"
            >
              Batal
            </button>
            <button
              type="button"
              onClick={() => void confirm()}
              disabled={saving || (force && !reason.trim())}
              className="rounded-xl bg-slate-950 px-4 py-2.5 text-sm font-bold text-white disabled:opacity-40"
            >
              {saving ? 'Memproses...' : 'Ya, lanjutkan'}
            </button>
          </footer>
        </div>
      </section>
    </div>
  )
}
