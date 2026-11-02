import { useEffect, useMemo, useState } from 'react'
import {
  Banknote,
  CalendarDays,
  CircleDollarSign,
  FileText,
  RefreshCw,
  ShieldCheck,
  X,
} from 'lucide-react'
import {
  postPosExpense,
  type CashierSession,
  type CatalogData,
} from './lib/pos'
import { ExpenseSettlementPanel } from './ExpenseSettlementPanel'
import { CurrencyInput } from './CurrencyInput'

type Props = {
  cashierSession: CashierSession
  catalog: CatalogData
  actorId: string
  actorName: string
  close: () => void
  completed: (message: string, expectedCashAfter?: number) => void
}

function errorMessage(error: unknown) {
  const code = error instanceof Error ? error.message : 'UNKNOWN_ERROR'
  const labels: Record<string, string> = {
    EXPENSE_FEATURE_DISABLED: 'Fitur Expense belum diaktifkan untuk Company ini.',
    ACTIVE_EXPENSE_CATEGORY_NOT_FOUND: 'Kategori Expense tidak aktif atau sudah berubah.',
    ACTIVE_EXPENSE_PAYMENT_METHOD_NOT_FOUND: 'Metode pembayaran tidak tersedia untuk toko ini.',
    OPEN_EXPENSE_SESSION_REQUIRED: 'Expense tunai memerlukan sesi kasir yang masih terbuka.',
    EXPENSE_SESSION_OPERATOR_REQUIRED: 'Sesi kasir ini bukan milik user yang sedang masuk.',
    EXPENSE_EVIDENCE_REQUIRED: 'Kategori ini mewajibkan link bukti.',
    EXPENSE_EVIDENCE_HTTPS_REQUIRED: 'Link bukti harus menggunakan HTTPS.',
    MASTER_VERSION_CONFLICT: 'Data Expense berubah. Coba ajukan kembali.',
    ONLY_APPROVED_EXPENSE_DISBURSABLE: 'Expense ini sudah berubah dan tidak dapat dicairkan. Muat ulang daftar.',
    EXPENSE_INITIAL_DISBURSEMENT_STATE_INVALID: 'Expense ini sudah memiliki riwayat pencairan.',
    EXPENSE_APPROVAL_SNAPSHOT_INCOMPLETE: 'Bukti approval Expense belum lengkap.',
    ACTIVE_EXPENSE_TERMINAL_REQUIRED: 'Terminal sesi ini tidak lagi aktif.',
    EXPENSE_CASH_DISBURSER_REQUIRED: 'User ini tidak boleh mengeluarkan kas dari sesi tersebut.',
    EXPENSE_EXPECTED_CASH_NOT_RESOLVED: 'Kas sesi tidak dapat dihitung.',
    INSUFFICIENT_EXPECTED_CASH: 'Kas sesi tidak cukup untuk pencairan Expense ini.',
    EXPENSE_DISBURSEMENT_EVIDENCE_REQUIRED: 'Metode pembayaran ini mewajibkan link bukti pencairan.',
    EXPENSE_DISBURSEMENT_EVIDENCE_HTTPS_REQUIRED: 'Link bukti pencairan harus menggunakan HTTPS.',
    EXPENSE_DISBURSEMENT_IDEMPOTENCY_CONFLICT: 'Permintaan pencairan bertentangan dengan percobaan sebelumnya.',
    CLIENT_EXPENSE_ID_CONFLICT: 'Percobaan ulang Expense membawa data yang berbeda. Buat transaksi baru.',
    POS_DIRECT_EXPENSE_OWNERSHIP_REQUIRED: 'Expense harus berasal dari sesi kasir aktif milik user ini.',
    POS_DIRECT_EXPENSE_STATE_INVALID: 'Status Expense sudah berubah dan tidak dapat diproses ulang.',
    ACTIVE_EXPENSE_NONCASH_METHOD_NOT_FOUND: 'Metode non-tunai tidak aktif atau belum memiliki rute pembayaran yang valid.',
  }
  return labels[code] ?? code.replaceAll('_', ' ')
}

function rupiah(value: number) {
  return new Intl.NumberFormat('id-ID', {
    style: 'currency',
    currency: 'IDR',
    maximumFractionDigits: 0,
  }).format(value)
}

