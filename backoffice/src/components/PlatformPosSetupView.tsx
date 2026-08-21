'use client'

import { useCallback, useEffect, useMemo, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import { CircleAlert, Loader2, MonitorSmartphone, Pencil, Plus, RefreshCcw, Store, X } from 'lucide-react'
import { useEscapeClose } from '@/lib/use-escape-close'

type StoreRow = { id: string; code: string; name: string; address: string | null; timezone: string; status: string; masterVersion: number; activeTerminalCount: number; openSessionCount: number }
type TerminalRow = { id: string; storeId: string; code: string; name: string; deviceIdentifier: string | null; status: string; masterVersion: number; hiddenFeatureKeys: string[]; openSessionCount: number }
type WarehouseRow = { id: string; name: string; storeId: string | null; isSaleSource: boolean; isActive: boolean }
type Setup = { companyId: string; stores: StoreRow[]; terminals: TerminalRow[]; warehouses: WarehouseRow[] }
type Editor = { type: 'STORE' | 'TERMINAL'; row?: StoreRow | TerminalRow }

function authHeaders(session: Session) { return { Authorization: `Bearer ${session.access_token}`, 'Content-Type': 'application/json' } }
function count(value: number) { return Number(value ?? 0).toLocaleString('id-ID') }

function friendlyError(code?: string) {
  const messages: Record<string, string> = {
    PLATFORM_POS_MANAGEMENT_ACCESS_DENIED: 'Hanya Super Admin atau Owner/Admin Company yang dapat mengelola Toko dan Terminal.',
    ACTIVE_COMPANY_CONTEXT_MISMATCH: 'Company aktif berubah. Muat ulang halaman lalu coba kembali.',
    ACTIVE_STORE_NOT_FOUND: 'Toko tujuan tidak aktif atau tidak ditemukan.',
    DUPLICATE_STORE_CODE: 'Kode Toko sudah dipakai pada Company ini.',
    DUPLICATE_POS_CODE: 'Kode Terminal sudah dipakai pada Toko ini.',
    STORE_CODE_IMMUTABLE: 'Kode Toko tidak dapat diubah setelah dibuat.',
    POS_CODE_IMMUTABLE: 'Kode Terminal tidak dapat diubah setelah dibuat.',
    MASTER_VERSION_CONFLICT: 'Data berubah di sesi lain. Muat ulang sebelum menyimpan kembali.',
    TERMINAL_HAS_OPEN_SESSION: 'Terminal masih memiliki sesi kasir terbuka.',
    TERMINAL_STORE_LOCKED_BY_HISTORY: 'Terminal yang sudah memiliki riwayat sesi tidak dapat dipindah ke Toko lain.',
    STORE_HAS_ACTIVE_OPERATIONAL_DEPENDENCY: 'Nonaktifkan Terminal, sesi kasir, dan Gudang aktif pada Toko ini terlebih dahulu.',
  }
  return messages[code ?? ''] ?? code ?? 'Operasi Toko/Terminal gagal.'
}

export function PlatformPosSetupView({ session, companyId, companyName, notify }: { session: Session; companyId: string; companyName: string; notify: (message: string | null) => void }) {
  const [data, setData] = useState<Setup | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [tab, setTab] = useState<'STORE' | 'TERMINAL'>('STORE')
  const [editor, setEditor] = useState<Editor | null>(null)

  const refresh = useCallback(async () => {
    setLoading(true); setError('')
    try {
      const response = await fetch('/api/platform/pos-setup', { headers: authHeaders(session), cache: 'no-store' })
      const payload = await response.json() as { data?: Setup; error?: string }
      if (!response.ok) throw new Error(friendlyError(payload.error))
      if (!payload.data || payload.data.companyId !== companyId) throw new Error('Data tidak cocok dengan Company aktif.')
      setData(payload.data)
    } catch (caught) { setError(caught instanceof Error ? caught.message : 'Gagal memuat Toko dan Terminal.') }
    finally { setLoading(false) }
  }, [companyId, session])

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- the workspace follows the active Company context
    void refresh()
  }, [refresh])
  const storeNames = useMemo(() => new Map((data?.stores ?? []).map((row) => [row.id, row.name])), [data])

  return <>
    <div className="mb-7 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
      <div><p className="text-xs font-bold uppercase tracking-[.16em] text-emerald-600">Platform · Point of Sales</p><h1 className="mt-2 text-2xl font-black text-slate-950 md:text-3xl">Toko & Terminal POS</h1><p className="mt-2 text-sm text-slate-500">Kelola lokasi dan perangkat kasir untuk {companyName}.</p></div>
      <button onClick={() => setEditor({ type: tab })} disabled={tab === 'TERMINAL' && !(data?.stores.some((row) => row.status === 'ACTIVE'))} className="inline-flex items-center justify-center gap-2 rounded-xl bg-emerald-500 px-4 py-3 text-sm font-bold text-white disabled:cursor-not-allowed disabled:opacity-50"><Plus className="h-4 w-4" />{tab === 'STORE' ? 'Toko baru' : 'Terminal baru'}</button>
    </div>

    <div className="mb-5 flex gap-2 rounded-2xl border border-slate-200 bg-white p-2 shadow-sm">
      {(['STORE', 'TERMINAL'] as const).map((value) => <button key={value} onClick={() => setTab(value)} className={`flex-1 rounded-xl px-4 py-3 text-sm font-bold ${tab === value ? 'bg-slate-950 text-white' : 'text-slate-500 hover:bg-slate-50'}`}>{value === 'STORE' ? 'Toko' : 'Terminal POS'}</button>)}
      <button onClick={() => void refresh()} className="rounded-xl border border-slate-200 p-3 text-slate-500" aria-label="Muat ulang"><RefreshCcw className={`h-4 w-4 ${loading ? 'animate-spin' : ''}`} /></button>
    </div>

    {error && <div className="mb-5 rounded-2xl border border-red-200 bg-red-50 p-4 text-sm font-semibold text-red-700">{error}</div>}
    {loading ? <div className="grid min-h-56 place-items-center rounded-2xl border border-slate-200 bg-white"><Loader2 className="h-6 w-6 animate-spin text-emerald-500" /></div> : tab === 'STORE' ? (
      <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">{data?.stores.map((row) => {
        const saleWarehouses = data.warehouses.filter((warehouse) => warehouse.isActive && warehouse.isSaleSource && (warehouse.storeId === row.id || warehouse.storeId === null)).length
        return <article key={row.id} className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm"><div className="flex items-start justify-between gap-3"><div className="grid h-11 w-11 place-items-center rounded-xl bg-emerald-50 text-emerald-700"><Store className="h-5 w-5" /></div><button onClick={() => setEditor({ type: 'STORE', row })} className="rounded-lg border border-slate-200 p-2 text-slate-500"><Pencil className="h-4 w-4" /></button></div><h2 className="mt-4 font-black text-slate-950">{row.name}</h2><p className="mt-1 text-xs font-bold text-slate-400">{row.code} · {row.timezone}</p><p className="mt-3 min-h-10 text-sm text-slate-500">{row.address || 'Alamat belum diisi'}</p><div className="mt-4 grid grid-cols-3 gap-2 text-center"><Metric label="Terminal" value={row.activeTerminalCount} /><Metric label="Gudang jual" value={saleWarehouses} /><Metric label="Sesi buka" value={row.openSessionCount} /></div>{saleWarehouses === 0 && <p className="mt-3 flex gap-2 rounded-xl bg-amber-50 p-3 text-xs font-semibold text-amber-700"><CircleAlert className="h-4 w-4 shrink-0" />Atur Gudang aktif sebagai sumber penjualan sebelum POS dipakai.</p>}<Status value={row.status} /></article>
      })}{!data?.stores.length && <Empty label="Belum ada Toko pada Company ini." />}</div>
    ) : (
      <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">{data?.terminals.map((row) => <article key={row.id} className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm"><div className="flex items-start justify-between gap-3"><div className="grid h-11 w-11 place-items-center rounded-xl bg-blue-50 text-blue-700"><MonitorSmartphone className="h-5 w-5" /></div><button onClick={() => setEditor({ type: 'TERMINAL', row })} className="rounded-lg border border-slate-200 p-2 text-slate-500"><Pencil className="h-4 w-4" /></button></div><h2 className="mt-4 font-black text-slate-950">{row.name}</h2><p className="mt-1 text-xs font-bold text-slate-400">{row.code} · {storeNames.get(row.storeId) ?? 'Toko tidak ditemukan'}</p><p className="mt-3 text-sm text-slate-500">Perangkat: {row.deviceIdentifier || 'Tidak dikunci'}</p><p className="mt-2 text-xs font-semibold text-slate-500">{count(row.openSessionCount)} sesi sedang terbuka · {row.hiddenFeatureKeys.length} fitur disembunyikan</p><Status value={row.status} /></article>)}{!data?.terminals.length && <Empty label="Belum ada Terminal POS pada Company ini." />}</div>
    )}
    {editor && data && <SetupModal editor={editor} stores={data.stores} session={session} close={() => setEditor(null)} saved={async (message) => { setEditor(null); notify(message); await refresh() }} />}
  </>
}

