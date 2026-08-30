import { useMemo, useState } from 'react'
import {
  Ban,
  CalendarClock,
  ChevronDown,
  PackageCheck,
  RefreshCw,
  Search,
  X,
} from 'lucide-react'
import {
  cancelSalesOrder,
  type CustomerOption,
  type SalesOrderListItem,
} from './lib/pos'

function money(value: number) {
  return new Intl.NumberFormat('id-ID', {
    style: 'currency',
    currency: 'IDR',
    maximumFractionDigits: 0,
  }).format(value)
}

function date(value: string | null) {
  if (!value) return 'Tidak dijadwalkan'
  const parsed = new Date(`${value}T00:00:00`)
  return Number.isNaN(parsed.valueOf())
    ? value
    : parsed.toLocaleDateString('id-ID', {
        day: '2-digit',
        month: 'short',
        year: 'numeric',
      })
}

function statusLabel(status: SalesOrderListItem['orderRuntimeStatus']) {
  return ({
    CONFIRMED: 'Dikonfirmasi',
    RESERVED: 'Stok dicadangkan',
    PARTIALLY_DISPATCHED: 'Dikirim sebagian',
    DISPATCHED: 'Dalam perjalanan',
    DELIVERED: 'Selesai diterima',
  } as const)[status]
}

function friendly(value: unknown) {
  const message = value instanceof Error ? value.message : 'Order gagal diproses.'
  const known: Record<string, string> = {
    MASTER_VERSION_CONFLICT: 'Order berubah. Muat ulang sebelum mencoba kembali.',
    SALES_ORDER_FINAL: 'Order sudah final dan tidak dapat dibatalkan.',
    SALES_ORDER_DISPATCH_STARTED: 'Pengiriman sudah dimulai; Order tidak dapat dibatalkan.',
    CANCEL_REASON_REQUIRED: 'Alasan pembatalan wajib diisi.',
    SALES_ORDER_CANCEL_FORBIDDEN: 'Akun ini tidak berwenang membatalkan Order.',
    CUSTOM_PERMISSION_DENIED: 'Akun ini tidak memiliki izin Order.',
    SALES_ORDER_VERIFIED_PAYMENT_REVERSAL_REQUIRED:
      'Pembayaran sudah diverifikasi. Finance harus melakukan reversal sebelum Order dibatalkan.',
    SALES_ORDER_CASH_REFUND_REQUIRES_CURRENT_OPEN_SESSION:
      'Buka sesi kas pada toko Order ini untuk mencatat pengembalian Cash, lalu coba batalkan lagi.',
    SALES_ORDER_CASH_REFUND_REQUIRES_OPEN_SESSION:
      'Buka sesi kas pada toko Order ini untuk mencatat pengembalian Cash, lalu coba batalkan lagi.',
  }
  return Object.entries(known).find(([code]) => message.includes(code))?.[1] ?? message
}

