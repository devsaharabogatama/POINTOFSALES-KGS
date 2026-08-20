import { useCallback, useEffect, useState } from 'react'
import {
  BanknoteArrowDown,
  CircleDollarSign,
  FileCheck2,
  PlusCircle,
  RefreshCw,
  RotateCcw,
  X,
} from 'lucide-react'
import {
  disburseAdditionalCashExpense,
  listApprovedAdditionalCashExpenses,
  listOutstandingExpenses,
  requestAdditionalExpenseDisbursement,
  returnCashExpenseFunds,
  saveExpenseSettlement,
  type ApprovedAdditionalCashExpense,
  type CashierSession,
  type CatalogData,
  type OutstandingExpense,
} from './lib/pos'
import { CurrencyInput } from './CurrencyInput'

type Operation = 'ACTUAL' | 'RETURN' | 'ADDITIONAL'

function rupiah(value: number) {
  return new Intl.NumberFormat('id-ID', {
    style: 'currency', currency: 'IDR', maximumFractionDigits: 0,
  }).format(value)
}

function friendlyError(error: unknown) {
  const code = error instanceof Error ? error.message : 'UNKNOWN_ERROR'
  const labels: Record<string, string> = {
    MASTER_VERSION_CONFLICT: 'Expense berubah. Muat ulang daftar sebelum mengulangi.',
    EXPENSE_NOT_SETTLEABLE: 'Expense ini tidak lagi dapat diselesaikan.',
    EXPENSE_ACTUAL_EXCEEDS_OUTSTANDING: 'Biaya aktual melebihi dana outstanding. Ajukan dana tambahan terlebih dahulu.',
    EXPENSE_SETTLEMENT_EVIDENCE_REQUIRED: 'Link bukti biaya aktual wajib diisi.',
    EXPENSE_SETTLEMENT_EVIDENCE_HTTPS_REQUIRED: 'Link bukti harus menggunakan HTTPS.',
    EXPENSE_RETURN_EXCEEDS_OUTSTANDING: 'Nominal pengembalian melebihi outstanding.',
    OPEN_EXPENSE_RETURN_SESSION_REQUIRED: 'Pengembalian tunai memerlukan sesi kasir yang masih terbuka.',
    EXPENSE_CASH_RETURN_RECEIVER_REQUIRED: 'User ini tidak boleh menerima pengembalian pada sesi tersebut.',
    EXPENSE_RETURN_EVIDENCE_REQUIRED: 'Metode ini mewajibkan link bukti pengembalian.',
    EXPENSE_ADDITIONAL_REQUEST_NOT_ALLOWED: 'Expense ini tidak dapat menerima pengajuan dana tambahan.',
    EXPENSE_ADDITIONAL_EVIDENCE_REQUIRED: 'Link bukti permintaan tambahan wajib diisi.',
    ONLY_APPROVED_ADDITIONAL_REQUEST_DISBURSABLE: 'Permintaan tambahan ini tidak lagi siap dicairkan.',
    EXPENSE_ADDITIONAL_DOCUMENT_NOT_OPEN: 'Dokumen Expense ini sudah tidak terbuka.',
    OPEN_EXPENSE_SESSION_REQUIRED: 'Pencairan tunai memerlukan sesi kasir yang masih terbuka.',
    ACTIVE_EXPENSE_TERMINAL_REQUIRED: 'Terminal sesi ini tidak lagi aktif.',
    EXPENSE_CASH_DISBURSER_REQUIRED: 'User ini tidak boleh mencairkan tunai pada sesi tersebut.',
    EXPENSE_ADDITIONAL_DISBURSEMENT_EVIDENCE_REQUIRED: 'Metode ini mewajibkan link bukti pembayaran.',
    EXPENSE_ADDITIONAL_EVIDENCE_HTTPS_REQUIRED: 'Link bukti harus menggunakan HTTPS.',
    EXPENSE_EXPECTED_CASH_NOT_RESOLVED: 'Expected cash sesi tidak dapat dihitung. Muat ulang sesi.',
    INSUFFICIENT_EXPECTED_CASH: 'Expected cash sesi tidak cukup untuk pencairan tambahan ini.',
    EXPENSE_ADDITIONAL_CASH_DRAWER_EFFECT_NOT_FOUND: 'Efek kas pencairan tidak ditemukan. Muat ulang sebelum mencoba lagi.',
  }
  return labels[code] ?? code.replaceAll('_', ' ')
}

