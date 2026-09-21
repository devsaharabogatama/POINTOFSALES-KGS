import { useCallback, useEffect, useMemo, useState } from 'react'
import {
  Banknote,
  ChevronDown,
  ChevronUp,
  CreditCard,
  FileText,
  Loader2,
  Package,
  RefreshCw,
  Search,
  SquareArrowOutUpRight,
  X,
} from 'lucide-react'
import {
  loadCashierSessionSummary,
  type CashierSession,
  type CashierSessionSummary,
  type CashierSessionSummaryTransaction,
  type PaymentMethodOption,
} from './lib/pos'

function money(value: number) {
  return new Intl.NumberFormat('id-ID', {
    style: 'currency',
    currency: 'IDR',
    maximumFractionDigits: 0,
  }).format(value)
}

function dateTime(value: string) {
  if (!value) return '-'
  return new Date(value).toLocaleString('id-ID', {
    day: '2-digit',
    month: 'short',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  })
}

function statusLabel(value: string) {
  const labels: Record<string, string> = {
    DRAFT_INPUT: 'Draft',
    SCHEDULED: 'Terjadwal',
    CONFIRMED: 'Dikonfirmasi',
    RESERVED: 'Disiapkan',
    PARTIALLY_DISPATCHED: 'Dikirim sebagian',
    DISPATCHED: 'Dikirim',
    DELIVERED: 'Diterima',
    POSTED: 'Selesai',
    LEGACY_POSTED: 'Selesai',
    CANCELED: 'Dibatalkan',
  }
  return labels[value] ?? (value || 'Tercatat')
}

