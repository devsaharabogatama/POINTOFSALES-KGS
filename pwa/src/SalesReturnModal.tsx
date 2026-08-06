import { useEffect, useMemo, useState } from 'react'
import { ArrowLeft, PackageCheck, RefreshCw, RotateCcw, Search, X } from 'lucide-react'
import {
  loadDamagedWarehouses,
  loadReturnableSales,
  saveSalesReturnDraft,
  type CashierSession,
  type CatalogData,
  type DamagedWarehouseOption,
  type ReturnableSale,
} from './lib/pos'

type ReturnLineInput = {
  selected: boolean
  quantity: string
  condition: 'SALEABLE' | 'DAMAGED' | 'NO_PHYSICAL_RETURN'
  destinationWarehouseId: string
}

type Props = {
  companyId: string
  cashierSession: CashierSession
  catalog: CatalogData
  close: () => void
  completed: (message: string) => void
}

function money(value: number) {
  return `Rp ${Math.round(value).toLocaleString('id-ID')}`
}

function round4(value: number) {
  return Math.round((value + Number.EPSILON) * 10_000) / 10_000
}

function errorMessage(error: unknown) {
  if (error instanceof Error) return error.message
  return 'Terjadi kesalahan saat menyimpan Return.'
}

export function SalesReturnModal({
  companyId,
  cashierSession,
  catalog,
  close,
  completed,
}: Props) {
  const [sales, setSales] = useState<ReturnableSale[]>([])
  const [damagedWarehouses, setDamagedWarehouses] = useState<
    DamagedWarehouseOption[]
  >([])
  const [selectedSaleId, setSelectedSaleId] = useState('')
  const [lineInputs, setLineInputs] = useState<Record<string, ReturnLineInput>>({})
  const [search, setSearch] = useState('')
  const [rounding, setRounding] = useState<'NONE' | 'DOWN' | 'UP'>('NONE')
  const [paymentMethodId, setPaymentMethodId] = useState('')
  const [transferDestination, setTransferDestination] = useState('')
  const [transferReference, setTransferReference] = useState('')
  const [proofUrl, setProofUrl] = useState('')
  const [notes, setNotes] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const selectedSale = sales.find((sale) => sale.salesId === selectedSaleId)
  const refundMethods = catalog.paymentMethods.filter((method) =>
    ['CASH', 'TRANSFER'].includes(method.methodType),
  )
  const selectedMethod = refundMethods.find(
    (method) => method.id === paymentMethodId,
  )

  async function refresh(query = search) {
    setBusy(true)
    setError('')
    try {
      const [nextSales, warehouses] = await Promise.all([
        loadReturnableSales(companyId, query),
        loadDamagedWarehouses(companyId),
      ])
      setSales(nextSales.filter((sale) => sale.storeId === cashierSession.storeId))
      setDamagedWarehouses(warehouses)
    } catch (reason) {
      setError(errorMessage(reason))
    } finally {
      setBusy(false)
    }
  }

  useEffect(() => {
    void refresh('')
    setPaymentMethodId(
      refundMethods.find((method) => method.isDefault)?.id ??
        refundMethods[0]?.id ??
        '',
    )
    // Initial load is scoped by the immutable Session passed to this modal.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  useEffect(() => {
    const handler = (event: KeyboardEvent) => {
      if (event.key === 'Escape' && !busy) close()
    }
    window.addEventListener('keydown', handler)
    return () => window.removeEventListener('keydown', handler)
  }, [busy, close])

  function selectSale(sale: ReturnableSale) {
    setSelectedSaleId(sale.salesId)
    setLineInputs(
      Object.fromEntries(
        sale.lines.map((line) => [
          line.sourceSalesDetailId,
          {
            selected: false,
            quantity: String(line.remainingQuantity),
            condition: 'SALEABLE' as const,
            destinationWarehouseId: '',
          },
        ]),
      ),
    )
    setError('')
  }

  const calculation = useMemo(() => {
    if (!selectedSale) return { selectedCount: 0, refundBefore: 0, total: 0 }
    let refundBefore = 0
    let selectedCount = 0
    let allRemainingSelected = true
    for (const line of selectedSale.lines) {
      const input = lineInputs[line.sourceSalesDetailId]
      const quantity = Number(input?.quantity ?? 0)
      if (!input?.selected || quantity <= 0) {
        allRemainingSelected = false
        continue
      }
      selectedCount += 1
      if (quantity !== line.remainingQuantity) allRemainingSelected = false
      refundBefore += line.refundableLineAmount * quantity / line.soldQuantity
    }
    refundBefore = round4(refundBefore)
    let total = refundBefore
    if (allRemainingSelected && selectedCount === selectedSale.lines.length) {
      total = round4(selectedSale.grandTotal - selectedSale.priorRefundTotal)
    } else if (rounding === 'DOWN') {
      total = Math.floor(refundBefore / 100) * 100
    } else if (rounding === 'UP') {
      total = Math.ceil(refundBefore / 100) * 100
    }
    return { selectedCount, refundBefore, total: round4(total) }
  }, [lineInputs, rounding, selectedSale])

  function updateLine(id: string, patch: Partial<ReturnLineInput>) {
    setLineInputs((current) => ({
      ...current,
      [id]: { ...current[id], ...patch },
    }))
  }

  async function submit(event: React.FormEvent) {
    event.preventDefault()
    if (!selectedSale) return
    const lines = selectedSale.lines.flatMap((line) => {
      const input = lineInputs[line.sourceSalesDetailId]
      if (!input?.selected) return []
      const quantity = Number(input.quantity)
      if (!(quantity > 0 && quantity <= line.remainingQuantity)) {
        setError(`Qty Return ${line.productName} tidak valid.`)
        return []
      }
      return [{
        sourceSalesDetailId: line.sourceSalesDetailId,
        quantity,
        condition: input.condition,
        destinationWarehouseId: input.destinationWarehouseId || undefined,
      }]
    })
    if (lines.length !== calculation.selectedCount || lines.length === 0) {
      setError('Pilih minimal satu item dengan Qty Return yang valid.')
      return
    }
    if (!paymentMethodId || calculation.total <= 0) {
      setError('Pilih cara pengembalian dana yang tersedia.')
      return
    }
    if (selectedMethod?.methodType === 'TRANSFER' &&
        (!transferDestination.trim() || !transferReference.trim())) {
      setError('Tujuan transfer dan nomor referensi wajib diisi.')
      return
    }
    if (proofUrl && !/^https:\/\//i.test(proofUrl)) {
      setError('Link bukti harus menggunakan HTTPS.')
      return
    }
    const damagedWithoutWarehouse = lines.some(
      (line) => line.condition === 'DAMAGED' && !line.destinationWarehouseId,
    )
    if (damagedWithoutWarehouse) {
      setError('Pilih Gudang Rusak untuk item dengan kondisi Rusak.')
      return
    }

    setBusy(true)
    setError('')
    try {
      const result = await saveSalesReturnDraft({
        sourceSalesId: selectedSale.salesId,
        executingSessionId: cashierSession.id,
        roundingDirection: rounding,
        notes,
        lines,
        refund: {
          paymentMethodId,
          amount: calculation.total,
          transferDestination: transferDestination.trim(),
          transferReference: transferReference.trim(),
          proofUrl: proofUrl.trim(),
        },
      })
      completed(
        `${result.returnNo} tersimpan sebagai Draft. Menunggu persetujuan Store Manager/Admin.`,
      )
    } catch (reason) {
      setError(errorMessage(reason))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div
      className="pos-return-overlay fixed inset-0 z-50 bg-black/65 p-3 sm:p-6"
      onMouseDown={(event) => {
        if (event.currentTarget === event.target && !busy) close()
      }}
    >
      <section
        role="dialog"
        aria-modal="true"
        aria-labelledby="pos-return-title"
        className="pos-return-panel mx-auto flex h-full w-full max-w-5xl flex-col overflow-hidden bg-white shadow-2xl"
      >
        <header className="pos-return-header">
          <div className="pos-return-title-row">
            {selectedSale && (
              <button type="button" onClick={() => setSelectedSaleId('')} className="pos-return-back">
                <ArrowLeft className="h-5 w-5" />
              </button>
            )}
            <div>
              <p className="pos-eyebrow">Transaksi online</p>
              <h2 id="pos-return-title">Return Penjualan</h2>
              <p>
                {selectedSale
                  ? `${selectedSale.invoiceNo} · pilih barang yang dikembalikan`
                  : 'Cari invoice, lalu buat Draft untuk diperiksa Store Manager/Admin.'}
              </p>
            </div>
          </div>
          <button type="button" onClick={close} disabled={busy} className="pos-modal-close" aria-label="Tutup Return">
            <X className="h-5 w-5" />
          </button>
        </header>

        {error && <div className="pos-return-error">{error}</div>}

        {!selectedSale ? (
          <div className="pos-return-browser">
            <form
              className="pos-return-search"
              onSubmit={(event) => {
                event.preventDefault()
                void refresh(search)
              }}
            >
              <Search className="h-5 w-5" />
              <input
                value={search}
                onChange={(event) => setSearch(event.target.value)}
                placeholder="Cari nomor invoice…"
              />
              <button disabled={busy}>{busy ? 'Mencari…' : 'Cari'}</button>
            </form>
            <div className="pos-return-sale-list">
              {sales.length === 0 && !busy ? (
                <div className="pos-return-empty">
                  <RotateCcw className="h-10 w-10" />
                  <strong>Tidak ada invoice yang dapat diretur</strong>
                  <span>Pastikan invoice sudah posted dan masih memiliki qty tersisa.</span>
                </div>
              ) : sales.map((sale) => (
                <button key={sale.salesId} type="button" onClick={() => selectSale(sale)} className="pos-return-sale-card">
                  <div>
                    <strong>{sale.invoiceNo}</strong>
                    <span>{new Date(sale.transactionDate).toLocaleString('id-ID')}</span>
                    <span>{catalog.customers.find((customer) => customer.id === sale.customerId)?.name ?? 'Customer'}</span>
                  </div>
                  <div>
                    <strong>{money(sale.grandTotal - sale.priorRefundTotal)}</strong>
                    <span>{sale.lines.length} item dapat diretur</span>
                  </div>
                </button>
              ))}
            </div>
          </div>
        ) : (
          <form onSubmit={submit} className="pos-return-form">
            <div className="pos-return-content">
              <section className="pos-return-lines">
                <div className="pos-return-section-title">
                  <PackageCheck className="h-5 w-5" />
                  <div><strong>Barang yang dikembalikan</strong><span>Centang item dan isi jumlah aktual.</span></div>
                </div>
                {selectedSale.lines.map((line) => {
                  const input = lineInputs[line.sourceSalesDetailId]
                  return (
                    <article key={line.sourceSalesDetailId} className={`pos-return-line ${input?.selected ? 'is-selected' : ''}`}>
                      <label className="pos-return-line-select">
                        <input type="checkbox" checked={input?.selected ?? false} onChange={(event) => updateLine(line.sourceSalesDetailId, { selected: event.target.checked })} />
                        <span><strong>{line.productName}</strong><small>Terjual {line.soldQuantity} {line.uomName} · sisa {line.remainingQuantity}</small></span>
                      </label>
                      {input?.selected && (
                        <div className="pos-return-line-fields">
                          <label>Qty Return
                            <input type="number" min="0.000001" max={line.remainingQuantity} step="any" value={input.quantity} onChange={(event) => updateLine(line.sourceSalesDetailId, { quantity: event.target.value })} />
                          </label>
                          <label>Kondisi barang
                            <select value={input.condition} onChange={(event) => updateLine(line.sourceSalesDetailId, { condition: event.target.value as ReturnLineInput['condition'], destinationWarehouseId: '' })}>
                              <option value="SALEABLE">Layak jual — kembali ke stok toko</option>
                              <option value="DAMAGED">Rusak — masuk Gudang Rusak</option>
                              <option value="NO_PHYSICAL_RETURN">Tanpa barang kembali</option>
                            </select>
                          </label>
                          {input.condition === 'DAMAGED' && (
                            <label>Gudang Rusak
                              <select required value={input.destinationWarehouseId} onChange={(event) => updateLine(line.sourceSalesDetailId, { destinationWarehouseId: event.target.value })}>
                                <option value="">Pilih Gudang Rusak</option>
                                {damagedWarehouses.map((warehouse) => <option key={warehouse.id} value={warehouse.id}>{warehouse.name}</option>)}
                              </select>
                            </label>
                          )}
                        </div>
                      )}
                    </article>
                  )
                })}
              </section>

              <aside className="pos-return-summary">
                <h3>Pengembalian dana</h3>
                <label>Pembulatan Return
                  <select value={rounding} onChange={(event) => setRounding(event.target.value as typeof rounding)}>
                    <option value="NONE">Tanpa pembulatan</option>
                    <option value="DOWN">Bulatkan ke bawah Rp100</option>
                    <option value="UP">Bulatkan ke atas Rp100</option>
                  </select>
                </label>
                <label>Cara refund
                  <select required value={paymentMethodId} onChange={(event) => setPaymentMethodId(event.target.value)}>
                    <option value="">Pilih cara refund</option>
                    {refundMethods.map((method) => <option key={method.id} value={method.id}>{method.name}</option>)}
                  </select>
                </label>
                {selectedMethod?.methodType === 'TRANSFER' && <>
                  <label>Tujuan transfer<input required value={transferDestination} onChange={(event) => setTransferDestination(event.target.value)} placeholder="Bank / nomor rekening tujuan" /></label>
                  <label>Nomor referensi<input required value={transferReference} onChange={(event) => setTransferReference(event.target.value)} placeholder="Referensi transfer" /></label>
                  <label>Link bukti HTTPS (opsional)<input type="url" value={proofUrl} onChange={(event) => setProofUrl(event.target.value)} placeholder="https://…" /></label>
                </>}
                <label>Catatan (opsional)<textarea rows={3} maxLength={500} value={notes} onChange={(event) => setNotes(event.target.value)} /></label>
                <div className="pos-return-total">
                  <span>Nilai item</span><strong>{money(calculation.refundBefore)}</strong>
                  <span>Pembulatan</span><strong>{money(calculation.total - calculation.refundBefore)}</strong>
                  <span>Total refund</span><strong>{money(calculation.total)}</strong>
                </div>
                <p className="pos-return-approval-note">Draft belum mengubah stok atau kas. Store Manager/Admin harus memeriksa dan posting.</p>
              </aside>
            </div>
            <footer className="pos-return-footer">
              <button type="button" onClick={close} disabled={busy} className="pos-dialog-secondary">Batal</button>
              <button disabled={busy || calculation.selectedCount === 0 || calculation.total <= 0} className="pos-dialog-primary">
                {busy ? <><RefreshCw className="h-4 w-4 animate-spin" /> Menyimpan…</> : 'Simpan Draft Return'}
              </button>
            </footer>
          </form>
        )}
      </section>
    </div>
  )
}
