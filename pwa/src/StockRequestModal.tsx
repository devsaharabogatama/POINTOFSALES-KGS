import { useCallback, useEffect, useMemo, useState } from 'react'
import { ClipboardList, Loader2, Plus, RefreshCw, Send, Trash2, X } from 'lucide-react'
import {
  createStockRequest,
  loadStockRequestWorkspace,
  submitStockRequest,
  type PurchaseProductUomOption,
  type StockRequestSummary,
} from './lib/pos'

type FormLine = { key: string; optionKey: string; quantity: string; notes: string }
const newLine = (): FormLine => ({ key: crypto.randomUUID(), optionKey: '', quantity: '', notes: '' })

function friendly(message: string) {
  const known: Record<string, string> = {
    OPEN_CASHIER_SESSION_REQUIRED: 'Sesi kasir aktif tidak ditemukan.',
    STOCK_REQUEST_NEEDED_DATE_IN_PAST: 'Tanggal kebutuhan tidak boleh di masa lalu.',
    STOCK_REQUEST_LINES_REQUIRED: 'Tambahkan minimal satu produk.',
    STOCK_REQUEST_QUANTITY_MUST_BE_POSITIVE: 'Jumlah permintaan harus lebih dari nol.',
    DUPLICATE_STOCK_REQUEST_PRODUCT_UOM: 'Produk dan satuan yang sama tidak boleh diulang.',
    ACTIVE_PURCHASE_PRODUCT_UOM_NOT_FOUND: 'Produk atau satuan pembelian sudah tidak aktif.',
    PURCHASE_UOM_REQUIRES_INTEGER: 'Satuan ini hanya menerima jumlah bilangan bulat.',
  }
  return Object.entries(known).find(([code]) => message.includes(code))?.[1] ?? message
}