export function SessionSummaryModal({
  cashierSession,
  paymentMethods,
  close,
  openTransaction,
}: {
  cashierSession: CashierSession
  paymentMethods: PaymentMethodOption[]
  close: () => void
  openTransaction: (
    transaction: CashierSessionSummaryTransaction,
  ) => Promise<void>
}) {
  const [summary, setSummary] = useState<CashierSessionSummary | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [query, setQuery] = useState('')
  const [expandedId, setExpandedId] = useState<string | null>(null)
  const [openingId, setOpeningId] = useState<string | null>(null)

  const methodById = useMemo(
    () => new Map(paymentMethods.map((method) => [method.id, method])),
    [paymentMethods],
  )

  const load = useCallback(async () => {
    setLoading(true)
    setError('')
    try {
      setSummary(await loadCashierSessionSummary(cashierSession.id))
    } catch (caught) {
      setSummary(null)
      setError(caught instanceof Error ? caught.message : 'Ringkasan sesi gagal dimuat.')
    } finally {
      setLoading(false)
    }
  }, [cashierSession.id])

  useEffect(() => {
    void load()
  }, [load])

  useEffect(() => {
    const listener = (event: KeyboardEvent) => {
      if (event.key === 'Escape' && openingId === null) close()
    }
    window.addEventListener('keydown', listener)
    return () => window.removeEventListener('keydown', listener)
  }, [close, openingId])

  const totals = useMemo(() => {
    let cash = 0
    let nonCash = 0
    for (const transaction of summary?.transactions ?? []) {
      if (
        transaction.orderRuntimeStatus === 'CANCELED' ||
        transaction.documentStatus === 'CANCELED'
      ) continue
      for (const payment of transaction.payments) {
        const method = payment.paymentMethodId
          ? methodById.get(payment.paymentMethodId)
          : null
        const legacyName = (payment.paymentMethodName ?? '').toLocaleLowerCase('id-ID')
        const isCash = payment.paymentMethodType === 'CASH' ||
          payment.settlementRoute === 'CASH_DRAWER' ||
          method?.methodType === 'CASH' ||
          legacyName === 'cash' || legacyName === 'tunai'
        if (isCash) {
          cash += payment.amount
        } else {
          nonCash += payment.amount
        }
      }
    }
    return { cash, nonCash, total: cash + nonCash }
  }, [methodById, summary?.transactions])

  const transactions = useMemo(() => {
    const needle = query.trim().toLocaleLowerCase('id-ID')
    if (!needle) return summary?.transactions ?? []
    return (summary?.transactions ?? []).filter((transaction) =>
      [
        transaction.documentNo,
        transaction.orderNo,
        transaction.customerName,
        ...transaction.lines.flatMap((line) => [line.productName, line.productSku]),
      ].some((value) => value.toLocaleLowerCase('id-ID').includes(needle)),
    )
  }, [query, summary?.transactions])

  const openOriginal = async (transaction: CashierSessionSummaryTransaction) => {
    setOpeningId(transaction.salesId)
    setError('')
    try {
      await openTransaction(transaction)
    } catch (caught) {
      setError(
        caught instanceof Error
          ? caught.message
          : 'Dokumen transaksi asli gagal dibuka.',
      )
    } finally {
      setOpeningId(null)
    }
  }

  return (
    <div
      className="pos-session-summary-overlay"
      onMouseDown={(event) => {
        if (event.currentTarget === event.target) close()
      }}
    >
      <section
        role="dialog"
        aria-modal="true"
        aria-labelledby="session-summary-title"
        className="pos-session-summary-dialog"
      >
        <header className="pos-session-summary-header">
          <div>
            <p>SESI KASIR</p>
            <h2 id="session-summary-title">Ringkasan {cashierSession.code}</h2>
            <span>Transaksi dan barang yang dicatat pada sesi aktif.</span>
          </div>
          <div className="pos-session-summary-header-actions">
            <button type="button" onClick={() => void load()} disabled={loading}>
              <RefreshCw className={loading ? 'animate-spin' : ''} />
              Muat ulang
            </button>
            <button type="button" onClick={close} aria-label="Tutup ringkasan sesi">
              <X />
            </button>
          </div>
        </header>

        {error && <p className="pos-session-summary-error">{error}</p>}

        <div className="pos-session-summary-totals">
          <article>
            <Banknote />
            <span>Cash diterima</span>
            <strong>{money(totals.cash)}</strong>
          </article>
          <article>
            <CreditCard />
            <span>Non-cash tercatat</span>
            <strong>{money(totals.nonCash)}</strong>
            <small>Termasuk yang masih menunggu verifikasi.</small>
          </article>
          <article className="is-total">
            <FileText />
            <span>Total pembayaran tercatat</span>
            <strong>{money(totals.total)}</strong>
          </article>
        </div>

        <label className="pos-session-summary-search">
          <Search />
          <input
            autoFocus
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder="Cari nomor order, customer, SKU, atau produk..."
          />
        </label>

        <div className="pos-session-summary-list">
          {loading && !summary ? (
            <div className="pos-session-summary-empty">
              <Loader2 className="animate-spin" />
              <p>Memuat transaksi sesi...</p>
            </div>
          ) : transactions.length === 0 ? (
            <div className="pos-session-summary-empty">
              <Package />
              <p>Tidak ada transaksi yang cocok.</p>
            </div>
          ) : (
            transactions.map((transaction) => {
              const expanded = expandedId === transaction.salesId
              return (
                <article key={transaction.salesId} className="pos-session-transaction">
                  <button
                    type="button"
                    className="pos-session-transaction-head"
                    onClick={() => setExpandedId(expanded ? null : transaction.salesId)}
                  >
                    <span>
                      <strong>{transaction.orderNo}</strong>
                      <small>
                        {transaction.documentNo !== transaction.orderNo
                          ? `${transaction.documentNo} · `
                          : ''}
                        {transaction.customerName} · {dateTime(transaction.transactionAt)}
                      </small>
                    </span>
                    <span className="pos-session-transaction-state">
                      <em>{statusLabel(
                        transaction.orderRuntimeStatus || transaction.documentStatus,
                      )}</em>
                      <strong>{money(transaction.grandTotal)}</strong>
                      {expanded ? <ChevronUp /> : <ChevronDown />}
                    </span>
                  </button>
                  {expanded && (
                    <div className="pos-session-transaction-detail">
                      <div className="pos-session-line-table">
                        <div className="is-heading">
                          <span>Produk</span><span>Qty</span><span>Harga</span><span>Total</span>
                        </div>
                        {transaction.lines.map((line) => (
                          <div key={line.id}>
                            <span><strong>{line.productName}</strong><small>{line.productSku}</small></span>
                            <span>{line.quantity} {line.uomName}</span>
                            <span>{money(line.unitPrice)}</span>
                            <span>{money(line.lineTotal)}</span>
                          </div>
                        ))}
                      </div>
                      <div className="pos-session-payment-list">
                        <strong>Pembayaran tercatat</strong>
                        {transaction.isTempo && transaction.payments.length === 0 && (
                          <span>Tempo · belum ada pembayaran pada order.</span>
                        )}
                        {transaction.payments.map((payment) => {
                          const method = payment.paymentMethodId
                            ? methodById.get(payment.paymentMethodId)
                            : null
                          return (
                            <span key={payment.key}>
                              {payment.paymentMethodName ?? method?.name ?? 'Metode pembayaran'}
                              <strong>{money(payment.amount)}</strong>
                            </span>
                          )
                        })}
                      </div>
                      <div className="pos-session-document-actions">
                        <p className="pos-session-document-note">
                          Buka dokumen canonical untuk cetak, Return, atau penelusuran lanjutan.
                        </p>
                        <button
                          type="button"
                          disabled={openingId !== null}
                          onClick={() => void openOriginal(transaction)}
                        >
                          {openingId === transaction.salesId
                            ? <Loader2 className="animate-spin" />
                            : <SquareArrowOutUpRight />}
                          Buka dokumen
                        </button>
                      </div>
                    </div>
                  )}
                </article>
              )
            })
          )}
        </div>
      </section>
    </div>
  )
}
