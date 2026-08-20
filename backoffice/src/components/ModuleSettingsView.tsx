'use client'

import { useCallback, useEffect, useMemo, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import { Boxes, CircleAlert, RefreshCcw, Settings2, ShieldCheck, X } from 'lucide-react'
import { useEscapeClose } from '@/lib/use-escape-close'
import { OfflinePosSettings } from '@/components/OfflinePosSettings'
import { NegativeStockSettings } from '@/components/NegativeStockSettings'
import { PosTerminalUiSettings } from '@/components/PosTerminalUiSettings'

type Feature = {
  feature_code: string; feature_name: string; module_code: string
  description: string | null; is_enabled: boolean; updated_at: string | null
}
type Payload = { data?: Feature[]; error?: string }

const moduleLabels: Record<string, { name: string; description: string }> = {
  SALES: { name: 'Sales', description: 'Penjualan, customer, harga, dan pajak keluaran.' },
  PURCHASE: { name: 'Purchase', description: 'Pembelian, supplier, dan pajak masukan.' },
  POS: { name: 'Point of Sale', description: 'Mode operasional kasir dan workflow POS opsional.' },
}
const featureLabels: Record<string, { name: string; description: string; effect: string }> = {
  tax_sales_enabled: { name: 'Pajak Penjualan', description: 'Mengizinkan Company mengelola Tax Rule penjualan.', effect: 'Menu Aturan Pajak dapat membuat rule Sales. Kalkulasi checkout tetap mengikuti gate Tax Engine.' },
  tax_purchase_enabled: { name: 'Pajak Pembelian', description: 'Mengizinkan Company mengelola Tax Rule pembelian.', effect: 'Menu Aturan Pajak dapat membuat rule Purchase. Supplier Invoice Tax tetap mengikuti gate Purchasing.' },
  customer_balance_enabled: { name: 'Customer Balance', description: 'Saldo lebih bayar Customer dan workflow pemakaiannya.', effect: 'Hanya entitlement yang berubah; workflow transaksi tetap harus sudah diimplementasikan.' },
  offline_pos_enabled: { name: 'POS Offline', description: 'Mode transaksi dan sinkronisasi offline terkontrol.', effect: 'Jangan aktifkan untuk operasional sebelum UAT offline dan idempotency lulus.' },
  pos_negative_stock_enabled: { name: 'Stok Minus POS', description: 'Exception stok minus online yang dibatasi Company, Gudang, dan user.', effect: 'Aktifkan hanya setelah policy, opt-in Gudang, izin user, dan UAT replenishment siap.' },
  tempo_enabled: { name: 'POS Tempo', description: 'Penjualan tempo, cicilan, dan collection Customer.', effect: 'Jangan aktifkan sebelum workflow AR/collection dan posting terkait siap.' },
  ketul_enabled: { name: 'Operasional Ketul', description: 'Workflow Ketul opsional pada POS dan persediaan.', effect: 'Jangan aktifkan sebelum core stock dan checkout stabil.' },
}

function authHeaders(session: Session) { return { Authorization: `Bearer ${session.access_token}` } }
function friendlyError(code?: string) {
  const messages: Record<string, string> = {
    SUPER_ADMIN_REQUIRED: 'Hanya Super Admin yang dapat mengubah pengaturan modul.',
    ACTIVE_FEATURE_NOT_FOUND: 'Modul tidak aktif atau tidak ditemukan di katalog platform.',
    ACTIVE_COMPANY_NOT_FOUND: 'Pilih Company aktif terlebih dahulu.',
    FORBIDDEN: 'Anda tidak memiliki akses ke pengaturan modul.',
  }
  return messages[code ?? ''] ?? code ?? 'Operasi pengaturan modul gagal.'
}

export function ModuleSettingsView({ session, companyId, companyName, isSuperAdmin, notify }: {
  session: Session; companyId: string; companyName: string
  isSuperAdmin: boolean
  notify: (message: string | null) => void
}) {
  const [features, setFeatures] = useState<Feature[]>([])
  const [activeModule, setActiveModule] = useState('SALES')
  const [pending, setPending] = useState<Feature | undefined>()
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')

  const refresh = useCallback(async () => {
    setLoading(true); setError('')
    try {
      const response = await fetch('/api/platform/module-settings', {
        headers: authHeaders(session), cache: 'no-store',
      })
      const payload = await response.json() as Payload
      if (!response.ok) throw new Error(friendlyError(payload.error))
      setFeatures(payload.data ?? [])
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Gagal memuat pengaturan modul.')
    } finally { setLoading(false) }
  }, [session])

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- settings follow active Company context
    void refresh()
  }, [companyId, refresh])

  const modules = useMemo(
    () => [...new Set(features.map((feature) => feature.module_code))],
    [features],
  )
  const visible = features.filter((feature) => feature.module_code === activeModule)

  return <>
    <div className="mb-7 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between"><div><p className="text-xs font-bold uppercase tracking-[.16em] text-emerald-600">Platform Control</p><h1 className="mt-2 text-2xl font-black tracking-tight text-slate-950 md:text-3xl">Pengaturan Modul</h1><p className="mt-2 max-w-3xl text-sm leading-6 text-slate-500">Aktifkan kemampuan opsional untuk <b>{companyName}</b>. Company mengikuti pilihan pada selector workspace di atas.</p></div><button onClick={() => void refresh()} className="inline-flex items-center justify-center gap-2 rounded-xl border border-slate-200 bg-white px-4 py-3 text-sm font-bold text-slate-600"><RefreshCcw className={`h-4 w-4 ${loading ? 'animate-spin' : ''}`} /> Muat ulang</button></div>
    <div className="mb-5 flex gap-3 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm leading-6 text-amber-900"><CircleAlert className="mt-0.5 h-5 w-5 shrink-0" /><span><b>Toggle adalah entitlement, bukan tanda modul siap produksi.</b> {isSuperAdmin ? 'Aktifkan hanya setelah dependency dan UAT modul terkait lulus. Setiap perubahan tercatat pada audit Company Feature.' : 'Status entitlement hanya dapat diubah Super Admin. Anda tetap dapat menyiapkan konfigurasi operasional sesuai role.'}</span></div>
    {error && <div className="mb-5 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-700">{error}</div>}
    <div className="grid gap-5 lg:grid-cols-[260px_1fr]"><aside className="rounded-2xl border border-slate-200 bg-white p-3 shadow-sm"><p className="px-3 py-2 text-xs font-bold uppercase tracking-wider text-slate-400">Pilih modul</p>{modules.map((module) => { const meta = moduleLabels[module] ?? { name: module, description: 'Modul platform.' }; const count = features.filter((item) => item.module_code === module && item.is_enabled).length; return <button key={module} onClick={() => setActiveModule(module)} className={`mt-1 w-full rounded-xl p-3 text-left transition ${activeModule === module ? 'bg-slate-950 text-white' : 'hover:bg-slate-50'}`}><div className="flex items-center gap-2"><Boxes className="h-4 w-4" /><span className="font-bold">{meta.name}</span><span className={`ml-auto rounded-full px-2 py-0.5 text-xs ${activeModule === module ? 'bg-white/10' : 'bg-slate-100 text-slate-500'}`}>{count} aktif</span></div><p className={`mt-2 text-xs leading-5 ${activeModule === module ? 'text-slate-400' : 'text-slate-500'}`}>{meta.description}</p></button>})}</aside><section><div className="mb-4"><h2 className="text-xl font-black text-slate-950">{moduleLabels[activeModule]?.name ?? activeModule}</h2><p className="mt-1 text-sm text-slate-500">{moduleLabels[activeModule]?.description}</p></div><div className="space-y-3">{visible.map((feature) => { const meta = featureLabels[feature.feature_code] ?? { name: feature.feature_name, description: feature.description ?? 'Fitur platform.', effect: 'Entitlement Company akan diperbarui.' }; return <article key={feature.feature_code} className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm"><div className="flex flex-col gap-4 sm:flex-row sm:items-center"><div className={`grid h-11 w-11 shrink-0 place-items-center rounded-xl ${feature.is_enabled ? 'bg-emerald-50 text-emerald-600' : 'bg-slate-100 text-slate-400'}`}><Settings2 className="h-5 w-5" /></div><div className="min-w-0 flex-1"><div className="flex flex-wrap items-center gap-2"><h3 className="font-bold text-slate-950">{meta.name}</h3><span className={`rounded-full px-2.5 py-1 text-xs font-bold ${feature.is_enabled ? 'bg-emerald-50 text-emerald-700' : 'bg-slate-100 text-slate-500'}`}>{feature.is_enabled ? 'Aktif' : 'Nonaktif'}</span></div><p className="mt-1 text-sm leading-6 text-slate-500">{meta.description}</p></div>{isSuperAdmin ? <button onClick={() => setPending(feature)} className={`rounded-xl px-4 py-2.5 text-sm font-bold ${feature.is_enabled ? 'border border-rose-200 bg-white text-rose-600' : 'bg-emerald-500 text-white'}`}>{feature.is_enabled ? 'Nonaktifkan' : 'Aktifkan'}</button> : <span className="rounded-xl bg-slate-100 px-3 py-2 text-xs font-bold text-slate-500">Dikelola Super Admin</span>}</div></article>})}{!loading && !visible.length && <div className="rounded-2xl border border-dashed border-slate-300 p-10 text-center text-sm text-slate-400">Belum ada konfigurasi untuk modul ini.</div>}</div>{activeModule === 'POS' && <><PosTerminalUiSettings session={session} companyId={companyId} notify={notify}/><OfflinePosSettings session={session} companyId={companyId} notify={notify} /><NegativeStockSettings session={session} companyId={companyId} notify={notify} /></>}</section></div>
    {pending && <ConfirmFeature session={session} feature={pending} companyName={companyName} close={() => setPending(undefined)} complete={async () => { const enabled = !pending.is_enabled; setPending(undefined); await refresh(); notify(`${featureLabels[pending.feature_code]?.name ?? pending.feature_name} berhasil ${enabled ? 'diaktifkan' : 'dinonaktifkan'}.`) }} />}
  </>
}

function ConfirmFeature({ session, feature, companyName, close, complete }: {
  session: Session; feature: Feature; companyName: string
  close: () => void; complete: () => Promise<void>
}) {
  useEscapeClose(close)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')
  const enabling = !feature.is_enabled
  const meta = featureLabels[feature.feature_code] ?? { name: feature.feature_name, effect: feature.description ?? '' }
  async function confirm() {
    setSaving(true); setError('')
    try {
      const response = await fetch('/api/platform/module-settings', {
        method: 'PATCH', headers: { 'Content-Type': 'application/json', ...authHeaders(session) },
        body: JSON.stringify({ featureCode: feature.feature_code, enabled: enabling }),
      })
      const payload = await response.json() as { error?: string }
      if (!response.ok) throw new Error(friendlyError(payload.error))
      await complete()
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Gagal mengubah pengaturan modul.')
    } finally { setSaving(false) }
  }
  return <div className="fixed inset-0 z-[80] grid place-items-center overflow-y-auto bg-slate-950/50 p-4 backdrop-blur-sm"><div className="w-full max-w-lg rounded-3xl bg-white shadow-2xl"><div className="flex items-start justify-between border-b border-slate-100 p-6"><div><div className="mb-3 inline-flex items-center gap-2 rounded-full bg-slate-100 px-3 py-1 text-xs font-bold text-slate-600"><ShieldCheck className="h-3.5 w-3.5" /> Super Admin</div><h2 className="text-xl font-black text-slate-950">{enabling ? 'Aktifkan' : 'Nonaktifkan'} {meta.name}?</h2></div><button onClick={close} className="rounded-xl border border-slate-200 p-2 text-slate-500" aria-label="Tutup"><X className="h-5 w-5" /></button></div><div className="space-y-4 p-6"><p className="text-sm leading-6 text-slate-600">Perubahan berlaku untuk <b>{companyName}</b>. {meta.effect}</p>{error && <div className="rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-700">{error}</div>}<div className="flex justify-end gap-3 pt-2"><button onClick={close} className="rounded-xl border border-slate-200 px-4 py-2.5 text-sm font-bold text-slate-600">Batal</button><button disabled={saving} onClick={() => void confirm()} className={`rounded-xl px-4 py-2.5 text-sm font-bold text-white disabled:opacity-50 ${enabling ? 'bg-emerald-500' : 'bg-rose-600'}`}>{saving ? 'Menyimpan...' : enabling ? 'Ya, aktifkan' : 'Ya, nonaktifkan'}</button></div></div></div></div>
}