export function ExpenseRequestModal({
  cashierSession,
  catalog,
  actorId,
  actorName,
  close,
  completed,
}: Props) {
  const [mode, setMode] = useState<'REQUEST' | 'SETTLEMENT'>('REQUEST')
  const [categoryId, setCategoryId] = useState(
    catalog.expenseCategories[0]?.id ?? '',
  )
  const [amount, setAmount] = useState('')
  const [paymentMethodId, setPaymentMethodId] = useState('')
  const [responsibleType, setResponsibleType] = useState<'CASHIER' | 'EXTERNAL'>(
    'CASHIER',
  )
  const [externalName, setExternalName] = useState('')
  const [recipient, setRecipient] = useState('')
  const [description, setDescription] = useState('')
  const [evidenceUrl, setEvidenceUrl] = useState('')
  const [expectedSettlementDate, setExpectedSettlementDate] = useState('')
  const [clientExpenseId] = useState(() => crypto.randomUUID())
  const [disbursementKey] = useState(() => crypto.randomUUID())
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const selectedCategory = catalog.expenseCategories.find(
    (category) => category.id === categoryId,
  )
  const selectedMethod = catalog.paymentMethods.find(
    (method) => method.id === paymentMethodId,
  )

  const defaultMethodId = useMemo(() => {
    const categoryDefault = catalog.paymentMethods.find(
      (method) => method.id === selectedCategory?.defaultPaymentMethodId,
    )
    return (
      categoryDefault?.id ??
      catalog.paymentMethods.find((method) => method.isDefault)?.id ??
      catalog.paymentMethods[0]?.id ??
      ''
    )
  }, [catalog.paymentMethods, selectedCategory?.defaultPaymentMethodId])

  useEffect(() => {
    setPaymentMethodId((current) =>
      catalog.paymentMethods.some((method) => method.id === current)
        ? current
        : defaultMethodId,
    )
  }, [catalog.paymentMethods, defaultMethodId])

  useEffect(() => {
    const handler = (event: KeyboardEvent) => {
      if (event.key !== 'Escape' || busy) return
      close()
    }
    window.addEventListener('keydown', handler)
    return () => window.removeEventListener('keydown', handler)
  }, [busy, close])

  function changeCategory(nextCategoryId: string) {
    setCategoryId(nextCategoryId)
    const category = catalog.expenseCategories.find(
      (item) => item.id === nextCategoryId,
    )
    const nextMethod = catalog.paymentMethods.find(
      (method) => method.id === category?.defaultPaymentMethodId,
    )
    if (nextMethod) setPaymentMethodId(nextMethod.id)
    setError('')
  }

  async function submit(event: React.FormEvent) {
    event.preventDefault()
    const requestedAmount = Number(amount)
    const responsibleName =
      responsibleType === 'CASHIER' ? actorName : externalName.trim()

    if (!categoryId) {
      setError('Pilih kategori Expense.')
      return
    }
    if (!Number.isFinite(requestedAmount) || requestedAmount <= 0) {
      setError('Nominal pengajuan harus lebih dari 0.')
      return
    }
    if (!paymentMethodId) {
      setError('Pilih metode pembayaran.')
      return
    }
    if (!responsibleName) {
      setError('Isi nama pihak yang bertanggung jawab.')
      return
    }
    if (!description.trim()) {
      setError('Isi keperluan Expense.')
      return
    }
    if (evidenceUrl && !/^https:\/\//i.test(evidenceUrl)) {
      setError('Link bukti harus menggunakan HTTPS.')
      return
    }
    if (selectedCategory?.evidenceRequired && !evidenceUrl.trim()) {
      setError('Kategori ini mewajibkan link bukti.')
      return
    }

    setBusy(true)
    setError('')
    try {
      const result = await postPosExpense({
        storeId: cashierSession.storeId,
        cashierSessionId: cashierSession.id,
        categoryId,
        responsiblePartyType: responsibleType,
        responsiblePartyId: responsibleType === 'CASHIER' ? actorId : null,
        responsiblePartyName: responsibleName,
        requestedAmount,
        paymentMethodId,
        recipient,
        description,
        evidenceUrl,
        expectedSettlementDate,
        clientExpenseId,
        idempotencyKey: disbursementKey,
      })
      completed(
        `${result.documentNo} tercatat sebesar ${rupiah(result.amount)} dan sudah dibayar melalui ${selectedMethod?.name ?? 'metode terpilih'}.`,
        result.expectedCashAfter ?? undefined,
      )
    } catch (reason) {
      setError(errorMessage(reason))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div
      className="pos-expense-overlay fixed inset-0 z-50 bg-black/65 p-3 sm:p-6"
      onMouseDown={(event) => {
        if (event.currentTarget === event.target && !busy) close()
      }}
    >
      <section
        role="dialog"
        aria-modal="true"
        aria-labelledby="pos-expense-title"
        className="pos-expense-panel mx-auto flex h-full w-full max-w-3xl flex-col overflow-hidden bg-white shadow-2xl"
      >
        <header className="pos-expense-header">
          <div>
            <p className="pos-eyebrow">Pengeluaran operasional</p>
            <h2 id="pos-expense-title">Expense Operasional</h2>
            <p>Catat pengeluaran yang sudah dibayar dari sesi kasir ini.</p>
          </div>
          <button
            type="button"
            onClick={close}
            disabled={busy}
            className="pos-modal-close"
            aria-label="Tutup form Expense"
          >
            <X className="h-5 w-5" />
          </button>
        </header>

        <nav className="pos-expense-tabs" aria-label="Tahap Expense">
          <button
            type="button"
            className={mode === 'REQUEST' ? 'is-active' : ''}
            onClick={() => { setMode('REQUEST'); setError('') }}
          >
            <FileText className="h-4 w-4" /> Catat Expense
          </button>
          <button
            type="button"
            className={mode === 'SETTLEMENT' ? 'is-active' : ''}
            onClick={() => { setMode('SETTLEMENT'); setError('') }}
          >
            <CircleDollarSign className="h-4 w-4" /> Penyelesaian
          </button>
        </nav>

        {error && <div className="pos-expense-error">{error}</div>}

        {mode === 'REQUEST' ? (
        <form onSubmit={submit} className="pos-expense-form">
          {catalog.expenseCategories.length === 0 ? (
            <div className="pos-expense-empty">
              <FileText className="h-10 w-10" />
              <strong>Belum ada kategori Expense aktif</strong>
              <span>Company Admin perlu menyiapkan kategori sebelum pengajuan dibuat.</span>
            </div>
          ) : (
            <div className="pos-expense-fields">
              <label>
                Kategori Expense
                <select
                  required
                  value={categoryId}
                  onChange={(event) => changeCategory(event.target.value)}
                >
                  {catalog.expenseCategories.map((category) => (
                    <option key={category.id} value={category.id}>
                      {category.name}
                    </option>
                  ))}
                </select>
              </label>

              <label>
                Nominal Expense
                <span className="pos-expense-money-input">
                  <span>Rp</span>
                  <CurrencyInput
                    required
                    value={amount}
                    onValueChange={setAmount}
                    placeholder="0"
                  />
                </span>
              </label>

              <label>
                Metode pembayaran
                <select
                  required
                  value={paymentMethodId}
                  onChange={(event) => setPaymentMethodId(event.target.value)}
                >
                  <option value="">Pilih metode</option>
                  {catalog.paymentMethods.map((method) => (
                    <option key={method.id} value={method.id}>
                      {method.name}
                    </option>
                  ))}
                </select>
                <small>
                  {selectedMethod?.methodType === 'CASH'
                    ? 'Kas sesi langsung berkurang saat Expense disimpan.'
                    : 'Expense langsung tercatat tanpa mengubah kas laci.'}
                </small>
              </label>

              <label>
                Penanggung jawab dana
                <select
                  value={responsibleType}
                  onChange={(event) =>
                    setResponsibleType(event.target.value as 'CASHIER' | 'EXTERNAL')
                  }
                >
                  <option value="CASHIER">Saya sendiri — {actorName}</option>
                  <option value="EXTERNAL">Pihak luar</option>
                </select>
              </label>

              {responsibleType === 'EXTERNAL' && (
                <label className="pos-expense-wide">
                  Nama pihak luar
                  <input
                    required
                    value={externalName}
                    onChange={(event) => setExternalName(event.target.value)}
                    maxLength={150}
                    placeholder="Nama orang / pihak penerima tanggung jawab"
                  />
                </label>
              )}

              <label className="pos-expense-wide">
                Keperluan Expense
                <textarea
                  required
                  rows={3}
                  maxLength={500}
                  value={description}
                  onChange={(event) => setDescription(event.target.value)}
                  placeholder="Contoh: pembelian bensin operasional toko"
                />
              </label>

              <label>
                Penerima pembayaran (opsional)
                <input
                  value={recipient}
                  onChange={(event) => setRecipient(event.target.value)}
                  maxLength={150}
                  placeholder="Nama toko / vendor / penerima"
                />
              </label>

              <label>
                Target penyelesaian (opsional)
                <span className="pos-expense-icon-input">
                  <CalendarDays className="h-4 w-4" />
                  <input
                    type="date"
                    value={expectedSettlementDate}
                    onChange={(event) => setExpectedSettlementDate(event.target.value)}
                  />
                </span>
              </label>

              <label className="pos-expense-wide">
                Link bukti HTTPS {selectedCategory?.evidenceRequired ? '(wajib)' : '(opsional)'}
                <input
                  required={selectedCategory?.evidenceRequired}
                  type="url"
                  value={evidenceUrl}
                  onChange={(event) => setEvidenceUrl(event.target.value)}
                  placeholder="https://drive.google.com/…"
                />
                <small>Aplikasi hanya menyimpan link, bukan file atau foto.</small>
              </label>
            </div>
          )}

          <div className="pos-expense-boundary">
            <ShieldCheck className="h-5 w-5" />
            <div>
              <strong>Langsung tercatat sebagai pengeluaran</strong>
              <span>
                Tidak ada approval atau pencairan kedua. Cash langsung mengurangi kas sesi; non-tunai tidak mengubah kas laci.
              </span>
            </div>
          </div>

          <footer className="pos-expense-footer">
            <button type="button" onClick={close} disabled={busy} className="pos-dialog-secondary">
              Batal
            </button>
            <button
              disabled={busy || catalog.expenseCategories.length === 0}
              className="pos-dialog-primary"
            >
              {busy ? (
                <><RefreshCw className="h-4 w-4 animate-spin" /> Menyimpan…</>
              ) : (
                <><Banknote className="h-4 w-4" /> Simpan Expense</>
              )}
            </button>
          </footer>
        </form>
        ) : (
          <ExpenseSettlementPanel
            cashierSession={cashierSession}
            catalog={catalog}
            busy={busy}
            setBusy={setBusy}
            completed={completed}
          />
        )}

      </section>
    </div>
  )
}