export function SalesOrderPanel({
  orders,
  customers,
  loading,
  close,
  refresh,
}: {
  orders: SalesOrderListItem[]
  customers: CustomerOption[]
  loading: boolean
  close: () => void
  refresh: () => Promise<void>
}) {
  const [expanded, setExpanded] = useState<string | null>(null)
  const [cancelTarget, setCancelTarget] = useState<SalesOrderListItem | null>(null)
  const [cancelReason, setCancelReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [query, setQuery] = useState('')
  const customerCodeById = useMemo(
    () => new Map(customers.map((customer) => [customer.id, customer.code ?? ''])),
    [customers],
  )
  const filteredOrders = useMemo(() => {
    const keyword = query.trim().toLocaleLowerCase('id-ID')
    if (!keyword) return orders
    return orders.filter((order) => [
      order.orderNo,
      order.customerName,
      customerCodeById.get(order.customerId) ?? '',
    ].some((value) => value.toLocaleLowerCase('id-ID').includes(keyword)))
  }, [customerCodeById, orders, query])
  const scheduled = useMemo(
    () => filteredOrders.filter((order) => order.orderTimingMode === 'SCHEDULED'),
    [filteredOrders],
  )
  const active = useMemo(
    () => filteredOrders.filter((order) => order.orderTimingMode !== 'SCHEDULED'),
    [filteredOrders],
  )

  async function cancel() {
    if (!cancelTarget) return
    setBusy(true)
    setError('')
    try {
      await cancelSalesOrder(
        cancelTarget.salesId,
        cancelTarget.masterVersion,
        crypto.randomUUID(),
        cancelReason,
      )
      setCancelTarget(null)
      setCancelReason('')
      await refresh()
    } catch (reason) {
      setError(friendly(reason))
    } finally {
      setBusy(false)
    }
  }

  function group(title: string, subtitle: string, rows: SalesOrderListItem[]) {
    return <section>
      <div className="mb-3 flex items-end justify-between gap-3">
        <div><h3 className="font-black text-slate-950">{title}</h3><p className="text-xs text-slate-500">{subtitle}</p></div>
        <span className="rounded-full bg-slate-100 px-3 py-1 text-xs font-black text-slate-700">{rows.length}</span>
      </div>
      {rows.length === 0 ? <p className="rounded-2xl border border-dashed border-slate-300 p-5 text-sm text-slate-500">Belum ada Order pada kelompok ini.</p> : <div className="space-y-3">
        {rows.map((order) => {
          const open = expanded === order.salesId
          const canCancel = ['CONFIRMED', 'RESERVED'].includes(order.orderRuntimeStatus)
            && order.totalDispatchedBaseQuantity === 0
          return <article key={order.salesId} className="overflow-hidden rounded-2xl border border-slate-200 bg-white">
            <button type="button" onClick={() => setExpanded(open ? null : order.salesId)} className="flex w-full items-start gap-3 p-4 text-left">
              {order.orderTimingMode === 'SCHEDULED' ? <CalendarClock className="mt-0.5 h-5 w-5 shrink-0 text-blue-600"/> : <PackageCheck className="mt-0.5 h-5 w-5 shrink-0 text-emerald-600"/>}
              <span className="min-w-0 flex-1">
                <strong className="block truncate text-slate-950">{order.orderNo}</strong>
                <span className="mt-1 block text-sm text-slate-600">{order.customerName} · {money(order.grandTotal)}</span>
                <span className="mt-1 block text-xs text-slate-500">{order.orderTimingMode === 'SCHEDULED' ? `Rencana ${date(order.plannedOrderDate)}` : order.storeName} · {statusLabel(order.orderRuntimeStatus)}</span>
              </span>
              <ChevronDown className={`mt-1 h-5 w-5 shrink-0 text-slate-400 transition ${open ? 'rotate-180' : ''}`}/>
            </button>
            {open && <div className="border-t border-slate-100 bg-slate-50 p-4">
              <div className="space-y-2">{order.lines.map((line) => <div key={line.id} className="flex justify-between gap-4 text-sm"><span><strong className="text-slate-800">{line.productName}</strong><small className="block text-slate-500">{line.productSku} · {line.warehouseName}</small></span><span className="text-right font-bold text-slate-700">{line.reservedBaseQuantity}<small className="block font-normal text-slate-500">kurang {line.shortageBaseQuantity}</small></span></div>)}</div>
              {canCancel && <button type="button" onClick={() => { setCancelTarget(order); setCancelReason(''); setError('') }} className="mt-4 inline-flex min-h-10 items-center gap-2 rounded-xl border border-rose-200 px-4 text-sm font-black text-rose-700"><Ban className="h-4 w-4"/>Batalkan Order</button>}
            </div>}
          </article>
        })}
      </div>}
    </section>
  }

  return <div className="fixed inset-0 z-[70] bg-black/65 p-3 sm:p-6">
    <section className="ml-auto flex h-full w-full max-w-3xl flex-col overflow-hidden rounded-3xl bg-white shadow-2xl">
      <header className="flex items-start justify-between border-b border-slate-200 p-5">
        <div><p className="text-xs font-black uppercase tracking-wider text-emerald-700">Reserved Out</p><h2 className="mt-1 text-2xl font-black text-slate-950">Order aktif</h2><p className="mt-1 text-sm text-slate-500">Order sudah dikonfirmasi dan tidak lagi memenuhi daftar Draft.</p></div>
        <button type="button" onClick={close} className="rounded-xl bg-slate-100 p-2 text-slate-700" aria-label="Tutup daftar Order"><X className="h-5 w-5"/></button>
      </header>
      <div className="flex items-center justify-between border-b border-slate-100 px-5 py-3">
        <span className="text-sm font-bold text-slate-600">{query.trim() ? `${filteredOrders.length} dari ${orders.length}` : orders.length} Order</span>
        <button type="button" onClick={() => void refresh()} disabled={loading || busy} className="inline-flex min-h-10 items-center gap-2 rounded-xl border border-slate-200 px-4 text-sm font-black text-slate-700 disabled:opacity-40"><RefreshCw className={`h-4 w-4 ${loading ? 'animate-spin' : ''}`}/>Muat ulang</button>
      </div>
      <div className="border-b border-slate-100 px-5 py-4">
        <label className="relative block">
          <Search className="pointer-events-none absolute left-4 top-1/2 h-5 w-5 -translate-y-1/2 text-slate-400"/>
          <input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Cari nomor Order, nama Customer, atau kode Customer..." className="min-h-12 w-full rounded-xl border border-slate-300 bg-white py-3 pl-12 pr-4 text-sm text-slate-900 outline-none placeholder:text-slate-400 focus:border-emerald-500 focus:ring-2 focus:ring-emerald-100"/>
        </label>
      </div>
      {error && <p className="mx-5 mt-4 rounded-xl bg-rose-50 p-3 text-sm font-semibold text-rose-700">{error}</p>}
      <div className="flex-1 space-y-7 overflow-y-auto p-5">{filteredOrders.length === 0 && query.trim() ? <p className="rounded-2xl border border-dashed border-slate-300 p-6 text-center text-sm font-semibold text-slate-500">Order tidak ditemukan.</p> : <>{group('Order aktif', 'Siap diproses gudang atau sedang dikirim.', active)}{group('Order terjadwal', 'Stok sudah dicadangkan untuk tanggal rencana.', scheduled)}</>}</div>
    </section>
    {cancelTarget && <div className="fixed inset-0 z-[80] grid place-items-center bg-black/70 p-4"><section className="w-full max-w-lg rounded-3xl bg-white p-6 text-slate-950"><h3 className="text-xl font-black">Batalkan {cancelTarget.orderNo}?</h3><p className="mt-1 text-sm text-slate-500">Reserved Out yang belum dikirim akan dilepas. Jika pembayaran Cash berasal dari sesi lama yang sudah tutup, pengembaliannya dicatat pada sesi aktif toko ini. Histori tetap tersimpan.</p><textarea value={cancelReason} onChange={(event) => setCancelReason(event.target.value)} rows={4} maxLength={500} placeholder="Alasan pembatalan" className="mt-5 w-full rounded-xl border border-slate-300 p-3"/>{error && <p className="mt-3 rounded-xl bg-rose-50 p-3 text-sm text-rose-700">{error}</p>}<div className="mt-5 flex justify-end gap-3"><button type="button" onClick={() => setCancelTarget(null)} disabled={busy} className="min-h-11 rounded-xl border px-5 font-bold">Kembali</button><button type="button" onClick={() => void cancel()} disabled={busy || cancelReason.trim().length < 3} className="min-h-11 rounded-xl bg-rose-600 px-5 font-black text-white disabled:opacity-40">{busy ? 'Memproses...' : 'Batalkan Order'}</button></div></section></div>}
  </div>
}
