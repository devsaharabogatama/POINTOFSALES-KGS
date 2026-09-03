import { useCallback, useEffect, useMemo, useState } from 'react'
import {
  AlertTriangle, ArrowLeft, CheckCircle2, ClipboardCheck, Loader2, Pencil,
  Play, Plus, RefreshCw, RotateCcw, Save, Search, X, XCircle,
} from 'lucide-react'
import {
  cancelStockOpname,
  completeStockOpname,
  loadStockOpnameBlindSession,
  loadStockOpnameWorkspace,
  recordStockOpnameCount,
  requestStockOpnameRecount,
  saveStockOpnameSession,
  startStockOpname,
  type StockOpnameBlindLine,
  type StockOpnameBlindSession,
  type StockOpnameSessionSummary,
  type StockOpnameWorkspace,
} from './lib/pos'

type FormState = {
  opnameId: string | null
  masterVersion: number | null
  warehouseId: string
  scopeType: 'ALL' | 'CATEGORY' | 'SELECTED'
  categoryId: string
  selectedProductIds: string[]
  notes: string
}

type CountDraft = { quantity: string; notes: string }

const emptyForm = (warehouseId = ''): FormState => ({
  opnameId: null,
  masterVersion: null,
  warehouseId,
  scopeType: 'ALL',
  categoryId: '',
  selectedProductIds: [],
  notes: '',
})

function friendly(message: string) {
  const known: Record<string, string> = {
    CUSTOM_PERMISSION_DENIED: 'Izin Stock Opname untuk akun ini dibatasi.',
    STOCK_OPNAME_COUNTER_REQUIRED: 'Akun ini tidak mempunyai akses hitung pada gudang tersebut.',
    STOCK_OPNAME_OWNER_COUNTER_REQUIRED: 'Sesi hanya dapat dilanjutkan oleh petugas pembuatnya.',
    STOCK_OPNAME_NOT_FOUND: 'Sesi Stock Opname tidak ditemukan.',
    STOCK_OPNAME_SCOPE_INVALID: 'Cakupan Stock Opname tidak valid.',
    STOCK_OPNAME_CATEGORY_SCOPE_INVALID: 'Pilih kategori yang aktif.',
    STOCK_OPNAME_SELECTED_PRODUCTS_REQUIRED: 'Pilih minimal satu produk.',
    STOCK_OPNAME_SELECTED_PRODUCT_NOT_ELIGIBLE: 'Salah satu produk sudah tidak memenuhi syarat opname.',
    STOCK_OPNAME_SCOPE_HAS_NO_ELIGIBLE_PRODUCT: 'Tidak ada produk aktif pada cakupan tersebut.',
    STOCK_OPNAME_DRAFT_REQUIRED: 'Sesi ini sudah dimulai dan pengaturannya tidak dapat diubah.',
    STOCK_OPNAME_COUNTING_REQUIRED: 'Sesi belum berada pada tahap penghitungan.',
    STOCK_OPNAME_PHYSICAL_QUANTITY_INVALID: 'Jumlah fisik harus nol atau lebih.',
    STOCK_OPNAME_BASE_UOM_REQUIRES_INTEGER: 'Satuan produk ini hanya menerima bilangan bulat.',
    STOCK_OPNAME_BASE_UOM_PRECISION_EXCEEDED: 'Jumlah fisik melebihi ketelitian satuan produk.',
    STOCK_OPNAME_UNRESOLVED_LINE: 'Masih ada produk yang belum dihitung atau perlu dihitung ulang.',
    STOCK_OPNAME_PARTIAL_CONFIRMATION_REQUIRED: 'Konfirmasi produk yang belum dihitung sebelum mengirim hasil parsial.',
    STOCK_OPNAME_NO_ACTIVE_COUNTED_LINE: 'Belum ada hasil hitungan yang dapat diselesaikan.',
    STOCK_OPNAME_RECOUNT_NOT_ALLOWED: 'Produk ini tidak berada pada status hitung ulang.',
    FINAL_STOCK_OPNAME_IMMUTABLE: 'Stock Opname final tidak dapat dibatalkan.',
    MASTER_VERSION_CONFLICT: 'Sesi berubah di perangkat lain. Muat ulang sebelum melanjutkan.',
  }
  return Object.entries(known).find(([code]) => message.includes(code))?.[1] ?? message
}

function dateTime(value: string) {
  if (!value) return '-'
  return new Intl.DateTimeFormat('id-ID', {
    dateStyle: 'medium', timeStyle: 'short',
  }).format(new Date(value))
}

