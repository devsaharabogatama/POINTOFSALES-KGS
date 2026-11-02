import { useState } from 'react'
import { Package, Plus, Trash2, X } from 'lucide-react'
import { CurrencyInput } from './CurrencyInput'
import type { KetulIntakeLineInput, ProductOption } from './lib/pos'

type DraftRow = {
  key: string
  productId: string
  quantity: string
  unitPrice: string
}

function toDraft(line?: KetulIntakeLineInput): DraftRow {
  return {
    key: crypto.randomUUID(),
    productId: line?.productId ?? '',
    quantity: line ? String(line.quantity) : '',
    unitPrice: line ? String(line.unitPrice) : '',
  }
}

export function KetulIntakeModal(props: {
  products: ProductOption[]
  initialLines: KetulIntakeLineInput[]
  saleTotal: number
  onClose: () => void
  onSave: (lines: KetulIntakeLineInput[]) => void
}) {
  const { products, initialLines, saleTotal, onClose, onSave } = props
  const rows = initialLines.length > 0 ? initialLines.map(toDraft) : [toDraft()]

  function commit(nextRows: DraftRow[]) {
    const merged = new Map<string, KetulIntakeLineInput>()
    for (const row of nextRows) {
      const quantity = Number(row.quantity)
      const unitPrice = Number(row.unitPrice)
      if (!row.productId || !(quantity > 0) || !(unitPrice > 0)) {
        throw new Error('Lengkapi jenis Ketul, qty, dan harga positif.')
      }
      const existing = merged.get(row.productId)
      if (existing && existing.unitPrice !== unitPrice) {
        throw new Error('Jenis Ketul yang sama harus memakai harga yang sama.')
      }
      merged.set(row.productId, {
        productId: row.productId,
        quantity: (existing?.quantity ?? 0) + quantity,
        unitPrice,
      })
    }
    const lines = Array.from(merged.values())
    const total = lines.reduce(
      (sum, line) => sum + line.quantity * line.unitPrice,
      0,
    )
    if (total > saleTotal) {
      throw new Error('Potongan Ketul tidak boleh melebihi total belanja.')
    }
    onSave(lines)
  }

  return (
    <div className="pos-action-dialog-overlay fixed inset-0 z-[80] grid place-items-center bg-black/65 p-4">
      <KetulForm
        products={products}
        initialRows={rows}
        saleTotal={saleTotal}
        onClose={onClose}
        onCommit={commit}
      />
    </div>
  )
}

function KetulForm(props: {
  products: ProductOption[]
  initialRows: DraftRow[]
  saleTotal: number
  onClose: () => void
  onCommit: (rows: DraftRow[]) => void
}) {
  const [rows, setRows] = useState(props.initialRows)
  const [error, setError] = useState('')
  const total = rows.reduce(
    (sum, row) => sum + Number(row.quantity || 0) * Number(row.unitPrice || 0),
    0,
  )

  function patch(key: string, value: Partial<DraftRow>) {
    setRows((current) => current.map((row) => row.key === key
      ? { ...row, ...value }
      : row))
  }

  return (
    <section role="dialog" aria-modal="true" aria-labelledby="ketul-title"
      className="pos-ketul-dialog">
      <header className="pos-ketul-dialog-header">
        <div className="pos-ketul-dialog-title">
          <span aria-hidden="true"><Package /></span>
          <div>
          <p>
            Penerimaan barang dari customer
          </p>
          <h2 id="ketul-title">Pengembalian Ketul</h2>
          </div>
        </div>
        <button type="button" aria-label="Tutup" onClick={props.onClose}
          className="pos-ketul-close"><X /></button>
        <p className="pos-ketul-dialog-description">
          Catat Ketul yang diterima dari customer. Stock bertambah saat transaksi selesai dan nilainya mengurangi pembayaran setelah pajak.
        </p>
      </header>

      <div className="pos-ketul-lines">
        {rows.map((row, index) => (
          <article key={row.key} className="pos-ketul-line">
            <div className="pos-ketul-line-heading">
              <strong>Ketul {index + 1}</strong>
              <button type="button" aria-label={`Hapus baris ${index + 1}`}
                disabled={rows.length === 1}
                onClick={() => setRows((current) => current.filter((item) => item.key !== row.key))}>
                <Trash2 /> Hapus
              </button>
            </div>
            <div className="pos-ketul-line-fields">
            <label>
              Jenis Ketul
              <select value={row.productId}
                onChange={(event) => patch(row.key, { productId: event.target.value })}>
                <option value="">Pilih produk</option>
                {props.products.map((product) => (
                  <option key={product.productId} value={product.productId}>
                    {product.name} · {product.sku}
                  </option>
                ))}
              </select>
            </label>
            <label>
              Qty
              <input type="number" min="0" step="0.001" value={row.quantity}
                onChange={(event) => patch(row.key, { quantity: event.target.value })} />
            </label>
            <label>
              Harga per unit
              <CurrencyInput value={row.unitPrice}
                onValueChange={(unitPrice) => patch(row.key, { unitPrice })}
                placeholder="Rp 0" />
            </label>
            </div>
          </article>
        ))}
      </div>

      <button type="button" onClick={() => setRows((current) => [...current, toDraft()])}
        className="pos-ketul-add-line">
        <Plus /> Tambah jenis Ketul
      </button>

      {error && <p className="pos-ketul-error">{error}</p>}
      <footer className="pos-ketul-footer">
        <div className="pos-ketul-total">
          <span>Total potongan Ketul</span>
          <strong className={total > props.saleTotal ? 'is-over' : ''}>
            Rp {total.toLocaleString('id-ID')}
          </strong>
          <small>Batas maksimal: Rp {props.saleTotal.toLocaleString('id-ID')}</small>
        </div>
        <div className="pos-ketul-footer-actions">
          {props.initialRows.some((row) => row.productId) && (
            <button type="button" onClick={() => props.onCommit([])}
              className="is-remove">
              Hapus semua
            </button>
          )}
          <button type="button" onClick={props.onClose}
            className="is-cancel">Batal</button>
          <button type="button" onClick={() => {
            try { setError(''); props.onCommit(rows) }
            catch (reason) { setError(reason instanceof Error ? reason.message : 'Data Ketul tidak valid.') }
          }} className="is-primary">
            Terapkan Potongan
          </button>
        </div>
      </footer>
    </section>
  )
}