export function StockRequestModal({
  companyId,
  cashierSessionId,
  close,
  completed,
}: {
  companyId: string
  cashierSessionId: string
  close: () => void
  completed: (message: string) => void
}) {
  const [options, setOptions] = useState<PurchaseProductUomOption[]>([])
  const [documents, setDocuments] = useState<StockRequestSummary[]>([])
  const [lines, setLines] = useState<FormLine[]>([newLine()])
  const [neededDate, setNeededDate] = useState('')
  const [notes, setNotes] = useState('')
  const [busy, setBusy] = useState(true)
  const [error, setError] = useState('')
  const optionByKey = useMemo(() => new Map(options.map((item) => [`${item.productId}:${item.uomId}`, item])), [options])

  const load = useCallback(async () => {
    setBusy(true); setError('')
    try {
      const result = await loadStockRequestWorkspace(companyId, cashierSessionId)
      setOptions(result.options); setDocuments(result.documents)
    } catch (reason) { setError(friendly(reason instanceof Error ? reason.message : 'Gagal memuat permintaan stok.')) }
    finally { setBusy(false) }
  }, [cashierSessionId, companyId])
  useEffect(() => { void load() }, [load])
  useEffect(() => {
    const handler = (event: KeyboardEvent) => { if (event.key === 'Escape' && !busy) close() }
    window.addEventListener('keydown', handler); return () => window.removeEventListener('keydown', handler)
  }, [busy, close])

  async function saveAndSubmit() {
    setError('')
    const selected = lines.map((line) => ({ line, option: optionByKey.get(line.optionKey) }))
    if (selected.some(({ option }) => !option)) return setError('Pilih produk dan satuan pembelian pada setiap baris.')
    if (new Set(lines.map((line) => line.optionKey)).size !== lines.length) return setError('Produk dan satuan yang sama tidak boleh diulang.')
    if (selected.some(({ line }) => !(Number(line.quantity) > 0))) return setError('Jumlah setiap baris harus lebih dari nol.')
    setBusy(true)
    try {
      const draft = await createStockRequest({
        cashierSessionId,
        neededDate: neededDate || null,
        notes: notes.trim() || null,
        lines: selected.map(({ line, option }) => ({
          clientLineKey: line.key,
          productId: option!.productId,
          uomId: option!.uomId,
          quantity: Number(line.quantity),
          notes: line.notes.trim() || null,
        })),
      })
      await submitStockRequest(draft.documentId, Number(draft.masterVersion))
      completed(`Permintaan stok ${draft.requestNo} berhasil dikirim.`)
    } catch (reason) { setError(friendly(reason instanceof Error ? reason.message : 'Gagal mengirim permintaan stok.')); setBusy(false) }
  }

  return <div className="fixed inset-0 z-[70] bg-black/65 p-3 sm:p-6" onMouseDown={(e) => { if (e.target === e.currentTarget && !busy) close() }}>
    <section role="dialog" aria-modal="true" className="mx-auto flex h-full max-w-4xl flex-col overflow-hidden rounded-2xl bg-white text-slate-900 shadow-2xl">
      <header className="flex items-start justify-between border-b border-slate-200 p-5">
        <div><p className="text-xs font-bold uppercase tracking-wider text-emerald-600">Purchase request</p><h2 className="mt-1 text-xl font-black">Permintaan Stok</h2><p className="mt-1 text-sm text-slate-500">Kasir hanya menyebut barang yang dibutuhkan. Supplier ditentukan manajer di Backoffice.</p></div>
        <button onClick={close} disabled={busy} className="pos-modal-close" aria-label="Tutup"><X className="h-5 w-5" /></button>
      </header>
      <div className="flex-1 overflow-y-auto p-5">
        {error && <div className="mb-4 rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-700">{error}</div>}
        <div className="grid gap-4 sm:grid-cols-2"><label className="text-sm font-bold">Dibutuhkan tanggal (opsional)<input type="date" min={new Date().toISOString().slice(0,10)} value={neededDate} onChange={(e) => setNeededDate(e.target.value)} className="mt-2 w-full rounded-xl border border-slate-300 p-3 font-normal" /></label><label className="text-sm font-bold">Catatan (opsional)<input value={notes} onChange={(e) => setNotes(e.target.value)} className="mt-2 w-full rounded-xl border border-slate-300 p-3 font-normal" placeholder="Contoh: stok display hampir habis" /></label></div>
        <div className="mt-5 space-y-3">{lines.map((line, index) => <div key={line.key} className="grid gap-3 rounded-xl border border-slate-200 bg-slate-50 p-4 sm:grid-cols-[1fr_150px_44px]">
          <label className="text-sm font-bold">Produk · satuan pembelian<select value={line.optionKey} onChange={(e) => setLines((all) => all.map((item) => item.key === line.key ? {...item, optionKey:e.target.value} : item))} className="mt-2 w-full rounded-xl border border-slate-300 bg-white p-3 font-normal"><option value="">Pilih produk</option>{options.map((option) => <option key={`${option.productId}:${option.uomId}`} value={`${option.productId}:${option.uomId}`}>{option.productName} · {option.uomName}</option>)}</select></label>
          <label className="text-sm font-bold">Jumlah<input type="number" min="0" step="any" value={line.quantity} onChange={(e) => setLines((all) => all.map((item) => item.key === line.key ? {...item, quantity:e.target.value} : item))} className="mt-2 w-full rounded-xl border border-slate-300 bg-white p-3 font-normal" /></label>
          <button disabled={lines.length === 1} onClick={() => setLines((all) => all.filter((item) => item.key !== line.key))} className="mt-7 grid h-11 w-11 place-items-center rounded-xl border border-rose-200 text-rose-600 disabled:opacity-30" aria-label={`Hapus baris ${index+1}`}><Trash2 className="h-4 w-4" /></button>
        </div>)}</div>
        <button onClick={() => setLines((all) => [...all, newLine()])} className="mt-3 inline-flex items-center gap-2 rounded-xl border border-slate-300 px-4 py-2 text-sm font-bold"><Plus className="h-4 w-4" />Tambah produk</button>
        <div className="mt-7"><div className="mb-3 flex items-center justify-between"><h3 className="font-black">Riwayat permintaan</h3><button onClick={() => void load()} disabled={busy} className="inline-flex items-center gap-2 text-sm font-bold text-slate-600"><RefreshCw className="h-4 w-4" />Muat ulang</button></div>
          {documents.length === 0 ? <p className="rounded-xl bg-slate-50 p-4 text-sm text-slate-500">Belum ada permintaan stok.</p> : <div className="space-y-2">{documents.slice(0,10).map((doc) => <div key={doc.id} className="flex items-center gap-3 rounded-xl border border-slate-200 p-3"><ClipboardList className="h-5 w-5 text-emerald-600"/><div className="min-w-0 flex-1"><p className="font-bold">{doc.requestNo}</p><p className="text-xs text-slate-500">{doc.lineCount} baris · dibutuhkan {doc.neededDate ?? 'belum ditentukan'}</p></div><span className="rounded-full bg-slate-100 px-3 py-1 text-xs font-bold">{doc.status}</span></div>)}</div>}
        </div>
      </div>
      <footer className="flex justify-end gap-3 border-t border-slate-200 p-4"><button onClick={close} disabled={busy} className="rounded-xl border border-slate-300 px-4 py-3 font-bold">Batal</button><button onClick={() => void saveAndSubmit()} disabled={busy || options.length === 0} className="inline-flex items-center gap-2 rounded-xl bg-emerald-500 px-5 py-3 font-black text-slate-950 disabled:opacity-50">{busy ? <Loader2 className="h-4 w-4 animate-spin"/> : <Send className="h-4 w-4"/>}Kirim permintaan</button></footer>
    </section>
  </div>
}
