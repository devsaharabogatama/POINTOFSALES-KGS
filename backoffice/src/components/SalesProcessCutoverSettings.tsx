'use client'

import { useCallback, useEffect, useRef, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import {
  ArrowRight,
  CalendarClock,
  CheckCircle2,
  CircleAlert,
  FileClock,
  Loader2,
  RefreshCcw,
  ShieldAlert,
  XCircle,
} from 'lucide-react'

type ProcessMode = 'RETAIL_CONFIRM_INVOICE' | 'BACKOFFICE_DELIVERED_QTY_INVOICE'
type Action = 'CREATE' | 'REFRESH' | 'CANCEL' | 'APPLY' | 'RECOVER'
type RecoveryCandidate = { itemId: string; planId: string; planVersion: number; sourceVersion: number; settingsVersion: number; sourceDocumentNo: string; sourceStatus: string }
type RecoveryResult = { targetDocumentId: string; targetDocumentNo: string }
type Summary = {
  convertible: number
  blocked: number
  keepSource: number
  finalSourceDocuments: number
  existingTargetOpenDocuments: number
  nonterminalOfflineSubmissions: number
  activeFinanceQueues: number
}
type Candidate = {
  itemId?: string
  sourceDocumentType: string
  sourceDocumentNo: string
  sourceStatus: string
  decision: string
  itemStatus?: string
  blockerCodes: string[]
  requirementCodes: string[]
  targetDocumentType?: string | null
  targetDocumentNo?: string | null
}
type Preview = {
  currentMode: ProcessMode
  targetMode: ProcessMode
  settingsVersion: number
  summary: Summary
  warnings: string[]
  candidates: Candidate[]
}
type Plan = {
  planId: string
  sourceMode: ProcessMode
  targetMode: ProcessMode
  effectiveAt: string
  status: string
  reason: string
  expectedSettingsVersion: number
  masterVersion: number
  createdAt: string
  updatedAt: string
  appliedAt?: string | null
  canceledAt?: string | null
  cancelReason?: string | null
  items: Candidate[]
}
type StatePayload = {
  companyId?: string
  recoveryCandidates?: RecoveryCandidate[]
  recoverySetupPending?: boolean
  serverNow?: string
  setting?: {
    activeMode: ProcessMode
    modeEffectiveAt: string
    masterVersion: number
    updatedAt: string
  }
  targetMode?: ProcessMode
  preview?: Preview
  openPlan?: Plan | null
  latestPlan?: Plan | null
  error?: string
}

const hardWarnings = new Set([
  'NONTERMINAL_OFFLINE_SUBMISSION_REVIEW_REQUIRED',
  'ACTIVE_FINANCE_QUEUE_MUST_FINISH',
  'BACKOFFICE_ENTITLEMENT_ENABLEMENT_REQUIRED',
])

const codeLabels: Record<string, string> = {
  NONTERMINAL_OFFLINE_SUBMISSION_REVIEW_REQUIRED:
    'Sinkronisasi transaksi Offline harus diselesaikan terlebih dahulu.',
  ACTIVE_FINANCE_QUEUE_MUST_FINISH:
    'Posting Queue Finance aktif harus diselesaikan terlebih dahulu.',
  BACKOFFICE_ENTITLEMENT_ENABLEMENT_REQUIRED:
    'Fitur Backoffice Quotation & Sales Order harus diaktifkan terlebih dahulu.',
  KEEP_BACKOFFICE_ENTITLEMENT_FOR_HISTORICAL_COMPLETION:
    'Fitur Backoffice tetap diperlukan untuk menyelesaikan dokumen lama yang dipertahankan.',
  PENDING_REVISION_MUST_RESOLVE:
    'Draft revisi yang masih pending harus diselesaikan terlebih dahulu.',
  OPEN_PROCUREMENT_MUST_FINISH:
    'Procurement terbuka harus diselesaikan pada proses asal.',
  MULTI_INSTALLMENT_MUST_FINISH_IN_BACKOFFICE:
    'Tagihan dengan beberapa cicilan harus diselesaikan di Backoffice.',
  PRESERVE_SINGLE_ABSOLUTE_DUE_DATE:
    'Tanggal jatuh tempo tunggal akan dipertahankan.',
  TRANSFER_RESERVATION_LINEAGE:
    'Relasi reservasi akan dipindahkan ke dokumen pengganti.',
  RECONCILE_TARGET_PROCUREMENT_DEMAND:
    'Kebutuhan procurement target akan direkonsiliasi.',
}

const errorLabels: Record<string, string> = {
  SALES_PROCESS_CUTOVER_SUPER_ADMIN_REQUIRED:
    'Hanya Platform Super Admin yang dapat mengganti proses penjualan.',
  SALES_PROCESS_CUTOVER_OPEN_PLAN_EXISTS:
    'Masih ada rencana pergantian aktif. Selesaikan atau batalkan rencana tersebut.',
  SALES_PROCESS_CUTOVER_PLAN_VERSION_STALE:
    'Rencana sudah berubah. Muat ulang sebelum melanjutkan.',
  SALES_PROCESS_CUTOVER_SETTINGS_VERSION_STALE:
    'Pengaturan Company sudah berubah. Muat ulang dan buat preview terbaru.',
  SALES_PROCESS_CUTOVER_PREVIEW_STALE:
    'Dokumen operasional berubah setelah preview. Refresh preview sebelum Apply.',
  SALES_PROCESS_CUTOVER_EFFECTIVE_AT_NOT_REACHED:
    'Waktu penerapan yang ditetapkan belum tercapai.',
  SALES_PROCESS_CUTOVER_ACTIVE_FINANCE_QUEUE:
    'Posting Queue Finance aktif harus diselesaikan sebelum Apply.',
  SALES_PROCESS_CUTOVER_NONTERMINAL_OFFLINE_SUBMISSION:
    'Sinkronisasi transaksi Offline harus diselesaikan sebelum Apply.',
  BACKOFFICE_SALES_FEATURE_NOT_ENABLED:
    'Aktifkan fitur Backoffice Quotation & Sales Order sebelum Apply.',
  SALES_PROCESS_CUTOVER_IDEMPOTENCY_PAYLOAD_CONFLICT:
    'Identitas operasi pernah digunakan dengan data berbeda. Muat ulang lalu ulangi.',
}

function modeLabel(mode?: ProcessMode) {
  return mode === 'BACKOFFICE_DELIVERED_QTY_INVOICE'
    ? 'Office · Invoice setelah barang diterima'
    : 'Retail · Invoice saat Order dikonfirmasi'
}

function friendlyError(code?: string) {
  return errorLabels[code ?? ''] ?? code ?? 'Operasi pergantian proses gagal.'
}

function codeLabel(code: string) {
  return codeLabels[code] ?? code
    .toLowerCase()
    .replaceAll('_', ' ')
    .replace(/^./, (letter) => letter.toUpperCase())
}

function formatDate(value?: string | null) {
  if (!value) return '—'
  return new Intl.DateTimeFormat('id-ID', {
    dateStyle: 'medium',
    timeStyle: 'short',
  }).format(new Date(value))
}

function nowLocalInput() {
  const now = new Date()
  const local = new Date(now.getTime() - now.getTimezoneOffset() * 60_000)
  return local.toISOString().slice(0, 16)
}

function authHeaders(session: Session, json = false) {
  return {
    Authorization: `Bearer ${session.access_token}`,
    ...(json ? { 'Content-Type': 'application/json' } : {}),
  }
}

async function jsonResponse(response: Response) {
  const payload = await response.json() as StatePayload & { data?: unknown }
  if (!response.ok) throw new Error(friendlyError(payload.error))
  return payload
}

export function SalesProcessCutoverSettings({
  session,
  companyName,
  complete,
  notify,
}: {
  session: Session
  companyName: string
  complete: () => Promise<void>
  notify: (message: string | null) => void
}) {
  const [state, setState] = useState<StatePayload>({})
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState<Action | ''>('')
  const [error, setError] = useState('')
  const [reason, setReason] = useState('')
  const [cancelReason, setCancelReason] = useState('')
  const [effectiveAt, setEffectiveAt] = useState(nowLocalInput)
  const [confirmed, setConfirmed] = useState(false)
  const [recovered, setRecovered] = useState<RecoveryResult[]>([])
  const recoveryOperations = useRef<Record<string, string>>({})
  const operationIds = useRef<Record<Action, string>>({
    CREATE: crypto.randomUUID(),
    REFRESH: crypto.randomUUID(),
    CANCEL: crypto.randomUUID(),
    APPLY: crypto.randomUUID(),
    RECOVER: crypto.randomUUID(),
  })

  const load = useCallback(async () => {
    setLoading(true)
    setError('')
    try {
      const response = await fetch('/api/platform/sales-process-cutover', {
        headers: authHeaders(session),
        cache: 'no-store',
      })
      setState(await jsonResponse(response))
      setConfirmed(false)
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Pengaturan proses gagal dimuat.')
    } finally {
      setLoading(false)
    }
  }, [session])

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- follows active Company context
    void load()
  }, [load])

  useEffect(() => {
    operationIds.current.CREATE = crypto.randomUUID()
  }, [effectiveAt, reason, state.targetMode])
  useEffect(() => {
    operationIds.current.CANCEL = crypto.randomUUID()
  }, [cancelReason])

  const plan = state.openPlan ?? null
  const preview = plan
    ? ({
        currentMode: plan.sourceMode,
        targetMode: plan.targetMode,
        settingsVersion: plan.expectedSettingsVersion,
        summary: state.preview?.summary,
        warnings: state.preview?.warnings ?? [],
        candidates: plan.items,
      } as Omit<Preview, 'summary'> & { summary?: Summary })
    : state.preview
  const items = plan?.items ?? state.preview?.candidates ?? []
  const counts = {
    convertible: items.filter((item) => item.decision === 'CONVERT').length,
    blocked: items.filter((item) => item.decision === 'BLOCKED').length,
    kept: items.filter((item) => item.decision === 'KEEP_SOURCE').length,
  }
  const applyBlocked = (state.preview?.warnings ?? []).some((warning) => hardWarnings.has(warning))
  const effectiveReached = plan && state.serverNow
    ? new Date(plan.effectiveAt).getTime() <= new Date(state.serverNow).getTime()
    : false

  async function mutate(action: Action) {
    if (!state.setting) return
    setBusy(action)
    setError('')
    const body: Record<string, unknown> = {
      action,
      operationId: operationIds.current[action],
    }
    if (action === 'CREATE') {
      body.targetMode = state.targetMode
      body.effectiveAt = new Date(effectiveAt).toISOString()
      body.settingsVersion = state.setting.masterVersion
      body.reason = reason
    } else if (plan) {
      body.planId = plan.planId
      body.planVersion = plan.masterVersion
      body.settingsVersion = state.setting.masterVersion
      if (action === 'CANCEL') body.reason = cancelReason
    }
    try {
      await jsonResponse(await fetch('/api/platform/sales-process-cutover', {
        method: 'POST',
        headers: authHeaders(session, true),
        body: JSON.stringify(body),
      }))
      operationIds.current[action] = crypto.randomUUID()
      if (action === 'APPLY') await complete()
      await load()
      if (action === 'CREATE') setReason('')
      if (action === 'CANCEL') setCancelReason('')
      notify(action === 'APPLY'
        ? `Proses penjualan ${companyName} berhasil diganti.`
        : action === 'CANCEL'
          ? 'Rencana pergantian proses dibatalkan.'
          : action === 'REFRESH'
            ? 'Preview diperbarui dari data operasional terbaru.'
            : 'Rencana pergantian proses berhasil dibuat.')
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Operasi pergantian proses gagal.')
    } finally {
      setBusy('')
    }
  }

  async function recover(item: RecoveryCandidate) {
    if (!window.confirm(`Pindahkan ${item.sourceDocumentNo} ke Office? Stock Request lama dipertahankan; sumber Retail ditutup dan SO/DO dibuat oleh sistem.`)) return
    const key = `${item.itemId}:${item.sourceVersion}:${item.settingsVersion}:${item.planVersion}`
    const operationId = recoveryOperations.current[key] ??= crypto.randomUUID()
    setBusy('RECOVER'); setError('')
    try {
      const body = await jsonResponse(await fetch('/api/platform/sales-process-cutover', {
        method: 'POST', headers: authHeaders(session, true),
        body: JSON.stringify({ action: 'RECOVER', itemId: item.itemId, planVersion: item.planVersion,
          sourceVersion: item.sourceVersion, settingsVersion: item.settingsVersion, operationId }),
      }))
      const result = body.data as RecoveryResult
      setRecovered((rows) => rows.some((row) => row.targetDocumentId === result.targetDocumentId) ? rows : [...rows, result])
      await complete(); await load()
      notify(`${item.sourceDocumentNo} berhasil dipindahkan ke ${result.targetDocumentNo}.`)
    } catch (caught) { setError(caught instanceof Error ? caught.message : 'Pemindahan gagal. Muat ulang untuk memeriksa kondisi terbaru.') }
    finally { setBusy('') }
  }

  return <article className="mt-4 overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-sm">
    <div className="flex flex-col gap-3 border-b border-slate-100 p-5 sm:flex-row sm:items-start sm:justify-between">
      <div>
        <div className="flex items-center gap-2">
          <ShieldAlert className="h-5 w-5 text-violet-600" />
          <h3 className="font-black text-slate-950">Proses penjualan aktif</h3>
        </div>
        <p className="mt-1 text-sm leading-6 text-slate-500">
          Pergantian memindahkan dokumen yang memenuhi syarat dan mempertahankan dokumen blocker pada proses asal.
        </p>
      </div>
      <button type="button" onClick={() => void load()} disabled={loading || Boolean(busy)} className="inline-flex items-center justify-center gap-2 rounded-xl border border-slate-200 px-3 py-2 text-sm font-bold text-slate-600 disabled:opacity-50">
        <RefreshCcw className={`h-4 w-4 ${loading ? 'animate-spin' : ''}`} /> Muat ulang
      </button>
    </div>

    <div className="p-5">
      {state.recoverySetupPending && state.setting?.activeMode === 'BACKOFFICE_DELIVERED_QTY_INVOICE' && <p className="mb-4 rounded-xl bg-amber-50 p-3 text-sm text-amber-900">Paket SQL recovery belum terpasang. Pergantian proses biasa tetap tersedia.</p>}
      {(state.recoveryCandidates?.length ?? 0) > 0 && <section className="mb-4 rounded-xl border border-amber-200 bg-amber-50/50 p-4">
        <h4 className="font-black text-slate-950">Order tertahan dari pergantian sebelumnya</h4>
        <p className="mt-1 text-sm text-slate-600">Sistem memeriksa ulang kondisi setiap order saat dipindahkan. Stock Request dan histori lama tetap dipertahankan.</p>
        <ul className="mt-3 space-y-2">{state.recoveryCandidates!.map((item) => <li key={item.itemId} className="flex flex-wrap items-center justify-between gap-3 rounded-lg border border-amber-100 bg-white p-3"><span><strong className="block text-sm">{item.sourceDocumentNo}</strong><span className="text-xs text-slate-500">{item.sourceStatus}</span></span><button type="button" disabled={Boolean(busy) || loading} onClick={() => void recover(item)} className="rounded-lg bg-emerald-600 px-3 py-2 text-sm font-bold text-white disabled:opacity-50">{busy === 'RECOVER' ? 'Memproses...' : 'Pindahkan ke Office'}</button></li>)}</ul>
      </section>}
      {recovered.length > 0 && <ul className="mb-4 space-y-1 rounded-xl bg-emerald-50 p-3 text-sm text-emerald-800">{recovered.map((row) => <li key={row.targetDocumentId}><a className="font-bold underline" href={`/?view=backoffice-sales-orders&orderId=${encodeURIComponent(row.targetDocumentId)}&companyId=${encodeURIComponent(state.companyId ?? '')}`}>{row.targetDocumentNo}</a> berhasil dibuat.</li>)}</ul>}
      {error && <div className="mb-4 flex gap-2 rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-700"><XCircle className="mt-0.5 h-4 w-4 shrink-0" />{error}</div>}
      {loading && !state.setting ? <div className="flex items-center gap-2 py-8 text-sm text-slate-500"><Loader2 className="h-4 w-4 animate-spin" /> Memuat kontrol proses...</div> : state.setting && preview && <>
        <div className="grid gap-3 md:grid-cols-[1fr_auto_1fr] md:items-stretch">
          <ModeCard label="Berjalan sekarang" mode={state.setting.activeMode} active />
          <div className="hidden items-center justify-center md:flex"><ArrowRight className="h-5 w-5 text-slate-300" /></div>
          <ModeCard label={plan ? 'Rencana tujuan' : 'Pilihan berikutnya'} mode={preview.targetMode} />
        </div>

        <div className="mt-4 grid gap-3 sm:grid-cols-3">
          <CountCard label="Dikonversi" value={counts.convertible} tone="emerald" />
          <CountCard label="Tetap di proses asal" value={counts.blocked + counts.kept} tone="amber" />
          <CountCard label="Dokumen diperiksa" value={items.length} tone="slate" />
        </div>

        {(state.preview?.warnings.length ?? 0) > 0 && <div className="mt-4 space-y-2">
          {state.preview!.warnings.map((warning) => <div key={warning} className={`flex gap-2 rounded-xl border p-3 text-sm ${hardWarnings.has(warning) ? 'border-rose-200 bg-rose-50 text-rose-800' : 'border-amber-200 bg-amber-50 text-amber-900'}`}><CircleAlert className="mt-0.5 h-4 w-4 shrink-0" /><span>{codeLabel(warning)}</span></div>)}
        </div>}

        <div className="mt-4 max-h-72 overflow-auto rounded-xl border border-slate-200">
          <table className="w-full min-w-[760px] text-left text-sm">
            <thead className="sticky top-0 bg-slate-50 text-xs uppercase text-slate-500"><tr><th className="p-3">Dokumen asal</th><th className="p-3">Status</th><th className="p-3">Keputusan</th><th className="p-3">Keterangan</th><th className="p-3">Dokumen baru</th></tr></thead>
            <tbody className="divide-y divide-slate-100">{items.map((item) => <tr key={item.itemId ?? `${item.sourceDocumentType}-${item.sourceDocumentNo}`}><td className="p-3"><strong className="block text-slate-900">{item.sourceDocumentNo}</strong><span className="text-xs text-slate-500">{item.sourceDocumentType === 'RETAIL_SALE' ? 'Order Retail' : 'Quotation / SO Backoffice'}</span></td><td className="p-3">{item.sourceStatus}</td><td className="p-3"><span className={`rounded-full px-2 py-1 text-xs font-bold ${item.decision === 'CONVERT' ? 'bg-emerald-50 text-emerald-700' : 'bg-amber-50 text-amber-800'}`}>{item.decision === 'CONVERT' ? 'Dikonversi' : 'Tetap di proses asal'}</span></td><td className="p-3 text-xs leading-5 text-slate-600">{[...item.blockerCodes, ...item.requirementCodes].map(codeLabel).join(' · ') || 'Tidak ada catatan'}</td><td className="p-3 font-bold text-slate-700">{item.targetDocumentNo ?? '—'}</td></tr>)}{items.length === 0 && <tr><td colSpan={5} className="p-8 text-center text-slate-500">Tidak ada dokumen terbuka yang perlu dikonversi atau dipertahankan.</td></tr>}</tbody>
          </table>
        </div>

        {plan ? <div className="mt-5 rounded-2xl border border-violet-200 bg-violet-50/40 p-4">
          <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between"><div><span className="rounded-full bg-violet-100 px-2.5 py-1 text-xs font-bold text-violet-700">{plan.status}</span><h4 className="mt-3 font-black text-slate-950">Rencana pergantian aktif</h4><p className="mt-1 text-sm text-slate-600">{plan.reason}</p><p className="mt-2 flex items-center gap-2 text-xs text-slate-500"><CalendarClock className="h-4 w-4" /> Dapat diterapkan mulai {formatDate(plan.effectiveAt)}</p></div><button type="button" disabled={Boolean(busy)} onClick={() => void mutate('REFRESH')} className="inline-flex items-center justify-center gap-2 rounded-xl border border-violet-200 bg-white px-3 py-2 text-sm font-bold text-violet-700 disabled:opacity-50">{busy === 'REFRESH' ? <Loader2 className="h-4 w-4 animate-spin" /> : <RefreshCcw className="h-4 w-4" />} Refresh preview</button></div>
          <label className="mt-4 flex items-start gap-3 rounded-xl border border-slate-200 bg-white p-3 text-sm text-slate-700"><input type="checkbox" checked={confirmed} onChange={(event) => setConfirmed(event.target.checked)} className="mt-1 h-4 w-4" /><span>Saya sudah memeriksa Company, mode tujuan, dokumen yang dikonversi, serta dokumen yang tetap memakai proses asal.</span></label>
          <div className="mt-4 flex flex-col gap-3 lg:flex-row"><input value={cancelReason} onChange={(event) => setCancelReason(event.target.value)} maxLength={500} placeholder="Alasan pembatalan rencana" className="min-h-11 min-w-0 flex-1 rounded-xl border border-slate-200 px-3" /><button type="button" disabled={Boolean(busy) || !cancelReason.trim()} onClick={() => void mutate('CANCEL')} className="min-h-11 rounded-xl border border-rose-200 bg-white px-4 text-sm font-bold text-rose-700 disabled:opacity-50">{busy === 'CANCEL' ? 'Membatalkan...' : 'Batalkan rencana'}</button><button type="button" disabled={Boolean(busy) || !confirmed || !effectiveReached || applyBlocked} onClick={() => void mutate('APPLY')} className="min-h-11 rounded-xl bg-violet-600 px-5 text-sm font-black text-white disabled:opacity-40">{busy === 'APPLY' ? 'Menerapkan...' : effectiveReached ? 'Terapkan proses baru' : `Tunggu ${formatDate(plan.effectiveAt)}`}</button></div>
        </div> : <div className="mt-5 rounded-2xl border border-slate-200 bg-slate-50 p-4">
          <h4 className="font-black text-slate-950">Buat preview tersimpan</h4>
          <p className="mt-1 text-sm leading-6 text-slate-500">Rencana belum mengubah mode atau dokumen. Data operasional akan diperiksa ulang saat Apply.</p>
          <div className="mt-4 grid gap-3 lg:grid-cols-[220px_1fr_auto]"><label className="text-sm font-bold text-slate-700">Waktu mulai berlaku<input type="datetime-local" value={effectiveAt} onChange={(event) => setEffectiveAt(event.target.value)} className="mt-1 block min-h-11 w-full rounded-xl border border-slate-200 bg-white px-3 font-normal" /></label><label className="text-sm font-bold text-slate-700">Alasan pergantian<input value={reason} onChange={(event) => setReason(event.target.value)} maxLength={500} placeholder="Contoh: Mulai operasional penjualan kantor" className="mt-1 block min-h-11 w-full rounded-xl border border-slate-200 bg-white px-3 font-normal" /></label><button type="button" disabled={Boolean(busy) || !reason.trim() || !effectiveAt} onClick={() => void mutate('CREATE')} className="min-h-11 self-end rounded-xl bg-slate-950 px-5 text-sm font-black text-white disabled:opacity-40">{busy === 'CREATE' ? 'Membuat...' : 'Buat rencana'}</button></div>
        </div>}

        {!plan && state.latestPlan && <p className="mt-3 flex items-center gap-2 text-xs text-slate-500"><FileClock className="h-4 w-4" /> Rencana terakhir: {state.latestPlan.status} · {formatDate(state.latestPlan.updatedAt)}</p>}
      </>}
    </div>
  </article>
}

function ModeCard({ label, mode, active = false }: { label: string; mode: ProcessMode; active?: boolean }) {
  return <div className={`rounded-xl border p-4 ${active ? 'border-emerald-200 bg-emerald-50' : 'border-violet-200 bg-violet-50'}`}><span className={`text-xs font-bold uppercase tracking-wide ${active ? 'text-emerald-700' : 'text-violet-700'}`}>{label}</span><strong className="mt-2 block text-slate-950">{modeLabel(mode)}</strong></div>
}

function CountCard({ label, value, tone }: { label: string; value: number; tone: 'emerald' | 'amber' | 'slate' }) {
  const styles = tone === 'emerald' ? 'border-emerald-200 bg-emerald-50 text-emerald-800' : tone === 'amber' ? 'border-amber-200 bg-amber-50 text-amber-900' : 'border-slate-200 bg-slate-50 text-slate-700'
  return <div className={`rounded-xl border p-3 ${styles}`}><span className="text-xs font-bold uppercase">{label}</span><strong className="mt-1 flex items-center gap-2 text-2xl"><CheckCircle2 className="h-4 w-4" />{value}</strong></div>
}