function statusLabel(status: string) {
  return ({
    DRAFT: 'Draft', COUNTING: 'Sedang dihitung', COMPLETED: 'Menunggu review',
    POSTED: 'Sudah diposting', CANCELED: 'Dibatalkan', PENDING: 'Belum dihitung',
    COUNTED: 'Tersimpan', RECOUNT_REQUIRED: 'Perlu hitung ulang', SKIPPED: 'Dilewati',
  } as Record<string, string>)[status] ?? status
}

function statusTone(status: string) {
  if (['COUNTED', 'POSTED'].includes(status)) return 'bg-emerald-100 text-emerald-800'
  if (['RECOUNT_REQUIRED'].includes(status)) return 'bg-amber-100 text-amber-900'
  if (['SKIPPED'].includes(status)) return 'bg-slate-200 text-slate-700'
  if (['CANCELED'].includes(status)) return 'bg-rose-100 text-rose-800'
  if (['COUNTING'].includes(status)) return 'bg-blue-100 text-blue-800'
  return 'bg-slate-100 text-slate-700'
}

function decimalPlaces(value: string) {
  const normalized = value.trim().replace(',', '.')
  return normalized.includes('.') ? normalized.split('.')[1]?.length ?? 0 : 0
}

export function StockOpnameModal({
  companyId, defaultWarehouseId, isOnline, close, completed,
}: {
  companyId: string
  defaultWarehouseId: string
  isOnline: boolean
  close: () => void
  completed: (message: string) => void
}) {
  const [workspace, setWorkspace] = useState<StockOpnameWorkspace | null>(null)
  const [active, setActive] = useState<StockOpnameBlindSession | null>(null)
  const [view, setView] = useState<'LIST' | 'FORM' | 'DETAIL' | 'REVIEW'>('LIST')
  const [form, setForm] = useState<FormState>(() => emptyForm(defaultWarehouseId))
  const [countDrafts, setCountDrafts] = useState<Record<string, CountDraft>>({})
  const [search, setSearch] = useState('')
  const [productSearch, setProductSearch] = useState('')
  const [busy, setBusy] = useState(true)
  const [lineBusy, setLineBusy] = useState('')
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const [partialConfirmed, setPartialConfirmed] = useState(false)

  const load = useCallback(async () => {
    setBusy(true); setError('')
    try {
      if (!companyId) throw new Error('ACTIVE_COMPANY_REQUIRED')
      const next = await loadStockOpnameWorkspace()
      setWorkspace(next)
      setForm((current) => ({
        ...current,
        warehouseId: current.warehouseId ||
          next.warehouses.find((row) => row.id === defaultWarehouseId)?.id ||
          next.warehouses[0]?.id || '',
      }))
    } catch (reason) {
      setError(friendly(reason instanceof Error ? reason.message : 'Stock Opname gagal dimuat.'))
    } finally { setBusy(false) }
  }, [companyId, defaultWarehouseId])

  useEffect(() => { void load() }, [load])
  useEffect(() => {
    const handler = (event: KeyboardEvent) => {
      if (event.key === 'Escape' && !busy && !lineBusy) close()
    }
    window.addEventListener('keydown', handler)
    return () => window.removeEventListener('keydown', handler)
  }, [busy, close, lineBusy])

  const productById = useMemo(() => new Map(
    (workspace?.products ?? []).map((product) => [product.id, product]),
  ), [workspace?.products])
  const activeSummary = workspace?.sessions.find((row) => row.id === active?.opnameId)
  const filteredProducts = useMemo(() => {
    const needle = productSearch.trim().toLowerCase()
    return (workspace?.products ?? []).filter((product) =>
      (!needle || `${product.sku} ${product.name} ${product.uomName}`.toLowerCase().includes(needle)),
    )
  }, [productSearch, workspace?.products])
  const filteredLines = useMemo(() => {
    const needle = search.trim().toLowerCase()
    return (active?.lines ?? []).filter((line) =>
      !needle || `${line.sku} ${line.productName} ${line.uomName}`.toLowerCase().includes(needle),
    )
  }, [active?.lines, search])
  const unresolved = (active?.lines ?? []).filter((line) =>
    ['PENDING', 'RECOUNT_REQUIRED'].includes(line.lineStatus),
  ).length
  const counted = (active?.lines ?? []).filter((line) => line.lineStatus === 'COUNTED').length
  const skipped = (active?.lines ?? []).filter((line) => line.lineStatus === 'SKIPPED').length

  function draftsFromSession(session: StockOpnameBlindSession) {
    return Object.fromEntries(session.lines
      .filter((line) => line.enteredQuantity !== null)
      .map((line) => [line.productId, {
        quantity: String(line.enteredQuantity), notes: line.notes ?? '',
      }]))
  }

  async function openSession(session: StockOpnameSessionSummary) {
    setBusy(true); setError(''); setNotice('')
    try {
      const next = await loadStockOpnameBlindSession(session.id)
      setActive(next)
      setCountDrafts(draftsFromSession(next)); setSearch(''); setView('DETAIL')
    } catch (reason) {
      setError(friendly(reason instanceof Error ? reason.message : 'Sesi gagal dibuka.'))
    } finally { setBusy(false) }
  }

  function createSession() {
    setForm(emptyForm(
      workspace?.warehouses.find((row) => row.id === defaultWarehouseId)?.id ||
      workspace?.warehouses[0]?.id || '',
    ))
    setProductSearch(''); setError(''); setNotice(''); setView('FORM')
  }

  async function editSession(session: StockOpnameSessionSummary) {
    setBusy(true); setError('')
    try {
      const blind = await loadStockOpnameBlindSession(session.id)
      setForm({
        opnameId: session.id,
        masterVersion: blind.masterVersion,
        warehouseId: session.warehouseId,
        scopeType: session.scopeType,
        categoryId: session.categoryId ?? '',
        selectedProductIds: session.scopeType === 'SELECTED'
          ? blind.lines.map((line) => line.productId) : [],
        notes: session.notes ?? '',
      })
      setProductSearch(''); setView('FORM')
    } catch (reason) {
      setError(friendly(reason instanceof Error ? reason.message : 'Draft gagal dimuat.'))
    } finally { setBusy(false) }
  }

  async function saveForm() {
    if (!isOnline) { setError('Stock Opname memerlukan koneksi online.'); return }
    if (!form.warehouseId) { setError('Pilih gudang Stock Opname.'); return }
    if (form.scopeType === 'CATEGORY' && !form.categoryId) {
      setError('Pilih kategori produk.'); return
    }
    if (form.scopeType === 'SELECTED' && form.selectedProductIds.length === 0) {
      setError('Pilih minimal satu produk.'); return
    }
    setBusy(true); setError(''); setNotice('')
    try {
      const result = await saveStockOpnameSession({
        opnameId: form.opnameId,
        masterVersion: form.masterVersion,
        warehouseId: form.warehouseId,
        scopeType: form.scopeType,
        categoryId: form.scopeType === 'CATEGORY' ? form.categoryId : null,
        productIds: form.scopeType === 'SELECTED' ? form.selectedProductIds : [],
        notes: form.notes,
      })
      const opnameId = String(result.opnameId)
      const next = await loadStockOpnameBlindSession(opnameId)
      setActive(next); setCountDrafts(draftsFromSession(next))
      await load()
      setNotice(`Draft ${String(result.opnameNo)} tersimpan dengan ${Number(result.lineCount)} produk.`)
      setView('DETAIL')
    } catch (reason) {
      setError(friendly(reason instanceof Error ? reason.message : 'Draft gagal disimpan.'))
    } finally { setBusy(false) }
  }

  async function start() {
    if (!active) return
    if (!isOnline) { setError('Stock Opname memerlukan koneksi online.'); return }
    setBusy(true); setError(''); setNotice('')
    try {
      await startStockOpname(active.opnameId, active.masterVersion)
      const next = await loadStockOpnameBlindSession(active.opnameId)
      setActive(next); setCountDrafts(draftsFromSession(next))
      await load()
      setNotice('Penghitungan dimulai. Angka stok sistem tetap disembunyikan.')
    } catch (reason) {
      setError(friendly(reason instanceof Error ? reason.message : 'Penghitungan gagal dimulai.'))
    } finally { setBusy(false) }
  }

  function updateDraft(productId: string, patch: Partial<CountDraft>) {
    setCountDrafts((current) => ({
      ...current,
      [productId]: { ...(current[productId] ?? { quantity: '', notes: '' }), ...patch },
    }))
  }

  async function record(line: StockOpnameBlindLine) {
    if (!active) return
    if (!isOnline) { setError('Stock Opname memerlukan koneksi online.'); return }
    const draft = countDrafts[line.productId] ?? { quantity: '', notes: '' }
    const normalized = draft.quantity.trim().replace(',', '.')
    const quantity = Number(normalized)
    const product = productById.get(line.productId)
    if (!normalized || !Number.isFinite(quantity) || quantity < 0) {
      setError('Isi jumlah fisik dengan angka nol atau lebih.'); return
    }
    if (product && !product.allowDecimal && !Number.isInteger(quantity)) {
      setError(`${product.uomName} hanya menerima bilangan bulat.`); return
    }
    if (product?.allowDecimal && decimalPlaces(draft.quantity) > product.decimalPrecision) {
      setError(`Maksimal ${product.decimalPrecision} angka di belakang koma.`); return
    }
    setLineBusy(line.productId); setError(''); setNotice('')
    try {
      const result = await recordStockOpnameCount({
        opnameId: active.opnameId,
        masterVersion: active.masterVersion,
        productId: line.productId,
        physicalQuantity: quantity,
        notes: draft.notes,
      })
      const nextStatus = String(result.lineStatus) as StockOpnameBlindLine['lineStatus']
      setActive((current) => current ? {
        ...current,
        masterVersion: Number(result.masterVersion),
        lines: current.lines.map((row) => row.productId === line.productId
          ? {
            ...row, lineStatus: nextStatus, notes: draft.notes || null,
            enteredQuantity: nextStatus === 'COUNTED' ? quantity : null,
          } : row),
      } : current)
      setCountDrafts((current) => ({
        ...current,
        [line.productId]: nextStatus === 'COUNTED'
          ? { quantity: String(quantity), notes: draft.notes }
          : { quantity: '', notes: '' },
      }))
      setNotice(nextStatus === 'RECOUNT_REQUIRED'
        ? `${line.productName} perlu dihitung ulang karena ada pergerakan stok.`
        : `${line.productName} berhasil disimpan.`)
    } catch (reason) {
      setError(friendly(reason instanceof Error ? reason.message : 'Hitungan gagal disimpan.'))
      if (reason instanceof Error && reason.message.includes('MASTER_VERSION_CONFLICT')) {
        const next = await loadStockOpnameBlindSession(active.opnameId)
        setActive(next); setCountDrafts(draftsFromSession(next))
      }
    } finally { setLineBusy('') }
  }

  async function prepareRecount(line: StockOpnameBlindLine) {
    if (!active) return
    if (!isOnline) { setError('Stock Opname memerlukan koneksi online.'); return }
    setLineBusy(line.productId); setError(''); setNotice('')
    try {
      const result = await requestStockOpnameRecount(
        active.opnameId, active.masterVersion, line.detailId,
      )
      setActive((current) => current ? {
        ...current,
        masterVersion: Number(result.masterVersion),
        lines: current.lines.map((row) => row.productId === line.productId
          ? { ...row, lineStatus: 'PENDING', enteredQuantity: null } : row),
      } : current)
      setCountDrafts((current) => ({
        ...current, [line.productId]: { quantity: '', notes: '' },
      }))
      setNotice(`Jendela hitung ulang ${line.productName} sudah dibuka.`)
    } catch (reason) {
      setError(friendly(reason instanceof Error ? reason.message : 'Hitung ulang gagal dimulai.'))
    } finally { setLineBusy('') }
  }

  function review() {
    if (!active || counted === 0) return
    setPartialConfirmed(false); setError(''); setNotice(''); setView('REVIEW')
  }

  async function finish() {
    if (!active) return
    if (unresolved > 0 && !partialConfirmed) {
      setError('Konfirmasi dahulu bahwa produk yang belum dihitung akan dilewati.')
      return
    }
    if (!isOnline) { setError('Stock Opname memerlukan koneksi online.'); return }
    setBusy(true); setError('')
    try {
      const result = await completeStockOpname(
        active.opnameId, active.masterVersion, unresolved > 0,
      )
      const skippedCount = Number(result.skippedLineCount ?? 0)
      completed(`${active.opnameNo} dikirim: ${counted} produk dihitung${
        skippedCount ? `, ${skippedCount} dilewati` : ''}. Menunggu review Backoffice.`)
    } catch (reason) {
      setError(friendly(reason instanceof Error ? reason.message : 'Stock Opname gagal diselesaikan.'))
      setBusy(false)
    }
  }

  async function cancel() {
    if (!active || !window.confirm(`Batalkan ${active.opnameNo}? Histori tetap tersimpan.`)) return
    if (!isOnline) { setError('Stock Opname memerlukan koneksi online.'); return }
    setBusy(true); setError('')
    try {
      await cancelStockOpname(active.opnameId, active.masterVersion)
      setActive(null); setView('LIST'); await load()
      setNotice('Sesi Stock Opname dibatalkan.')
    } catch (reason) {
      setError(friendly(reason instanceof Error ? reason.message : 'Stock Opname gagal dibatalkan.'))
    } finally { setBusy(false) }
  }

  return (
    <div className="fixed inset-0 z-[70] bg-black/65 p-2 sm:p-5">
      <section className="mx-auto flex h-full w-full max-w-6xl flex-col overflow-hidden rounded-3xl bg-white shadow-2xl">
        <header className="flex items-start justify-between gap-4 border-b border-slate-200 px-5 py-4 sm:px-7">
          <div>
            <p className="text-xs font-black uppercase tracking-[0.16em] text-emerald-700">Blind count online</p>
            <h2 className="mt-1 text-2xl font-black text-slate-950">Stock Opname</h2>
            <p className="mt-1 text-sm text-slate-500">Hitung fisik tanpa melihat stok sistem atau selisih.</p>
          </div>
          <button type="button" onClick={close} disabled={busy || Boolean(lineBusy)} className="rounded-xl border border-slate-200 p-3 text-slate-600 disabled:opacity-40" aria-label="Tutup Stock Opname"><X className="h-5 w-5" /></button>
        </header>

        <div className="flex-1 overflow-y-auto px-4 py-5 sm:px-7">
          {!isOnline && <div className="mb-4 flex items-start gap-2 rounded-xl bg-amber-50 p-4 text-sm font-semibold text-amber-900"><AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />Koneksi terputus. Stock Opname tidak disimpan ke antrean offline; sambungkan kembali sebelum melanjutkan.</div>}
          {error && <div className="mb-4 flex items-start gap-2 rounded-xl bg-rose-50 p-4 text-sm font-semibold text-rose-700"><AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />{error}</div>}
          {notice && <div className="mb-4 flex items-start gap-2 rounded-xl bg-emerald-50 p-4 text-sm font-semibold text-emerald-800"><CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0" />{notice}</div>}
          {busy && !workspace ? <div className="grid min-h-64 place-items-center text-slate-500"><Loader2 className="h-7 w-7 animate-spin" /></div> : null}

          {workspace && view === 'LIST' && <>
            <div className="flex flex-wrap items-center justify-between gap-3">
              <div><h3 className="text-lg font-black">Sesi hitung saya</h3><p className="text-sm text-slate-500">Lanjutkan sesi yang tertunda atau buat hitungan baru.</p></div>
              <div className="flex gap-2"><button type="button" onClick={() => void load()} disabled={busy} className="inline-flex items-center gap-2 rounded-xl border border-slate-300 px-4 py-3 text-sm font-bold"><RefreshCw className={`h-4 w-4 ${busy ? 'animate-spin' : ''}`} />Muat ulang</button><button type="button" onClick={createSession} disabled={busy} className="inline-flex items-center gap-2 rounded-xl bg-emerald-600 px-4 py-3 text-sm font-black text-white"><Plus className="h-4 w-4" />Buat Opname</button></div>
            </div>
            <div className="mt-5 grid gap-3 lg:grid-cols-2">
              {workspace.sessions.map((session) => <article key={session.id} className="rounded-2xl border border-slate-200 p-4">
                <div className="flex items-start justify-between gap-3"><div><h4 className="font-black text-slate-950">{session.opnameNo}</h4><p className="mt-1 text-sm text-slate-500">{session.warehouseName} · {dateTime(session.createdAt)}</p></div><span className={`rounded-full px-3 py-1 text-xs font-black ${statusTone(session.status)}`}>{statusLabel(session.status)}</span></div>
                <div className="mt-4 grid grid-cols-2 gap-2 text-center text-xs sm:grid-cols-4"><div className="rounded-xl bg-slate-50 p-2"><strong className="block text-base text-slate-900">{session.lineCount}</strong>Produk</div><div className="rounded-xl bg-emerald-50 p-2"><strong className="block text-base text-emerald-800">{session.countedCount}</strong>Dihitung</div><div className="rounded-xl bg-amber-50 p-2"><strong className="block text-base text-amber-800">{session.pendingCount + session.recountRequiredCount}</strong>Belum dihitung</div><div className="rounded-xl bg-slate-100 p-2"><strong className="block text-base text-slate-700">{session.skippedCount}</strong>Dilewati</div></div>
                <div className="mt-4 flex flex-wrap gap-2"><button type="button" onClick={() => void openSession(session)} disabled={busy} className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-black text-white">{['DRAFT', 'COUNTING'].includes(session.status) ? 'Lanjutkan' : 'Lihat status'}</button>{session.status === 'DRAFT' && <button type="button" onClick={() => void editSession(session)} disabled={busy} className="inline-flex items-center gap-2 rounded-xl border border-slate-300 px-4 py-2 text-sm font-bold"><Pencil className="h-4 w-4" />Ubah</button>}</div>
              </article>)}
              {!workspace.sessions.length && <div className="col-span-full rounded-2xl border border-dashed border-slate-300 p-10 text-center text-slate-500"><ClipboardCheck className="mx-auto mb-3 h-8 w-8" />Belum ada sesi Stock Opname milik Anda.</div>}
            </div>
          </>}

          {workspace && view === 'FORM' && <div className="mx-auto max-w-4xl">
            <button type="button" onClick={() => setView('LIST')} disabled={busy} className="mb-4 text-sm font-bold text-slate-600">← Kembali ke daftar</button>
            <h3 className="text-xl font-black">{form.opnameId ? 'Ubah Draft Opname' : 'Buat Stock Opname'}</h3>
            <div className="mt-5 grid gap-4 sm:grid-cols-2">
              <label className="text-sm font-bold">Gudang<select value={form.warehouseId} onChange={(event) => setForm((current) => ({ ...current, warehouseId: event.target.value }))} className="mt-2 w-full rounded-xl border border-slate-300 bg-white p-3 font-normal">{workspace.warehouses.map((row) => <option key={row.id} value={row.id}>{row.name}</option>)}</select></label>
              <label className="text-sm font-bold">Cakupan<select value={form.scopeType} onChange={(event) => setForm((current) => ({ ...current, scopeType: event.target.value as FormState['scopeType'], categoryId: '', selectedProductIds: [] }))} className="mt-2 w-full rounded-xl border border-slate-300 bg-white p-3 font-normal"><option value="ALL">Semua produk aktif</option><option value="CATEGORY">Satu kategori</option><option value="SELECTED">Produk tertentu</option></select></label>
            </div>
            {form.scopeType === 'CATEGORY' && <label className="mt-4 block text-sm font-bold">Kategori<select value={form.categoryId} onChange={(event) => setForm((current) => ({ ...current, categoryId: event.target.value }))} className="mt-2 w-full rounded-xl border border-slate-300 bg-white p-3 font-normal"><option value="">Pilih kategori</option>{workspace.categories.map((row) => <option key={row.id} value={row.id}>{row.name}</option>)}</select></label>}
            {form.scopeType === 'SELECTED' && <div className="mt-4 rounded-2xl border border-slate-200 p-4"><label className="relative block"><Search className="absolute left-3 top-3.5 h-4 w-4 text-slate-400" /><input value={productSearch} onChange={(event) => setProductSearch(event.target.value)} className="w-full rounded-xl border border-slate-300 py-3 pl-10 pr-3 text-sm" placeholder="Cari nama atau SKU produk" /></label><p className="mt-3 text-xs font-bold text-slate-500">{form.selectedProductIds.length} produk dipilih</p><div className="mt-3 max-h-72 space-y-2 overflow-y-auto">{filteredProducts.map((product) => { const checked = form.selectedProductIds.includes(product.id); return <label key={product.id} className={`flex cursor-pointer items-center gap-3 rounded-xl border p-3 ${checked ? 'border-emerald-300 bg-emerald-50' : 'border-slate-200'}`}><input type="checkbox" checked={checked} onChange={() => setForm((current) => ({ ...current, selectedProductIds: checked ? current.selectedProductIds.filter((id) => id !== product.id) : [...current.selectedProductIds, product.id] }))} className="h-4 w-4 accent-emerald-600" /><span><strong className="block text-sm">{product.name}</strong><span className="text-xs text-slate-500">{product.sku} · {product.uomName}</span></span></label>})}</div></div>}
            <label className="mt-4 block text-sm font-bold">Catatan (opsional)<textarea value={form.notes} onChange={(event) => setForm((current) => ({ ...current, notes: event.target.value }))} className="mt-2 min-h-24 w-full rounded-xl border border-slate-300 p-3 font-normal" placeholder="Contoh: opname akhir shift" /></label>
            <div className="mt-5 flex justify-end"><button type="button" onClick={() => void saveForm()} disabled={busy} className="inline-flex items-center gap-2 rounded-xl bg-emerald-600 px-5 py-3 font-black text-white disabled:opacity-50">{busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <Save className="h-4 w-4" />}Simpan Draft</button></div>
          </div>}

          {active && view === 'DETAIL' && <div>
            <button type="button" onClick={() => { setActive(null); setView('LIST'); setError(''); setNotice(''); void load() }} disabled={busy || Boolean(lineBusy)} className="mb-4 text-sm font-bold text-slate-600">← Kembali ke daftar</button>
            <div className="flex flex-wrap items-start justify-between gap-3"><div><h3 className="text-xl font-black">{active.opnameNo}</h3><p className="mt-1 text-sm text-slate-500">{activeSummary?.warehouseName ?? 'Gudang'} · {active.lines.length} produk</p></div><span className={`rounded-full px-3 py-1 text-xs font-black ${statusTone(active.status)}`}>{statusLabel(active.status)}</span></div>
            <div className="mt-4 grid grid-cols-2 gap-3 sm:grid-cols-4"><div className="rounded-xl bg-slate-50 p-3 text-sm"><strong className="block text-xl">{active.lines.length}</strong>Total produk</div><div className="rounded-xl bg-emerald-50 p-3 text-sm text-emerald-900"><strong className="block text-xl">{counted}</strong>Dihitung</div><div className="rounded-xl bg-amber-50 p-3 text-sm text-amber-900"><strong className="block text-xl">{unresolved}</strong>Belum dihitung</div><div className="rounded-xl bg-slate-100 p-3 text-sm text-slate-700"><strong className="block text-xl">{skipped}</strong>Dilewati</div></div>
            {active.status === 'DRAFT' && <div className="mt-5 rounded-2xl border border-blue-200 bg-blue-50 p-5"><h4 className="font-black text-blue-950">Draft siap dimulai</h4><p className="mt-1 text-sm text-blue-800">Setelah dimulai, cakupan produk dikunci dan angka stok sistem tetap tersembunyi.</p><div className="mt-4 flex flex-wrap gap-2"><button type="button" onClick={() => activeSummary && void editSession(activeSummary)} disabled={busy} className="inline-flex items-center gap-2 rounded-xl border border-blue-300 bg-white px-4 py-2 text-sm font-bold text-blue-900"><Pencil className="h-4 w-4" />Ubah cakupan</button><button type="button" onClick={() => void start()} disabled={busy} className="inline-flex items-center gap-2 rounded-xl bg-blue-700 px-4 py-2 text-sm font-black text-white"><Play className="h-4 w-4" />Mulai hitung</button><button type="button" onClick={() => void cancel()} disabled={busy} className="inline-flex items-center gap-2 rounded-xl border border-rose-300 px-4 py-2 text-sm font-bold text-rose-700"><XCircle className="h-4 w-4" />Batalkan</button></div></div>}
            {active.status === 'COUNTING' && <>
              <label className="relative mt-5 block"><Search className="absolute left-3 top-3.5 h-4 w-4 text-slate-400" /><input value={search} onChange={(event) => setSearch(event.target.value)} className="w-full rounded-xl border border-slate-300 py-3 pl-10 pr-3 text-sm" placeholder="Cari produk, SKU, atau satuan" /></label>
              <p className="mt-3 rounded-xl bg-blue-50 p-3 text-sm font-semibold text-blue-800">Jumlah yang sudah tersimpan tetap terlihat oleh Anda dan dapat diperbarui selama sesi masih dihitung. Angka stok sistem dan selisih tetap disembunyikan.</p>
              <div className="mt-4 space-y-3">{filteredLines.map((line) => { const draft = countDrafts[line.productId] ?? { quantity: '', notes: '' }; const waiting = lineBusy === line.productId; return <article key={line.detailId} className={`rounded-2xl border p-4 ${line.lineStatus === 'RECOUNT_REQUIRED' ? 'border-amber-300 bg-amber-50' : 'border-slate-200'}`}><div className="flex flex-wrap items-start justify-between gap-3"><div><h4 className="font-black">{line.productName}</h4><p className="mt-1 text-xs text-slate-500">{line.sku} · {line.uomName}</p></div><span className={`rounded-full px-3 py-1 text-xs font-black ${statusTone(line.lineStatus)}`}>{statusLabel(line.lineStatus)}</span></div>{line.lineStatus === 'RECOUNT_REQUIRED' ? <div className="mt-4"><p className="text-sm font-semibold text-amber-900">Ada pergerakan stok pada jendela hitung. Buka jendela baru sebelum menghitung kembali.</p><button type="button" onClick={() => void prepareRecount(line)} disabled={Boolean(lineBusy)} className="mt-3 inline-flex items-center gap-2 rounded-xl bg-amber-700 px-4 py-2 text-sm font-black text-white disabled:opacity-50">{waiting ? <Loader2 className="h-4 w-4 animate-spin" /> : <RotateCcw className="h-4 w-4" />}Mulai hitung ulang</button></div> : <div className="mt-4 grid gap-3 lg:grid-cols-[minmax(180px,0.45fr)_1fr_auto]"><label className="text-xs font-bold text-slate-600">Jumlah fisik ({line.uomName})<input type="text" inputMode="decimal" value={draft.quantity} onChange={(event) => updateDraft(line.productId, { quantity: event.target.value })} className="mt-1 w-full rounded-xl border border-slate-300 bg-white p-3 text-base font-black text-slate-950" placeholder="0" /></label><label className="text-xs font-bold text-slate-600">Catatan (opsional)<input value={draft.notes} onChange={(event) => updateDraft(line.productId, { notes: event.target.value })} className="mt-1 w-full rounded-xl border border-slate-300 bg-white p-3 text-sm font-normal text-slate-950" placeholder="Kondisi atau lokasi hitung" /></label><button type="button" onClick={() => void record(line)} disabled={Boolean(lineBusy)} className="self-end rounded-xl bg-emerald-600 px-5 py-3 text-sm font-black text-white disabled:opacity-50">{waiting ? 'Menyimpan...' : line.lineStatus === 'COUNTED' ? 'Perbarui' : 'Simpan'}</button></div>}</article>})}</div>
              <div className="mt-5 flex flex-wrap justify-between gap-3 border-t border-slate-200 pt-5"><button type="button" onClick={() => void cancel()} disabled={busy || Boolean(lineBusy)} className="rounded-xl border border-rose-300 px-4 py-3 text-sm font-bold text-rose-700">Batalkan sesi</button><button type="button" onClick={review} disabled={busy || Boolean(lineBusy) || counted === 0} className="rounded-xl bg-emerald-700 px-5 py-3 font-black text-white disabled:cursor-not-allowed disabled:opacity-40">Review hasil ({counted})</button></div>
            </>}
            {active.status === 'COMPLETED' && <div className="mt-5 rounded-2xl border border-emerald-200 bg-emerald-50 p-6"><CheckCircle2 className="h-8 w-8 text-emerald-700" /><h4 className="mt-3 text-lg font-black text-emerald-950">Menunggu review Backoffice</h4><p className="mt-1 text-sm text-emerald-800">Manager dapat meminta hitung ulang atau melakukan posting. Selisih tetap tidak ditampilkan di POS.</p><button type="button" onClick={() => void cancel()} disabled={busy} className="mt-4 rounded-xl border border-rose-300 bg-white px-4 py-2 text-sm font-bold text-rose-700">Batalkan sesi</button></div>}
            {['POSTED', 'CANCELED'].includes(active.status) && <div className="mt-5 rounded-2xl bg-slate-50 p-6 text-sm text-slate-600">Sesi ini sudah final. Detail selisih dan dokumen Adjustment tersedia sesuai kewenangan di Backoffice.</div>}
          </div>}

          {active && view === 'REVIEW' && <div className="mx-auto max-w-4xl">
            <button type="button" onClick={() => { setView('DETAIL'); setError('') }} disabled={busy} className="mb-4 inline-flex items-center gap-2 text-sm font-bold text-slate-600"><ArrowLeft className="h-4 w-4" />Kembali mengedit hitungan</button>
            <h3 className="text-xl font-black">Review hasil {active.opnameNo}</h3>
            <p className="mt-2 text-sm text-slate-600">Periksa kembali jumlah yang Anda masukkan. Nilai nol berarti fisik memang kosong; produk yang tidak diisi akan dilewati dan tidak mengubah stok.</p>
            <div className="mt-5 space-y-2">
              {active.lines.filter((line) => line.lineStatus === 'COUNTED').map((line) => <div key={line.detailId} className="flex items-center justify-between gap-4 rounded-xl border border-emerald-200 bg-emerald-50 p-4"><div><p className="font-black text-slate-900">{line.productName}</p><p className="mt-1 text-xs text-slate-500">{line.sku} - {line.notes || 'Tanpa catatan'}</p></div><strong className="shrink-0 text-lg text-emerald-800">{line.enteredQuantity} {line.uomName}</strong></div>)}
            </div>
            {unresolved > 0 && <div className="mt-5 rounded-2xl border border-amber-300 bg-amber-50 p-5"><h4 className="font-black text-amber-950">{unresolved} produk akan dilewati</h4><p className="mt-1 text-sm text-amber-900">Produk berstatus belum dihitung atau perlu hitung ulang tidak dianggap nol dan tidak ikut Adjustment. Produk tersebut dapat dimasukkan pada sesi Opname baru.</p><ul className="mt-3 max-h-44 space-y-1 overflow-y-auto text-sm text-amber-950">{active.lines.filter((line) => ['PENDING', 'RECOUNT_REQUIRED'].includes(line.lineStatus)).map((line) => <li key={line.detailId} className="flex items-start gap-2"><span aria-hidden="true" className="mt-2 h-1.5 w-1.5 shrink-0 rounded-full bg-amber-700" /><span>{line.productName} ({line.sku})</span></li>)}</ul><label className="mt-4 flex items-start gap-3 rounded-xl border border-amber-300 bg-white p-4"><input type="checkbox" checked={partialConfirmed} onChange={(event) => setPartialConfirmed(event.target.checked)} className="mt-1 h-4 w-4 accent-emerald-600" /><span className="text-sm font-semibold text-slate-700">Saya memahami produk tersebut belum menjadi hasil hitung dan akan ditandai Dilewati.</span></label></div>}
            <div className="mt-6 flex flex-wrap justify-between gap-3 border-t border-slate-200 pt-5"><button type="button" onClick={() => setView('DETAIL')} disabled={busy} className="rounded-xl border border-slate-300 px-4 py-3 text-sm font-bold">Perbaiki hitungan</button><button type="button" onClick={() => void finish()} disabled={busy || counted === 0 || (unresolved > 0 && !partialConfirmed)} className="rounded-xl bg-emerald-700 px-5 py-3 font-black text-white disabled:cursor-not-allowed disabled:opacity-40">{busy ? 'Mengirim...' : `Kirim ${counted} hasil hitung`}</button></div>
          </div>}
        </div>
      </section>
    </div>
  )
}
