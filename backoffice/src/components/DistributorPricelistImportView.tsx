'use client'

import { useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import { AlertTriangle, CheckCircle2, FileSpreadsheet, Loader2, Upload } from 'lucide-react'
import { parseDistributorPricelistFile, type DistributorPricelistRow } from '@/lib/distributor-pricelist-import'

type PlanRow = {
  rowNumber: number; sku: string; productName: string | null; status: 'VALID' | 'ERROR' | 'SKIPPED'
  errors: string[]; warnings: string[]; packFactor: number | null; dusFactor: number | null
  retail: number; cogs: number
}
type Plan = {
  mode: 'PREVIEW' | 'APPLY'; sourceRowCount: number; validRowCount: number
  errorRowCount: number; skippedRowCount: number; warningRowCount: number; productUomPriceUpdates: number
  pricelistRuleUpdates: number; configurationErrors: string[]; rows: PlanRow[]
  appliedProductCount?: number; appliedPricelistCount?: number; replayed?: boolean
}

const rupiah = (value: number | null) => new Intl.NumberFormat('id-ID', {
  style: 'currency', currency: 'IDR', maximumFractionDigits: 0,
}).format(value ?? 0)
const authHeaders = (session: Session) => ({
  Authorization: `Bearer ${session.access_token}`, 'Content-Type': 'application/json',
})
const messages: Record<string, string> = {
  ACTIVE_PRODUCT_SKU_NOT_FOUND_SKIPPED: 'SKU tidak ditemukan pada Company aktif; baris dilewati.',
  ACTIVE_PACK_SALES_UOM_NOT_FOUND: 'UOM jual PACK aktif tidak ditemukan.',
  AMBIGUOUS_ACTIVE_PACK_SALES_UOM: 'Product memiliki lebih dari satu UOM jual bernama PACK.',
  DUS_UOM_NOT_FOUND_SKIPPED: 'UOM DUS belum ada; harga UOM lain tetap dihitung.',
  EXACT_ONE_DEFAULT_GLOBAL_PRICELIST_REQUIRED: 'Company wajib memiliki tepat satu Pricelist Global default aktif.',
  NO_MATCHED_PRODUCT_SKU: 'Tidak ada satu pun SKU file yang cocok dengan Company aktif.',
  CUSTOM_PERMISSION_DENIED: 'Akses import Pricelist atau Product dibatasi.',
}
const friendly = (code: string) => {
  if (code.startsWith('IMPORT_PRICELIST_INACTIVE:')) {
    return `Aktifkan Pricelist ${code.split(':').slice(1).join(':')} sebelum import.`
  }
  if (code.startsWith('AMBIGUOUS_PRICELIST_NAME:')) {
    return `Nama Pricelist ${code.split(':').slice(1).join(':')} terduplikasi.`
  }
  return messages[code] ?? code
}

export function DistributorPricelistImportView({ session, companyName, notify }: {
  session: Session; companyName: string; notify: (message: string) => void
}) {
  const [source, setSource] = useState<{ fileName: string; checksum: string; rows: DistributorPricelistRow[] } | null>(null)
  const [plan, setPlan] = useState<Plan | null>(null)
  const [loading, setLoading] = useState(false)
  const [confirmed, setConfirmed] = useState(false)
  const [error, setError] = useState('')
  const [requestId, setRequestId] = useState('')

  async function call(mode: 'PREVIEW' | 'APPLY', nextSource = source) {
    if (!nextSource) return
    setLoading(true); setError('')
    try {
      const id = requestId || crypto.randomUUID()
      if (!requestId) setRequestId(id)
      const response = await fetch('/api/sales/pricelists/import', {
        method: 'POST', headers: authHeaders(session),
        body: JSON.stringify({ mode, ...nextSource, clientRequestId: id }),
      })
      const payload = await response.json() as { data?: Plan; error?: string }
      if (!response.ok || !payload.data) throw new Error(friendly(payload.error ?? 'PRICELIST_IMPORT_FAILED'))
      setPlan(payload.data)
      if (mode === 'APPLY') notify(`Pricelist ${companyName} berhasil diperbarui.`)
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Import Pricelist gagal.')
    } finally { setLoading(false) }
  }

  async function selectFile(file: File | undefined) {
    if (!file) return
    setLoading(true); setError(''); setPlan(null); setConfirmed(false); setRequestId(crypto.randomUUID())
    try {
      const parsed = await parseDistributorPricelistFile(file)
      setSource(parsed)
      await call('PREVIEW', parsed)
    } catch (caught) {
      setSource(null)
      setError(caught instanceof Error ? caught.message : 'File tidak dapat dibaca.')
    } finally { setLoading(false) }
  }

  const blocked = !plan || plan.errorRowCount > 0 || plan.configurationErrors.length > 0
  return <div className="space-y-5">
    <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm md:p-6">
      <p className="text-xs font-black uppercase tracking-[.16em] text-emerald-600">Import Pricelist Distributor</p>
      <h2 className="mt-2 text-2xl font-black text-slate-950">Upload harga PACK untuk {companyName}</h2>
      <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-500">
        Sistem mencocokkan Kode Produk dengan SKU Company aktif. COGS dan Retail menjadi harga dasar;
        Agen/SM, Spesial, dan Khusus menjadi Pricelist Customer; tier 60/100/150 masuk Pricelist Global.
        Harga DUS dan UOM lain dihitung dari faktor UOM.
      </p>
      <label className="mt-5 flex min-h-32 cursor-pointer flex-col items-center justify-center rounded-2xl border-2 border-dashed border-slate-300 bg-slate-50 p-6 text-center hover:border-emerald-500 hover:bg-emerald-50">
        {loading ? <Loader2 className="h-7 w-7 animate-spin text-emerald-600" /> : <Upload className="h-7 w-7 text-slate-400" />}
        <b className="mt-3 text-sm text-slate-800">Pilih file Excel atau CSV</b>
        <span className="mt-1 text-xs text-slate-500">Header file: Kode Produk, COGS, Retail, Agen/SM, Spesial, Khusus, dan tier Pack.</span>
        <input type="file" accept=".xlsx,.csv" disabled={loading} onChange={(event) => void selectFile(event.target.files?.[0])} className="sr-only" />
      </label>
      {source && <p className="mt-3 text-xs font-bold text-slate-500">File aktif: {source.fileName} · {source.rows.length} SKU</p>}
      {error && <div className="mt-4 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-bold text-rose-700">{error}</div>}
    </section>

    {plan && <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm md:p-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div><p className="text-xs font-black uppercase tracking-[.16em] text-slate-400">Preview server</p><h3 className="mt-2 text-xl font-black">{plan.mode === 'APPLY' ? 'Import selesai' : 'Periksa sebelum simpan'}</h3></div>
        <span className={`inline-flex items-center gap-2 rounded-full px-3 py-2 text-xs font-black ${blocked ? 'bg-rose-50 text-rose-700' : 'bg-emerald-50 text-emerald-700'}`}>
          {blocked ? <AlertTriangle className="h-4 w-4" /> : <CheckCircle2 className="h-4 w-4" />}
          {blocked ? 'Perlu diperbaiki' : 'Siap disimpan'}
        </span>
      </div>
      <div className="mt-5 grid gap-3 sm:grid-cols-2 xl:grid-cols-6">
        {[['SKU valid',plan.validRowCount],['SKU dilewati',plan.skippedRowCount],['SKU error',plan.errorRowCount],['Peringatan',plan.warningRowCount],['Harga UOM',plan.productUomPriceUpdates],['Rule Pricelist',plan.pricelistRuleUpdates]].map(([label,value]) =>
          <div key={String(label)} className="rounded-2xl bg-slate-50 p-4"><p className="text-xs font-bold text-slate-500">{label}</p><p className="mt-1 text-2xl font-black">{value}</p></div>)}
      </div>
      {plan.configurationErrors.length > 0 && <div className="mt-4 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-700">{plan.configurationErrors.map(friendly).join(' · ')}</div>}
      <div className="mt-5 max-h-[460px] overflow-auto rounded-2xl border border-slate-200">
        <table className="w-full min-w-[850px] text-left text-sm"><thead className="sticky top-0 bg-slate-50 text-xs uppercase text-slate-500"><tr><th className="px-4 py-3">Baris</th><th className="px-4 py-3">SKU / Product</th><th className="px-4 py-3">COGS PACK</th><th className="px-4 py-3">Retail PACK</th><th className="px-4 py-3">Faktor DUS</th><th className="px-4 py-3">Status</th></tr></thead>
          <tbody className="divide-y divide-slate-100">{plan.rows.map((row) => <tr key={`${row.rowNumber}-${row.sku}`}><td className="px-4 py-3">{row.rowNumber}</td><td className="px-4 py-3"><b>{row.sku}</b><span className="block text-xs text-slate-500">{row.productName ?? '-'}</span></td><td className="px-4 py-3">{rupiah(row.cogs)}</td><td className="px-4 py-3">{rupiah(row.retail)}</td><td className="px-4 py-3">{row.dusFactor ?? '-'}</td><td className="px-4 py-3">{row.errors.length > 0 ? <span className="text-xs font-bold text-rose-700">{row.errors.map(friendly).join(' · ')}</span> : row.status === 'SKIPPED' ? <span className="text-xs font-bold text-amber-700">{row.warnings.map(friendly).join(' · ')}</span> : row.warnings.length > 0 ? <span className="text-xs font-bold text-amber-700">{row.warnings.map(friendly).join(' · ')}</span> : <span className="text-xs font-bold text-emerald-700">Cocok</span>}</td></tr>)}</tbody>
        </table>
      </div>
      {plan.mode === 'PREVIEW' && <div className="mt-5 rounded-2xl border border-amber-200 bg-amber-50 p-4">
        <label className="flex items-start gap-3 text-sm font-bold text-amber-950"><input type="checkbox" checked={confirmed} onChange={(event) => setConfirmed(event.target.checked)} className="mt-0.5 h-4 w-4 accent-emerald-600" />Saya sudah memeriksa Company aktif, SKU, harga PACK, dan hasil perhitungan UOM.</label>
        <button type="button" disabled={blocked || !confirmed || loading} onClick={() => void call('APPLY')} className="mt-4 inline-flex min-h-11 items-center gap-2 rounded-xl bg-emerald-600 px-5 text-sm font-black text-white disabled:bg-slate-300">{loading ? <Loader2 className="h-4 w-4 animate-spin" /> : <FileSpreadsheet className="h-4 w-4" />}Simpan ke {companyName}</button>
      </div>}
      {plan.mode === 'APPLY' && <div className="mt-5 rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-sm font-bold text-emerald-800">{plan.appliedProductCount ?? 0} Product dan {plan.appliedPricelistCount ?? 0} Pricelist berhasil diproses{plan.replayed ? ' (retry aman)' : ''}.</div>}
    </section>}
  </div>
}