function Metric({ label, value }: { label: string; value: number }) { return <div className="rounded-xl bg-slate-50 px-2 py-3"><p className="text-lg font-black text-slate-900">{count(value)}</p><p className="mt-1 text-[10px] font-bold uppercase text-slate-400">{label}</p></div> }
function Status({ value }: { value: string }) { return <span className={`mt-4 inline-flex rounded-full px-2.5 py-1 text-[11px] font-bold ${value === 'ACTIVE' ? 'bg-emerald-50 text-emerald-700' : 'bg-slate-100 text-slate-500'}`}>{value === 'ACTIVE' ? 'Aktif' : 'Nonaktif'}</span> }
function Empty({ label }: { label: string }) { return <div className="md:col-span-2 xl:col-span-3 rounded-2xl border border-dashed border-slate-300 bg-white p-12 text-center text-sm font-semibold text-slate-500">{label}</div> }

function SetupModal({ editor, stores, session, close, saved }: { editor: Editor; stores: StoreRow[]; session: Session; close: () => void; saved: (message: string) => Promise<void> }) {
  const row = editor.row
  const isStore = editor.type === 'STORE'
  const [code, setCode] = useState(row?.code ?? '')
  const [name, setName] = useState(row?.name ?? '')
  const [status, setStatus] = useState(row?.status ?? 'ACTIVE')
  const [address, setAddress] = useState(isStore ? (row as StoreRow | undefined)?.address ?? '' : '')
  const [timezone, setTimezone] = useState(isStore ? (row as StoreRow | undefined)?.timezone ?? 'Asia/Jakarta' : 'Asia/Jakarta')
  const [storeId, setStoreId] = useState(!isStore ? (row as TerminalRow | undefined)?.storeId ?? stores.find((item) => item.status === 'ACTIVE')?.id ?? '' : '')
  const [deviceIdentifier, setDeviceIdentifier] = useState(!isStore ? (row as TerminalRow | undefined)?.deviceIdentifier ?? '' : '')
  const [busy, setBusy] = useState(false); const [error, setError] = useState('')
  useEscapeClose(() => { if (!busy) close() })

  async function submit(event: React.FormEvent) {
    event.preventDefault(); setBusy(true); setError('')
    try {
      const response = await fetch('/api/platform/pos-setup', { method: 'POST', headers: authHeaders(session), body: JSON.stringify({ entityType: editor.type, id: row?.id, masterVersion: row?.masterVersion, code, name, status, address, timezone, storeId, deviceIdentifier }) })
      const payload = await response.json() as { error?: string }
      if (!response.ok) throw new Error(friendlyError(payload.error))
      await saved(`${isStore ? 'Toko' : 'Terminal POS'} berhasil disimpan.`)
    } catch (caught) { setError(caught instanceof Error ? caught.message : 'Gagal menyimpan.') }
    finally { setBusy(false) }
  }

  return <div className="fixed inset-0 z-[70] grid place-items-center overflow-y-auto bg-slate-950/55 p-4" role="dialog" aria-modal="true"><form onSubmit={submit} className="my-auto w-full max-w-xl rounded-3xl border border-slate-200 bg-white shadow-2xl"><div className="flex items-start justify-between border-b border-slate-200 p-6"><div><p className="text-xs font-bold uppercase tracking-wider text-emerald-600">Point of Sales</p><h2 className="mt-2 text-xl font-black">{row ? 'Edit' : 'Tambah'} {isStore ? 'Toko' : 'Terminal POS'}</h2></div><button type="button" onClick={close} disabled={busy} className="rounded-xl border border-slate-200 p-2"><X className="h-5 w-5" /></button></div><div className="grid gap-4 p-6 sm:grid-cols-2"><Field label={isStore ? 'Kode Toko' : 'Kode Terminal'} value={code} setValue={setCode} disabled={Boolean(row)} /><Field label={isStore ? 'Nama Toko' : 'Nama Terminal'} value={name} setValue={setName} />{isStore ? <><Field label="Zona waktu" value={timezone} setValue={setTimezone} /><label className="sm:col-span-2 text-sm font-bold text-slate-700">Alamat<textarea value={address} onChange={(event) => setAddress(event.target.value)} rows={3} className="mt-2 w-full rounded-xl border border-slate-200 px-3 py-2.5 font-normal outline-none focus:border-emerald-500" /></label></> : <><label className="text-sm font-bold text-slate-700">Toko<select value={storeId} onChange={(event) => setStoreId(event.target.value)} className="mt-2 w-full rounded-xl border border-slate-200 bg-white px-3 py-2.5 font-normal"><option value="">Pilih Toko</option>{stores.filter((item) => item.status === 'ACTIVE').map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}</select></label><Field label="ID perangkat (opsional)" value={deviceIdentifier} setValue={setDeviceIdentifier} /></>}<label className="text-sm font-bold text-slate-700">Status<select value={status} onChange={(event) => setStatus(event.target.value)} className="mt-2 w-full rounded-xl border border-slate-200 bg-white px-3 py-2.5 font-normal"><option value="ACTIVE">Aktif</option><option value="INACTIVE">Nonaktif</option></select></label>{error && <p className="sm:col-span-2 rounded-xl bg-red-50 p-3 text-sm font-semibold text-red-700">{error}</p>}</div><div className="flex justify-end gap-3 border-t border-slate-200 p-6"><button type="button" onClick={close} disabled={busy} className="rounded-xl border border-slate-200 px-4 py-2.5 text-sm font-bold">Batal</button><button disabled={busy || !code.trim() || !name.trim() || (!isStore && !storeId)} className="inline-flex items-center gap-2 rounded-xl bg-emerald-500 px-5 py-2.5 text-sm font-bold text-white disabled:opacity-50">{busy && <Loader2 className="h-4 w-4 animate-spin" />}Simpan</button></div></form></div>
}

function Field({ label, value, setValue, disabled = false }: { label: string; value: string; setValue: (value: string) => void; disabled?: boolean }) { return <label className="text-sm font-bold text-slate-700">{label}<input value={value} onChange={(event) => setValue(event.target.value)} disabled={disabled} required className="mt-2 w-full rounded-xl border border-slate-200 px-3 py-2.5 font-normal outline-none focus:border-emerald-500 disabled:bg-slate-100 disabled:text-slate-500" /></label> }