export function ExpenseSettlementPanel({
  cashierSession,
  catalog,
  busy,
  setBusy,
  completed,
}: {
  cashierSession: CashierSession
  catalog: CatalogData
  busy: boolean
  setBusy: (value: boolean) => void
  completed: (message: string, expectedCashAfter?: number) => void
}) {
  const [items, setItems] = useState<OutstandingExpense[]>([])
  const [approvedAdditional, setApprovedAdditional] = useState<ApprovedAdditionalCashExpense[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [selected, setSelected] = useState<OutstandingExpense | null>(null)
  const [selectedAdditional, setSelectedAdditional] = useState<ApprovedAdditionalCashExpense | null>(null)
  const [operation, setOperation] = useState<Operation>('ACTUAL')
  const [amount, setAmount] = useState('')
  const [evidenceUrl, setEvidenceUrl] = useState('')
  const [confirmed, setConfirmed] = useState(false)
  const [idempotencyKey, setIdempotencyKey] = useState(() => crypto.randomUUID())

  const load = useCallback(async () => {
    setLoading(true)
    setError('')
    try {
      const [outstanding, additional] = await Promise.all([
        listOutstandingExpenses(cashierSession),
        listApprovedAdditionalCashExpenses(cashierSession),
      ])
      setItems(outstanding)
      setApprovedAdditional(additional)
    } catch (reason) {
      setError(friendlyError(reason))
    } finally {
      setLoading(false)
    }
  }, [cashierSession])

  useEffect(() => { void load() }, [load])

  useEffect(() => {
    const handler = (event: KeyboardEvent) => {
      if (event.key === 'Escape' && !busy) {
        if (selectedAdditional) setSelectedAdditional(null)
        else if (selected) setSelected(null)
      }
    }
    window.addEventListener('keydown', handler)
    return () => window.removeEventListener('keydown', handler)
  }, [busy, selected, selectedAdditional])

  function open(item: OutstandingExpense, next: Operation) {
    setSelected(item)
    setOperation(next)
    setAmount('')
    setEvidenceUrl('')
    setConfirmed(false)
    setIdempotencyKey(crypto.randomUUID())
    setError('')
  }

  function openAdditional(item: ApprovedAdditionalCashExpense) {
    setSelectedAdditional(item)
    setEvidenceUrl(item.evidenceUrl ?? '')
    setConfirmed(false)
    setIdempotencyKey(crypto.randomUUID())
    setError('')
  }

  async function submitAdditionalCash() {
    if (!selectedAdditional) return
    if (evidenceUrl && !/^https:\/\//i.test(evidenceUrl)) {
      setError('Link bukti harus menggunakan HTTPS.')
      return
    }
    if (!confirmed) {
      setError('Centang konfirmasi setelah memeriksa nominal.')
      return
    }
    setBusy(true)
    setError('')
    try {
      const result = await disburseAdditionalCashExpense({
        requestId: selectedAdditional.requestId,
        requestMasterVersion: selectedAdditional.requestMasterVersion,
        documentMasterVersion: selectedAdditional.documentMasterVersion,
        cashierSessionId: cashierSession.id,
        evidenceUrl,
        idempotencyKey,
      })
      completed(
        `${selectedAdditional.documentNo}: dana tambahan ${rupiah(selectedAdditional.amount)} berhasil dicairkan.`,
        result.expectedCashAfter === null
          ? undefined
          : Number(result.expectedCashAfter),
      )
    } catch (reason) {
      setError(friendlyError(reason))
    } finally {
      setBusy(false)
    }
  }

  async function submit() {
    if (!selected) return
    const numericAmount = Number(amount)
    if (!Number.isFinite(numericAmount) || numericAmount <= 0) {
      setError('Nominal harus lebih dari 0.')
      return
    }
    if (operation !== 'ADDITIONAL' && numericAmount > selected.outstandingAmount) {
      setError('Nominal tidak boleh melebihi outstanding.')
      return
    }
    if (evidenceUrl && !/^https:\/\//i.test(evidenceUrl)) {
      setError('Link bukti harus menggunakan HTTPS.')
      return
    }
    if (operation === 'ACTUAL' && selected.evidenceRequired && !evidenceUrl) {
      setError('Link bukti biaya aktual wajib diisi.')
      return
    }
    const method = catalog.paymentMethods.find(
      (row) => row.id === selected.paymentMethodId,
    )
    if (operation === 'RETURN' && method?.proofRequired && !evidenceUrl) {
      setError('Metode ini mewajibkan link bukti pengembalian.')
      return
    }
    if (!confirmed) {
      setError('Centang konfirmasi setelah memeriksa nominal.')
      return
    }

    setBusy(true)
    setError('')
    try {
      if (operation === 'ACTUAL') {
        await saveExpenseSettlement({
          documentId: selected.documentId,
          masterVersion: selected.masterVersion,
          actualExpenseAmount: numericAmount,
          evidenceUrl,
          idempotencyKey,
        })
        completed(`${selected.documentNo}: biaya aktual ${rupiah(numericAmount)} diajukan untuk review.`)
      } else if (operation === 'RETURN') {
        if (selected.paymentMethodType !== 'CASH') {
          throw new Error('RETURN_NONCASH_USE_BACKOFFICE')
        }
        const result = await returnCashExpenseFunds({
          documentId: selected.documentId,
          masterVersion: selected.masterVersion,
          amount: numericAmount,
          paymentMethodId: selected.paymentMethodId,
          cashierSessionId: cashierSession.id,
          evidenceUrl,
          idempotencyKey,
        })
        completed(
          `${selected.documentNo}: pengembalian tunai ${rupiah(numericAmount)} diterima.`,
          result.expectedCashAfter === null
            ? undefined
            : Number(result.expectedCashAfter),
        )
      } else {
        await requestAdditionalExpenseDisbursement({
          documentId: selected.documentId,
          masterVersion: selected.masterVersion,
          amount: numericAmount,
          paymentMethodId: selected.paymentMethodId,
          evidenceUrl,
          idempotencyKey,
        })
        completed(`${selected.documentNo}: permintaan tambahan ${rupiah(numericAmount)} diajukan. Dana belum dicairkan.`)
      }
    } catch (reason) {
      setError(friendlyError(reason))
    } finally {
      setBusy(false)
    }
  }

  return <div className="pos-expense-cash-body">
    <div className="pos-expense-cash-intro">
      <div><strong>Expense yang perlu diselesaikan</strong><span>Catat biaya aktual, kembalikan sisa dana, atau ajukan tambahan.</span></div>
      <button type="button" onClick={load} disabled={loading || busy}><RefreshCw className={`h-4 w-4 ${loading ? 'animate-spin' : ''}`} /> Muat ulang</button>
    </div>
    {error && <div className="pos-expense-error">{error}</div>}
    {approvedAdditional.length > 0 && <section className="pos-expense-cash-list">
      <div className="pos-expense-cash-intro"><div><strong>Dana tambahan siap dicairkan</strong><span>Permintaan di bawah sudah disetujui. Pencairan tunai akan mengurangi expected cash sesi ini.</span></div></div>
      {approvedAdditional.map((item) => <article key={item.requestId} className="pos-expense-settlement-card">
        <div className="pos-expense-settlement-summary">
          <span><strong>{item.documentNo}</strong><small>{item.categoryName} · {item.responsiblePartyName}</small></span>
          <span><small>Tambahan disetujui</small><strong>{rupiah(item.amount)}</strong></span>
        </div>
        <div className="pos-expense-settlement-metrics"><span>Metode <b>{item.paymentMethodName}</b></span><span>Disetujui <b>{new Date(item.approvedAt).toLocaleString('id-ID')}</b></span></div>
        <div className="pos-expense-settlement-actions"><button type="button" onClick={() => openAdditional(item)}><BanknoteArrowDown className="h-4 w-4" /> Cairkan tambahan tunai</button></div>
      </article>)}
    </section>}
    <div className="pos-expense-cash-list">
      {items.map((item) => <article key={item.documentId} className="pos-expense-settlement-card">
        <div className="pos-expense-settlement-summary">
          <span><strong>{item.documentNo}</strong><small>{item.categoryName} · {item.responsiblePartyName}</small></span>
          <span><small>Outstanding</small><strong>{rupiah(item.outstandingAmount)}</strong></span>
        </div>
        <div className="pos-expense-settlement-metrics"><span>Dicairkan <b>{rupiah(item.disbursedAmount)}</b></span><span>Aktual <b>{rupiah(item.actualExpenseAmount)}</b></span><span>Kembali <b>{rupiah(item.returnedAmount)}</b></span></div>
        <div className="pos-expense-settlement-actions">
          <button type="button" disabled={item.settlementPending} onClick={() => open(item, 'ACTUAL')}><FileCheck2 className="h-4 w-4" /> {item.settlementPending ? 'Aktual menunggu review' : 'Catat biaya aktual'}</button>
          {item.paymentMethodType === 'CASH' && <button type="button" onClick={() => open(item, 'RETURN')}><RotateCcw className="h-4 w-4" /> Kembalikan tunai</button>}
          <button type="button" onClick={() => open(item, 'ADDITIONAL')}><PlusCircle className="h-4 w-4" /> Ajukan tambahan</button>
        </div>
      </article>)}
      {!loading && items.length === 0 && <div className="pos-expense-empty"><CircleDollarSign className="h-10 w-10" /><strong>Tidak ada outstanding Expense</strong><span>Dokumen muncul setelah dana dicairkan.</span></div>}
      {loading && <div className="pos-expense-empty"><RefreshCw className="h-8 w-8 animate-spin" /><strong>Memuat outstanding…</strong></div>}
    </div>

    {selected && <div className="pos-expense-confirm-layer" onMouseDown={(event) => { if (event.currentTarget === event.target && !busy) setSelected(null) }}>
      <section role="dialog" aria-modal="true" className="pos-expense-confirm-card">
        <header><div><small>Penyelesaian Expense</small><h3>{operation === 'ACTUAL' ? 'Catat biaya aktual' : operation === 'RETURN' ? 'Terima pengembalian tunai' : 'Ajukan dana tambahan'}</h3><p>{selected.documentNo} · outstanding {rupiah(selected.outstandingAmount)}</p></div><button type="button" onClick={() => setSelected(null)} disabled={busy} aria-label="Tutup"><X className="h-5 w-5" /></button></header>
        <div className="pos-expense-confirm-content">
          <label>Nominal<span className="pos-expense-money-input"><span>Rp</span><CurrencyInput value={amount} onValueChange={setAmount} autoFocus /></span></label>
          <label>Link bukti HTTPS {operation === 'ACTUAL' && selected.evidenceRequired ? '(wajib)' : '(opsional)'}<input type="url" value={evidenceUrl} onChange={(event) => setEvidenceUrl(event.target.value)} placeholder="https://drive.google.com/…" /></label>
          <div className="pos-expense-boundary">{operation === 'ACTUAL' ? <FileCheck2 className="h-5 w-5" /> : operation === 'RETURN' ? <BanknoteArrowDown className="h-5 w-5" /> : <PlusCircle className="h-5 w-5" />}<div><strong>{operation === 'ACTUAL' ? 'Menunggu review' : operation === 'RETURN' ? 'Langsung menambah expected cash' : 'Belum mencairkan dana'}</strong><span>{operation === 'ACTUAL' ? 'Total Expense belum berubah sebelum Manager/Finance menyetujui.' : operation === 'RETURN' ? 'Pastikan uang benar-benar diterima di laci sesi ini.' : 'Permintaan mengikuti aturan approval dan belum memiliki cash effect.'}</span></div></div>
          <label className="pos-expense-confirm-check"><input type="checkbox" checked={confirmed} onChange={(event) => setConfirmed(event.target.checked)} /><span>Saya sudah memeriksa dokumen dan nominal di atas.</span></label>
        </div>
        <footer><button type="button" onClick={() => setSelected(null)} disabled={busy} className="pos-dialog-secondary">Kembali</button><button type="button" onClick={submit} disabled={busy || !confirmed} className="pos-dialog-primary">{busy ? <RefreshCw className="h-4 w-4 animate-spin" /> : null} Simpan</button></footer>
      </section>
    </div>}

    {selectedAdditional && <div className="pos-expense-confirm-layer" onMouseDown={(event) => { if (event.currentTarget === event.target && !busy) setSelectedAdditional(null) }}>
      <section role="dialog" aria-modal="true" className="pos-expense-confirm-card">
        <header><div><small>Pencairan dana tambahan</small><h3>Cairkan tambahan tunai</h3><p>{selectedAdditional.documentNo} · {rupiah(selectedAdditional.amount)}</p></div><button type="button" onClick={() => setSelectedAdditional(null)} disabled={busy} aria-label="Tutup"><X className="h-5 w-5" /></button></header>
        <div className="pos-expense-confirm-content">
          <div className="pos-expense-boundary"><BanknoteArrowDown className="h-5 w-5" /><div><strong>Nominal sudah dikunci oleh approval</strong><span>{rupiah(selectedAdditional.amount)} melalui {selectedAdditional.paymentMethodName}. Pastikan uang benar-benar keluar dari laci sesi ini.</span></div></div>
          <label>Link bukti HTTPS (opsional)<input type="url" value={evidenceUrl} onChange={(event) => setEvidenceUrl(event.target.value)} placeholder="https://drive.google.com/…" /></label>
          <label className="pos-expense-confirm-check"><input type="checkbox" checked={confirmed} onChange={(event) => setConfirmed(event.target.checked)} /><span>Saya sudah menyerahkan dana sesuai nominal approved di atas.</span></label>
        </div>
        <footer><button type="button" onClick={() => setSelectedAdditional(null)} disabled={busy} className="pos-dialog-secondary">Kembali</button><button type="button" onClick={submitAdditionalCash} disabled={busy || !confirmed} className="pos-dialog-primary">{busy ? <RefreshCw className="h-4 w-4 animate-spin" /> : <BanknoteArrowDown className="h-4 w-4" />} Cairkan dana</button></footer>
      </section>
    </div>}
  </div>
}
