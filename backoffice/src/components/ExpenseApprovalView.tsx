'use client'

import { useCallback, useEffect, useMemo, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import {
  Ban,
  CheckCircle2,
  Eye,
  FileCheck2,
  Loader2,
  RefreshCcw,
  RotateCcw,
  Search,
  X,
  XCircle,
} from 'lucide-react'
import { useEscapeClose } from '@/lib/use-escape-close'

type ExpenseStatus =
  | 'DRAFT'
  | 'SUBMITTED'
  | 'APPROVED'
  | 'REJECTED'
  | 'CANCELED'
  | 'PAYMENT_PENDING'
  | 'DISBURSED'
  | 'PARTIALLY_SETTLED'
  | 'SETTLED'
  | 'SETTLED_NO_EXPENSE'
  | 'REVERSED'

type ExpenseDocument = {
  id: string
  document_no: string
  store_id: string
  cashier_session_id: string | null
  category_name_snapshot: string
  responsible_party_type: string
  responsible_party_id: string | null
  responsible_party_name_snapshot: string
  requested_amount: number | string
  disbursed_amount: number | string
  actual_expense_amount: number | string
  returned_amount: number | string
  outstanding_amount: number | string
  requested_payment_method_id: string
  requested_payment_method_name_snapshot: string
  requested_payment_method_type_snapshot: string
  recipient: string | null
  description: string
  evidence_url: string | null
  expected_settlement_date: string | null
  status: ExpenseStatus
  approval_required_snapshot: boolean
  evidence_policy_snapshot: string
  master_version: number | string
  created_by: string
  submitted_by: string | null
  approved_by: string | null
  rejected_by: string | null
  canceled_by: string | null
  created_at: string
  updated_at: string
  submitted_at: string | null
  approved_at: string | null
  rejected_at: string | null
  canceled_at: string | null
  rejection_reason: string | null
  cancel_reason: string | null
  disbursed_by: string | null
  disbursed_at: string | null
  settled_by: string | null
  settled_at: string | null
}

type ExpenseSettlementRequest = {
  id: string
  document_id: string
  store_id: string
  actual_expense_amount: number | string
  evidence_url: string | null
  status: 'SUBMITTED' | 'APPROVED' | 'REJECTED'
  submitted_by: string
  reviewed_by: string | null
  submitted_at: string
  reviewed_at: string | null
  rejection_reason: string | null
  master_version: number | string
}

type ExpenseAdditionalRequest = {
  id: string
  document_id: string
  store_id: string
  amount: number | string
  payment_method_id: string
  payment_method_name_snapshot: string
  payment_method_type_snapshot: string
  evidence_url: string | null
  approval_required_snapshot: boolean
  status: 'SUBMITTED' | 'APPROVED' | 'REJECTED' | 'DISBURSED'
  document_master_version_snapshot: number | string
  requested_by: string
  approved_by: string | null
  rejected_by: string | null
  disbursed_by: string | null
  requested_at: string
  approved_at: string | null
  rejected_at: string | null
  rejection_reason: string | null
  disbursed_at: string | null
  expense_disbursement_id: string | null
  master_version: number | string
}

type Lookup = {
  id: string
  name?: string
  store_name?: string
  session_code?: string
  status?: string
  payment_method_name?: string
  method_type?: string
  proof_mode?: string
  settlement_route?: string
  is_active?: boolean
}

type Payload = {
  data?: ExpenseDocument[]
  stores?: Lookup[]
  sessions?: Lookup[]
  actors?: Lookup[]
  paymentMethods?: Lookup[]
  settlementRequests?: ExpenseSettlementRequest[]
  additionalRequests?: ExpenseAdditionalRequest[]
  error?: string
}

type Action = {
  type: 'approve' | 'reject' | 'cancel' | 'disburse'
  document: ExpenseDocument
  paymentMethod?: Lookup
}

type SettlementAction = {
  type: 'APPROVE' | 'REJECT'
  request: ExpenseSettlementRequest
  document: ExpenseDocument
}

type AdditionalReviewAction = {
  type: 'APPROVE' | 'REJECT'
  request: ExpenseAdditionalRequest
  document: ExpenseDocument
}

type AdditionalDisbursementAction = {
  request: ExpenseAdditionalRequest
  document: ExpenseDocument
  paymentMethod?: Lookup
}

function authHeaders(session: Session) {
  return { Authorization: `Bearer ${session.access_token}` }
}

function rupiah(value: number | string) {
  return new Intl.NumberFormat('id-ID', {
    style: 'currency',
    currency: 'IDR',
    maximumFractionDigits: 0,
  }).format(Number(value) || 0)
}

function dateTime(value: string | null) {
  return value ? new Date(value).toLocaleString('id-ID') : '-'
}

function dateOnly(value: string | null) {
  return value ? new Date(`${value}T00:00:00`).toLocaleDateString('id-ID') : '-'
}

function statusLabel(status: ExpenseStatus) {
  const labels: Record<ExpenseStatus, string> = {
    DRAFT: 'Draft',
    SUBMITTED: 'Menunggu approval',
    APPROVED: 'Disetujui — belum dicairkan',
    REJECTED: 'Ditolak',
    CANCELED: 'Dibatalkan',
    PAYMENT_PENDING: 'Menunggu pembayaran',
    DISBURSED: 'Sudah dicairkan',
    PARTIALLY_SETTLED: 'Sebagian diselesaikan',
    SETTLED: 'Selesai',
    SETTLED_NO_EXPENSE: 'Selesai tanpa biaya',
    REVERSED: 'Dikoreksi',
  }
  return labels[status]
}

function responsibleLabel(type: string) {
  const labels: Record<string, string> = {
    CASHIER: 'Kasir',
    STORE_MANAGER: 'Manager Toko',
    EMPLOYEE: 'Pegawai',
    EXTERNAL: 'Pihak luar',
  }
  return labels[type] ?? type
}

function friendlyError(code?: string) {
  const labels: Record<string, string> = {
    EXPENSE_DOCUMENT_NOT_FOUND: 'Pengajuan Expense tidak ditemukan.',
    ONLY_SUBMITTED_EXPENSE_REVIEWABLE: 'Hanya Expense yang menunggu approval yang dapat direview.',
    EXPENSE_APPROVER_REQUIRED: 'Role atau cakupan Store Anda tidak dapat menyetujui Expense ini.',
    EXPENSE_REJECTION_REASON_REQUIRED: 'Alasan penolakan wajib diisi.',
    EXPENSE_CANCEL_NOT_ALLOWED: 'Status Expense ini tidak dapat dibatalkan.',
    EXPENSE_CANCELER_REQUIRED: 'Anda tidak diizinkan membatalkan Expense ini.',
    CANCEL_REASON_REQUIRED: 'Alasan pembatalan wajib diisi.',
    REASON_REQUIRED: 'Alasan wajib diisi.',
    MASTER_VERSION_CONFLICT: 'Pengajuan berubah di perangkat lain. Muat ulang sebelum mengulangi tindakan.',
    FORBIDDEN: 'Anda tidak memiliki akses ke pengajuan Expense.',
    ONLY_APPROVED_EXPENSE_DISBURSABLE: 'Hanya Expense approved yang dapat dibayar.',
    EXPENSE_CASH_DISBURSEMENT_POS_REQUIRED: 'Expense tunai harus dicairkan dari POS dengan sesi kasir aktif.',
    EXPENSE_INITIAL_DISBURSEMENT_STATE_INVALID: 'Expense ini sudah memiliki riwayat pencairan.',
    EXPENSE_APPROVAL_SNAPSHOT_INCOMPLETE: 'Bukti approval Expense belum lengkap.',
    ACTIVE_EXPENSE_PAYMENT_METHOD_NOT_FOUND: 'Metode pembayaran Expense tidak lagi aktif untuk Store ini.',
    EXPENSE_PAYMENT_METHOD_SNAPSHOT_CONFLICT: 'Konfigurasi metode pembayaran berubah. Review dokumen sebelum melanjutkan.',
    EXPENSE_DISBURSEMENT_EVIDENCE_REQUIRED: 'Metode pembayaran ini mewajibkan link bukti pembayaran.',
    EXPENSE_DISBURSEMENT_EVIDENCE_HTTPS_REQUIRED: 'Link bukti pembayaran harus menggunakan HTTPS.',
    EXPENSE_NONCASH_DISBURSER_REQUIRED: 'Hanya Finance, Pemilik, atau Admin Perusahaan yang boleh mengonfirmasi pembayaran non-tunai.',
    EXPENSE_DISBURSEMENT_CATEGORY_NOT_FOUND: 'Kategori transaksi pencairan Expense belum siap.',
    EXPENSE_DISBURSEMENT_ACCOUNT_NOT_RESOLVED: 'Akun pencairan Expense belum dapat ditentukan.',
    EXPENSE_DISBURSEMENT_IDEMPOTENCY_CONFLICT: 'Permintaan pembayaran bertentangan dengan percobaan sebelumnya.',
    EXPENSE_SETTLEMENT_REQUEST_NOT_FOUND: 'Pengajuan biaya aktual tidak ditemukan.',
    ONLY_SUBMITTED_SETTLEMENT_REVIEWABLE: 'Pengajuan biaya aktual ini sudah direview.',
    EXPENSE_SETTLEMENT_REVIEWER_REQUIRED: 'Anda tidak memiliki akses untuk mereview biaya aktual ini.',
    EXPENSE_SETTLEMENT_REJECTION_REASON_REQUIRED: 'Alasan penolakan biaya aktual wajib diisi.',
    EXPENSE_ACTUAL_EXCEEDS_OUTSTANDING: 'Biaya aktual melebihi outstanding Expense.',
    EXPENSE_RETURN_NOT_ALLOWED: 'Expense ini tidak dapat menerima pengembalian dana.',
    EXPENSE_RETURN_EXCEEDS_OUTSTANDING: 'Nominal pengembalian melebihi outstanding Expense.',
    EXPENSE_RETURN_EVIDENCE_REQUIRED: 'Metode ini mewajibkan link bukti pengembalian.',
    EXPENSE_RETURN_EVIDENCE_HTTPS_REQUIRED: 'Link bukti pengembalian harus menggunakan HTTPS.',
    EXPENSE_NONCASH_RETURN_RECEIVER_REQUIRED: 'Hanya Finance, Pemilik, atau Admin Perusahaan yang boleh menerima pengembalian non-tunai.',
    EXPENSE_CASH_RETURN_POS_REQUIRED: 'Pengembalian tunai harus diterima dari POS dengan sesi kasir aktif.',
    EXPENSE_RETURN_IDEMPOTENCY_CONFLICT: 'Permintaan pengembalian bertentangan dengan percobaan sebelumnya.',
    EXPENSE_ADDITIONAL_REQUEST_NOT_FOUND: 'Permintaan dana tambahan tidak ditemukan.',
    ONLY_SUBMITTED_ADDITIONAL_REQUEST_REVIEWABLE: 'Permintaan dana tambahan ini sudah direview.',
    EXPENSE_ADDITIONAL_REVIEWER_REQUIRED: 'Anda tidak memiliki akses untuk mereview dana tambahan ini.',
    EXPENSE_ADDITIONAL_REJECTION_REASON_REQUIRED: 'Alasan penolakan dana tambahan wajib diisi.',
    ONLY_APPROVED_ADDITIONAL_REQUEST_DISBURSABLE: 'Permintaan dana tambahan ini tidak lagi siap dibayar.',
    EXPENSE_ADDITIONAL_DOCUMENT_NOT_OPEN: 'Dokumen Expense sudah tidak terbuka.',
    EXPENSE_ADDITIONAL_CASH_DISBURSEMENT_POS_REQUIRED: 'Dana tambahan tunai harus dicairkan dari POS dengan sesi kasir aktif.',
    EXPENSE_ADDITIONAL_EVIDENCE_REQUIRED: 'Metode ini mewajibkan link bukti pembayaran.',
    EXPENSE_ADDITIONAL_DISBURSEMENT_EVIDENCE_REQUIRED: 'Metode ini mewajibkan link bukti pembayaran.',
    EXPENSE_ADDITIONAL_EVIDENCE_HTTPS_REQUIRED: 'Link bukti pembayaran harus menggunakan HTTPS.',
    EXPENSE_ADDITIONAL_NONCASH_DISBURSER_REQUIRED: 'Hanya Finance, Pemilik, atau Admin Perusahaan yang boleh membayar dana tambahan non-tunai.',
    EXPENSE_ADDITIONAL_DISBURSEMENT_IDEMPOTENCY_CONFLICT: 'Permintaan pembayaran bertentangan dengan percobaan sebelumnya.',
  }
  return labels[code ?? ''] ?? code ?? 'Operasi Expense gagal.'
}

export function ExpenseApprovalView({
  session,
  companyId,
  canApprove,
  canCancelAdministrative,
  canDisburseNonCash,
  notify,
}: {
  session: Session
  companyId: string
  canApprove: boolean
  canCancelAdministrative: boolean
  canDisburseNonCash: boolean
  notify: (message: string) => void
}) {
  const [payload, setPayload] = useState<Payload>({})
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [status, setStatus] = useState<'ALL' | ExpenseStatus>('SUBMITTED')
  const [search, setSearch] = useState('')
  const [detail, setDetail] = useState<ExpenseDocument | null>(null)
  const [action, setAction] = useState<Action | null>(null)
  const [settlementAction, setSettlementAction] = useState<SettlementAction | null>(null)
  const [additionalReviewAction, setAdditionalReviewAction] = useState<AdditionalReviewAction | null>(null)
  const [additionalDisbursementAction, setAdditionalDisbursementAction] = useState<AdditionalDisbursementAction | null>(null)
  const [returnDocument, setReturnDocument] = useState<ExpenseDocument | null>(null)

  const load = useCallback(async () => {
    const response = await fetch('/api/finance/expenses', {
      headers: authHeaders(session),
    })
    const result = (await response.json()) as Payload
    if (!response.ok) throw new Error(friendlyError(result.error))
    setPayload(result)
  }, [session])

  const refresh = useCallback(async () => {
    setLoading(true)
    setError('')
    try {
      await load()
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Gagal memuat Expense.')
    } finally {
      setLoading(false)
    }
  }, [load])

  useEffect(() => {
    let canceled = false
    // eslint-disable-next-line react-hooks/set-state-in-effect -- synchronize data to the active Company context
    load().catch((caught) => {
      if (!canceled) {
        setError(caught instanceof Error ? caught.message : 'Gagal memuat Expense.')
      }
    }).finally(() => {
      if (!canceled) setLoading(false)
    })
    return () => { canceled = true }
  }, [companyId, load])

  const storeById = useMemo(
    () => new Map((payload.stores ?? []).map((row) => [row.id, row.store_name ?? 'Store'])),
    [payload.stores],
  )
  const sessionById = useMemo(
    () => new Map((payload.sessions ?? []).map((row) => [row.id, row])),
    [payload.sessions],
  )
  const actorById = useMemo(
    () => new Map((payload.actors ?? []).map((row) => [row.id, row.name ?? 'User'])),
    [payload.actors],
  )
  const paymentMethodById = useMemo(
    () => new Map((payload.paymentMethods ?? []).map((row) => [row.id, row])),
    [payload.paymentMethods],
  )
  const submittedSettlementByDocument = useMemo(() => {
    const rows = (payload.settlementRequests ?? []).filter((row) => row.status === 'SUBMITTED')
    return new Map(rows.map((row) => [row.document_id, row]))
  }, [payload.settlementRequests])
  const additionalByDocument = useMemo(() => {
    const map = new Map<string, ExpenseAdditionalRequest[]>()
    for (const row of payload.additionalRequests ?? []) {
      map.set(row.document_id, [...(map.get(row.document_id) ?? []), row])
    }
    return map
  }, [payload.additionalRequests])
  const documents = useMemo(() => {
    const term = search.trim().toLowerCase()
    return (payload.data ?? []).filter((row) => {
      if (status !== 'ALL' && row.status !== status) return false
      return !term || [
        row.document_no,
        row.category_name_snapshot,
        row.responsible_party_name_snapshot,
        row.description,
        storeById.get(row.store_id),
      ].some((value) => value?.toLowerCase().includes(term))
    })
  }, [payload.data, search, status, storeById])
  const counts = useMemo(() => ({
    submitted: (payload.data ?? []).filter((row) => row.status === 'SUBMITTED').length,
    approved: (payload.data ?? []).filter((row) => row.status === 'APPROVED').length,
    rejected: (payload.data ?? []).filter((row) => row.status === 'REJECTED').length,
    disbursed: (payload.data ?? []).filter((row) => row.status === 'DISBURSED').length,
    settlementReview: (payload.settlementRequests ?? []).filter((row) => row.status === 'SUBMITTED').length,
    additionalReview: (payload.additionalRequests ?? []).filter((row) => row.status === 'SUBMITTED').length,
    additionalPayment: (payload.additionalRequests ?? []).filter((row) => row.status === 'APPROVED').length,
  }), [payload.data, payload.settlementRequests, payload.additionalRequests])

  return (
    <>
      <section className="space-y-6">
        <div className="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
          <div>
            <p className="text-xs font-black uppercase tracking-[0.18em] text-violet-600">Finance Control</p>
            <h1 className="mt-2 text-3xl font-black text-slate-950">Approval & Pembayaran Expense</h1>
            <p className="mt-2 max-w-3xl text-sm text-slate-500">
              Review pengajuan dan konfirmasi pembayaran non-tunai. Expense tunai tetap dicairkan dari sesi kasir di POS.
            </p>
          </div>
          <button onClick={refresh} disabled={loading} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-xl border border-slate-200 bg-white px-4 text-sm font-black text-slate-700 shadow-sm disabled:opacity-50">
            <RefreshCcw className={`h-4 w-4 ${loading ? 'animate-spin' : ''}`} /> Muat ulang
          </button>
        </div>

        <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-5">
          <Summary label="Menunggu approval" value={String(counts.submitted)} tone="amber" />
          <Summary label="Disetujui, belum dicairkan" value={String(counts.approved)} tone="emerald" />
          <Summary label="Ditolak" value={String(counts.rejected)} tone="rose" />
          <Summary label="Perlu review aktual" value={String(counts.settlementReview)} tone="violet" />
          <Summary label="Tambahan perlu tindakan" value={String(counts.additionalReview + counts.additionalPayment)} tone="amber" />
        </div>

        <div className="grid gap-3 rounded-2xl border border-slate-200 bg-white p-4 shadow-sm md:grid-cols-[240px_1fr]">
          <label className="text-sm font-bold text-slate-700">Status
            <select value={status} onChange={(event) => setStatus(event.target.value as typeof status)} className="mt-2 min-h-11 w-full rounded-xl border border-slate-200 bg-white px-3 font-semibold outline-none focus:border-violet-500">
              <option value="SUBMITTED">Menunggu approval</option>
              <option value="APPROVED">Disetujui</option>
              <option value="REJECTED">Ditolak</option>
              <option value="PAYMENT_PENDING">Menunggu pembayaran</option>
              <option value="DISBURSED">Sudah dicairkan</option>
              <option value="PARTIALLY_SETTLED">Sebagian diselesaikan</option>
              <option value="SETTLED">Selesai</option>
              <option value="SETTLED_NO_EXPENSE">Selesai tanpa biaya</option>
              <option value="DRAFT">Draft</option>
              <option value="CANCELED">Dibatalkan</option>
              <option value="ALL">Semua status</option>
            </select>
          </label>
          <label className="text-sm font-bold text-slate-700">Cari Expense
            <span className="mt-2 flex min-h-11 items-center gap-2 rounded-xl border border-slate-200 px-3 focus-within:border-violet-500">
              <Search className="h-4 w-4 text-slate-400" />
              <input value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Nomor, kategori, penanggung jawab, keperluan, atau Store" className="w-full bg-transparent text-sm outline-none" />
            </span>
          </label>
        </div>

        {error && <div className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-semibold text-rose-700">{error}</div>}
        <div className="overflow-x-auto rounded-2xl border border-slate-200 bg-white shadow-sm">
          <table className="w-full min-w-[980px] text-left text-sm">
            <thead className="bg-slate-50 text-xs uppercase tracking-wider text-slate-500"><tr><th className="px-5 py-4">Expense</th><th className="px-5 py-4">Kategori / Penanggung jawab</th><th className="px-5 py-4">Store</th><th className="px-5 py-4 text-right">Diajukan</th><th className="px-5 py-4">Status</th><th className="px-5 py-4 text-right">Aksi</th></tr></thead>
            <tbody className="divide-y divide-slate-100">
              {documents.map((row) => <tr key={row.id} className="hover:bg-slate-50/70">
                <td className="px-5 py-4"><p className="font-black text-slate-900">{row.document_no}</p><p className="mt-1 max-w-xs truncate text-xs text-slate-500">{row.description}</p></td>
                <td className="px-5 py-4"><p className="font-bold text-slate-800">{row.category_name_snapshot}</p><p className="mt-1 text-xs text-slate-500">{row.responsible_party_name_snapshot}</p></td>
                <td className="px-5 py-4 text-slate-600">{storeById.get(row.store_id) ?? 'Store'}</td>
                <td className="px-5 py-4 text-right"><p className="font-black text-slate-900">{rupiah(row.requested_amount)}</p><p className="mt-1 text-xs text-slate-500">{row.requested_payment_method_name_snapshot}</p></td>
                <td className="px-5 py-4"><StatusBadge status={row.status} /></td>
                <td className="px-5 py-4 text-right"><button onClick={() => setDetail(row)} className="inline-flex min-h-10 items-center gap-2 rounded-xl border border-slate-200 px-3 font-black text-slate-700"><Eye className="h-4 w-4" /> Detail</button></td>
              </tr>)}
              {!loading && documents.length === 0 && <tr><td colSpan={6} className="px-5 py-12 text-center text-slate-400">Tidak ada Expense untuk filter ini.</td></tr>}
              {loading && <tr><td colSpan={6} className="px-5 py-12 text-center text-slate-400"><Loader2 className="mx-auto h-5 w-5 animate-spin" /></td></tr>}
            </tbody>
          </table>
        </div>
      </section>

      {detail && (
        <ExpenseDetail
          document={detail}
          store={storeById.get(detail.store_id)}
          cashierSession={detail.cashier_session_id ? sessionById.get(detail.cashier_session_id) : undefined}
          actorById={actorById}
          paymentMethod={paymentMethodById.get(detail.requested_payment_method_id)}
          settlementRequest={submittedSettlementByDocument.get(detail.id)}
          additionalRequests={additionalByDocument.get(detail.id) ?? []}
          canApprove={canApprove}
          canCancel={canCancelAdministrative || detail.created_by === session.user.id}
          canDisburseNonCash={canDisburseNonCash}
          close={() => setDetail(null)}
          act={(type) => setAction({
            type,
            document: detail,
            paymentMethod: paymentMethodById.get(detail.requested_payment_method_id),
          })}
          reviewSettlement={(type, request) => setSettlementAction({
            type,
            request,
            document: detail,
          })}
          reviewAdditional={(type, request) => setAdditionalReviewAction({
            type,
            request,
            document: detail,
          })}
          disburseAdditional={(request) => setAdditionalDisbursementAction({
            request,
            document: detail,
            paymentMethod: paymentMethodById.get(request.payment_method_id),
          })}
          returnNonCash={() => setReturnDocument(detail)}
        />
      )}
      {action && (
        <ExpenseActionDialog
          session={session}
          action={action}
          close={() => setAction(null)}
          complete={async () => {
            const labels = { approve: 'disetujui', reject: 'ditolak', cancel: 'dibatalkan', disburse: 'dibayar' }
            const label = labels[action.type]
            setAction(null)
            setDetail(null)
            await refresh()
            notify(action.type === 'disburse'
              ? `Expense berhasil ${label}. Financial Event masih HOLD sampai Finance G6.`
              : `Expense berhasil ${label}. Belum ada pencairan dana.`)
          }}
        />
      )}
      {settlementAction && (
        <ExpenseSettlementReviewDialog
          session={session}
          action={settlementAction}
          close={() => setSettlementAction(null)}
          complete={async () => {
            setSettlementAction(null)
            setDetail(null)
            await refresh()
            notify('Review biaya aktual berhasil disimpan. Nilai Expense diperbarui hanya jika disetujui.')
          }}
        />
      )}
      {returnDocument && (
        <ExpenseReturnDialog
          session={session}
          document={returnDocument}
          paymentMethod={paymentMethodById.get(returnDocument.requested_payment_method_id)}
          close={() => setReturnDocument(null)}
          complete={async () => {
            setReturnDocument(null)
            setDetail(null)
            await refresh()
            notify('Pengembalian dana non-tunai berhasil dicatat. Kas laci tidak berubah.')
          }}
        />
      )}
      {additionalReviewAction && (
        <ExpenseAdditionalReviewDialog
          session={session}
          action={additionalReviewAction}
          close={() => setAdditionalReviewAction(null)}
          complete={async () => {
            setAdditionalReviewAction(null)
            setDetail(null)
            await refresh()
            notify('Review permintaan dana tambahan berhasil disimpan. Approval belum mencairkan dana.')
          }}
        />
      )}
      {additionalDisbursementAction && (
        <ExpenseAdditionalDisbursementDialog
          session={session}
          action={additionalDisbursementAction}
          close={() => setAdditionalDisbursementAction(null)}
          complete={async () => {
            setAdditionalDisbursementAction(null)
            setDetail(null)
            await refresh()
            notify('Dana tambahan non-tunai berhasil dibayar. Financial Event masih HOLD sampai Finance G6.')
          }}
        />
      )}
    </>
  )
}

function Summary({ label, value, tone }: { label: string; value: string; tone: 'amber' | 'emerald' | 'rose' | 'violet' }) {
  const style = tone === 'amber'
    ? 'border-amber-200 bg-amber-50 text-amber-900'
    : tone === 'emerald'
      ? 'border-emerald-200 bg-emerald-50 text-emerald-900'
      : tone === 'rose'
        ? 'border-rose-200 bg-rose-50 text-rose-900'
        : 'border-violet-200 bg-violet-50 text-violet-900'
  return <div className={`rounded-2xl border p-5 ${style}`}><p className="text-xs font-black uppercase tracking-wider opacity-70">{label}</p><p className="mt-2 text-3xl font-black">{value}</p></div>
}

function StatusBadge({ status }: { status: ExpenseStatus }) {
  const style = status === 'SUBMITTED'
    ? 'bg-amber-100 text-amber-800'
    : status === 'APPROVED'
      ? 'bg-emerald-100 text-emerald-800'
      : status === 'REJECTED'
        ? 'bg-rose-100 text-rose-800'
        : 'bg-slate-200 text-slate-700'
  return <span className={`inline-flex rounded-full px-3 py-1 text-xs font-black ${style}`}>{statusLabel(status)}</span>
}

function Info({ label, value }: { label: string; value: string }) {
  return <div className="rounded-2xl border border-slate-200 p-4"><p className="text-xs font-black uppercase tracking-wider text-slate-400">{label}</p><p className="mt-2 font-black text-slate-800">{value}</p></div>
}

function ExpenseDetail({ document, store, cashierSession, actorById, paymentMethod, settlementRequest, additionalRequests, canApprove, canCancel, canDisburseNonCash, close, act, reviewSettlement, reviewAdditional, disburseAdditional, returnNonCash }: {
  document: ExpenseDocument
  store?: string
  cashierSession?: Lookup
  actorById: Map<string, string>
  paymentMethod?: Lookup
  settlementRequest?: ExpenseSettlementRequest
  additionalRequests: ExpenseAdditionalRequest[]
  canApprove: boolean
  canCancel: boolean
  canDisburseNonCash: boolean
  close: () => void
  act: (type: Action['type']) => void
  reviewSettlement: (type: SettlementAction['type'], request: ExpenseSettlementRequest) => void
  reviewAdditional: (type: AdditionalReviewAction['type'], request: ExpenseAdditionalRequest) => void
  disburseAdditional: (request: ExpenseAdditionalRequest) => void
  returnNonCash: () => void
}) {
  useEscapeClose(close)
  return <div className="fixed inset-0 z-[70] grid place-items-center bg-slate-950/55 p-4 backdrop-blur-sm" onMouseDown={(event) => { if (event.currentTarget === event.target) close() }}>
    <div role="dialog" aria-modal="true" aria-labelledby="expense-detail-title" className="max-h-[94vh] w-full max-w-5xl overflow-y-auto rounded-3xl bg-white p-6 shadow-2xl sm:p-8">
      <div className="flex items-start justify-between gap-4"><div><p className="text-xs font-black uppercase tracking-wider text-violet-600">Detail Expense</p><h2 id="expense-detail-title" className="mt-2 text-2xl font-black text-slate-950">{document.document_no}</h2><p className="mt-2 text-sm text-slate-500">{document.category_name_snapshot} · {store ?? 'Store'}</p></div><button onClick={close} className="rounded-xl bg-slate-100 p-2 text-slate-500" aria-label="Tutup"><X className="h-4 w-4" /></button></div>

      <div className="mt-6 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <Info label="Status" value={statusLabel(document.status)} />
        <Info label="Nominal diajukan" value={rupiah(document.requested_amount)} />
        <Info label="Pembayaran direncanakan" value={document.requested_payment_method_name_snapshot} />
        <Info label="Dibuat oleh" value={actorById.get(document.created_by) ?? 'User'} />
      </div>

      <div className="mt-6 grid gap-5 lg:grid-cols-[1.35fr_0.65fr]">
        <section className="rounded-2xl border border-slate-200 p-5">
          <h3 className="font-black text-slate-900">Keperluan dan tanggung jawab</h3>
          <p className="mt-4 whitespace-pre-wrap text-sm leading-6 text-slate-700">{document.description}</p>
          <dl className="mt-5 grid gap-4 sm:grid-cols-2">
            <DetailItem label="Penanggung jawab" value={`${document.responsible_party_name_snapshot} · ${responsibleLabel(document.responsible_party_type)}`} />
            <DetailItem label="Penerima pembayaran" value={document.recipient ?? '-'} />
            <DetailItem label="Target penyelesaian" value={dateOnly(document.expected_settlement_date)} />
            <DetailItem label="Sesi asal" value={cashierSession ? `${cashierSession.session_code} · ${cashierSession.status}` : '-'} />
            <DetailItem label="Diajukan pada" value={dateTime(document.submitted_at)} />
            <DetailItem label="Approval wajib" value={document.approval_required_snapshot ? 'Ya' : 'Tidak / otomatis'} />
          </dl>
          {document.evidence_url && <a href={document.evidence_url} target="_blank" rel="noreferrer" className="mt-5 inline-flex min-h-10 items-center gap-2 rounded-xl border border-violet-200 px-4 text-sm font-black text-violet-700"><FileCheck2 className="h-4 w-4" /> Buka link bukti</a>}
        </section>

        <aside className="rounded-2xl bg-slate-950 p-5 text-white">
          <p className="text-xs font-black uppercase tracking-wider text-slate-400">Nilai dokumen</p>
          <div className="mt-4 space-y-3 text-sm">
            <div className="flex justify-between gap-4"><span>Diajukan</span><strong>{rupiah(document.requested_amount)}</strong></div>
            <div className="flex justify-between gap-4"><span>Dicairkan</span><strong>{rupiah(document.disbursed_amount)}</strong></div>
            <div className="flex justify-between gap-4"><span>Biaya aktual</span><strong>{rupiah(document.actual_expense_amount)}</strong></div>
            <div className="flex justify-between gap-4"><span>Dikembalikan</span><strong>{rupiah(document.returned_amount)}</strong></div>
            <div className="flex justify-between gap-4 border-t border-slate-700 pt-3"><span>Outstanding</span><strong>{rupiah(document.outstanding_amount)}</strong></div>
          </div>
          <p className="mt-5 rounded-xl bg-slate-800 p-3 text-xs leading-5 text-slate-300">
            {document.status === 'APPROVED'
              ? document.requested_payment_method_type_snapshot === 'CASH'
                ? 'Expense tunai dicairkan dari POS agar Kas Keluar tercatat pada sesi yang benar.'
                : 'Pembayaran non-tunai dikonfirmasi Finance sesuai nominal approved; tidak mengubah kas laci.'
              : 'Nilai dokumen berasal dari event append-only dan tidak dapat diedit setelah pencairan.'}
          </p>
        </aside>
      </div>

      {document.status === 'REJECTED' && <div className="mt-5 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-800"><strong>Alasan ditolak:</strong> {document.rejection_reason}</div>}
      {document.status === 'CANCELED' && <div className="mt-5 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-700"><strong>Alasan dibatalkan:</strong> {document.cancel_reason}</div>}
      {settlementRequest && <div className="mt-5 rounded-2xl border border-amber-200 bg-amber-50 p-5 text-sm text-amber-950">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div><p className="font-black">Biaya aktual menunggu review</p><p className="mt-1">Diajukan {actorById.get(settlementRequest.submitted_by) ?? 'User'} pada {dateTime(settlementRequest.submitted_at)}.</p></div>
          <strong className="text-lg">{rupiah(settlementRequest.actual_expense_amount)}</strong>
        </div>
        {settlementRequest.evidence_url && <a href={settlementRequest.evidence_url} target="_blank" rel="noreferrer" className="mt-3 inline-flex items-center gap-2 font-black text-amber-900 underline"><FileCheck2 className="h-4 w-4" /> Buka bukti aktual</a>}
      </div>}
      {additionalRequests.length > 0 && <section className="mt-5 rounded-2xl border border-violet-200 bg-violet-50 p-5 text-sm text-violet-950">
        <h3 className="font-black">Riwayat permintaan dana tambahan</h3>
        <div className="mt-3 space-y-3">
          {additionalRequests.map((request) => <article key={request.id} className="rounded-xl border border-violet-200 bg-white p-4">
            <div className="flex flex-wrap items-start justify-between gap-3">
              <div><p className="font-black">{request.payment_method_name_snapshot} · {request.status}</p><p className="mt-1 text-xs text-slate-500">Diajukan {actorById.get(request.requested_by) ?? 'User'} pada {dateTime(request.requested_at)}</p></div>
              <strong className="text-lg">{rupiah(request.amount)}</strong>
            </div>
            {request.evidence_url && <a href={request.evidence_url} target="_blank" rel="noreferrer" className="mt-3 inline-flex items-center gap-2 font-black text-violet-700 underline"><FileCheck2 className="h-4 w-4" /> Buka bukti</a>}
            {request.status === 'REJECTED' && request.rejection_reason && <p className="mt-3 rounded-lg bg-rose-50 p-3 text-rose-800"><strong>Alasan:</strong> {request.rejection_reason}</p>}
            {request.status === 'SUBMITTED' && canApprove && <div className="mt-4 flex flex-wrap justify-end gap-2"><button onClick={() => reviewAdditional('REJECT', request)} className="min-h-10 rounded-xl border border-rose-200 px-4 font-black text-rose-700">Tolak tambahan</button><button onClick={() => reviewAdditional('APPROVE', request)} className="min-h-10 rounded-xl bg-emerald-600 px-4 font-black text-white">Setujui tambahan</button></div>}
            {request.status === 'APPROVED' && request.payment_method_type_snapshot === 'CASH' && <p className="mt-4 rounded-xl bg-amber-50 p-3 font-black text-amber-800">Cairkan dari POS / sesi kasir.</p>}
            {request.status === 'APPROVED' && request.payment_method_type_snapshot !== 'CASH' && canDisburseNonCash && <div className="mt-4 flex justify-end"><button onClick={() => disburseAdditional(request)} className="min-h-10 rounded-xl bg-violet-600 px-4 font-black text-white">Bayar dana tambahan</button></div>}
          </article>)}
        </div>
      </section>}

      <div className="mt-6 flex flex-wrap justify-end gap-3">
        <button onClick={close} className="min-h-11 rounded-xl border border-slate-200 px-5 font-black text-slate-600">Tutup</button>
        {['DRAFT', 'SUBMITTED'].includes(document.status) && canCancel && <button onClick={() => act('cancel')} className="inline-flex min-h-11 items-center gap-2 rounded-xl border border-slate-300 px-5 font-black text-slate-700"><Ban className="h-4 w-4" /> Batalkan</button>}
        {document.status === 'SUBMITTED' && canApprove && <>
          <button onClick={() => act('reject')} className="inline-flex min-h-11 items-center gap-2 rounded-xl border border-rose-200 px-5 font-black text-rose-700"><XCircle className="h-4 w-4" /> Tolak</button>
          <button onClick={() => act('approve')} className="inline-flex min-h-11 items-center gap-2 rounded-xl bg-emerald-600 px-5 font-black text-white"><CheckCircle2 className="h-4 w-4" /> Setujui</button>
        </>}
        {document.status === 'APPROVED' && document.requested_payment_method_type_snapshot === 'CASH' && (
          <span className="inline-flex min-h-11 items-center rounded-xl bg-amber-50 px-4 text-sm font-black text-amber-800">
            Cairkan dari POS / sesi kasir
          </span>
        )}
        {document.status === 'APPROVED' && document.requested_payment_method_type_snapshot !== 'CASH' && canDisburseNonCash && (
          <button onClick={() => act('disburse')} disabled={paymentMethod?.is_active === false} className="inline-flex min-h-11 items-center gap-2 rounded-xl bg-violet-600 px-5 font-black text-white disabled:bg-slate-300">
            <FileCheck2 className="h-4 w-4" /> Konfirmasi Pembayaran
          </button>
        )}
        {settlementRequest && canApprove && <>
          <button onClick={() => reviewSettlement('REJECT', settlementRequest)} className="inline-flex min-h-11 items-center gap-2 rounded-xl border border-rose-200 px-5 font-black text-rose-700"><XCircle className="h-4 w-4" /> Tolak aktual</button>
          <button onClick={() => reviewSettlement('APPROVE', settlementRequest)} className="inline-flex min-h-11 items-center gap-2 rounded-xl bg-emerald-600 px-5 font-black text-white"><CheckCircle2 className="h-4 w-4" /> Setujui aktual</button>
        </>}
        {['DISBURSED', 'PARTIALLY_SETTLED'].includes(document.status) && Number(document.outstanding_amount) > 0 && document.requested_payment_method_type_snapshot !== 'CASH' && canDisburseNonCash && (
          <button onClick={returnNonCash} className="inline-flex min-h-11 items-center gap-2 rounded-xl bg-sky-600 px-5 font-black text-white"><RotateCcw className="h-4 w-4" /> Terima pengembalian non-tunai</button>
        )}
      </div>
    </div>
  </div>
}

function DetailItem({ label, value }: { label: string; value: string }) {
  return <div><dt className="text-xs font-black uppercase tracking-wider text-slate-400">{label}</dt><dd className="mt-1 text-sm font-bold text-slate-800">{value}</dd></div>
}

function ExpenseActionDialog({ session, action, close, complete }: {
  session: Session
  action: Action
  close: () => void
  complete: () => Promise<void>
}) {
  const [confirmed, setConfirmed] = useState(false)
  const [reason, setReason] = useState('')
  const [evidenceUrl, setEvidenceUrl] = useState('')
  const [idempotencyKey] = useState(() => crypto.randomUUID())
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')
  useEscapeClose(saving ? () => undefined : close)

  async function run() {
    setSaving(true)
    setError('')
    try {
      const isDisburse = action.type === 'disburse'
      const review = action.type === 'approve' || action.type === 'reject'
      const response = await fetch(
        `/api/finance/expenses/${action.document.id}/${isDisburse ? 'disburse' : review ? 'review' : 'cancel'}`,
        {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', ...authHeaders(session) },
          body: JSON.stringify({
            masterVersion: Number(action.document.master_version),
            ...(isDisburse
              ? {
                  evidenceUrl: evidenceUrl.trim() || null,
                  idempotencyKey,
                }
              : review
              ? {
                  approve: action.type === 'approve',
                  ...(action.type === 'reject' ? { reason } : {}),
                }
              : { reason }),
          }),
        },
      )
      const result = (await response.json()) as { error?: string }
      if (!response.ok) throw new Error(friendlyError(result.error))
      await complete()
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Tindakan Expense gagal.')
    } finally {
      setSaving(false)
    }
  }

  const isApprove = action.type === 'approve'
  const isDisburse = action.type === 'disburse'
  const evidenceRequired = action.paymentMethod?.proof_mode === 'REQUIRED'
  const evidenceValid = !evidenceUrl.trim() || /^https:\/\//i.test(evidenceUrl.trim())
  const valid = confirmed && (
    isApprove ||
    (isDisburse && evidenceValid && (!evidenceRequired || Boolean(evidenceUrl.trim()))) ||
    reason.trim().length >= 3
  )
  const title = isDisburse
    ? 'Konfirmasi pembayaran Expense?'
    : isApprove
    ? 'Setujui pengajuan Expense?'
    : action.type === 'reject'
      ? 'Tolak pengajuan Expense?'
      : 'Batalkan Expense?'

  return <div className="fixed inset-0 z-[80] grid place-items-center bg-slate-950/60 p-4 backdrop-blur-sm" onMouseDown={(event) => { if (event.currentTarget === event.target && !saving) close() }}>
    <div role="dialog" aria-modal="true" aria-labelledby="expense-action-title" className="w-full max-w-xl rounded-3xl bg-white p-7 shadow-2xl">
      <div className="flex items-start justify-between gap-4"><div><p className="text-xs font-black uppercase tracking-wider text-violet-600">Konfirmasi Expense</p><h2 id="expense-action-title" className="mt-2 text-xl font-black text-slate-950">{title}</h2><p className="mt-2 text-sm text-slate-500">{action.document.document_no} · {rupiah(action.document.requested_amount)}</p></div><button onClick={close} disabled={saving} className="rounded-xl bg-slate-100 p-2 text-slate-500" aria-label="Tutup"><X className="h-4 w-4" /></button></div>

      {isApprove ? <div className="mt-5 rounded-2xl border border-emerald-200 bg-emerald-50 p-4 text-sm text-emerald-900"><p className="font-black">Persetujuan belum mengeluarkan uang.</p><p className="mt-1">Pencairan Cash/Transfer dilakukan setelah approval tersimpan.</p></div> : isDisburse ? <div className="mt-5 space-y-4"><div className="rounded-2xl border border-violet-200 bg-violet-50 p-4 text-sm text-violet-950"><p className="font-black">Nominal dibayar: {rupiah(action.document.requested_amount)}</p><p className="mt-1">Metode: {action.document.requested_payment_method_name_snapshot}. Nilai dan metode berasal dari dokumen approved dan tidak dapat diubah.</p><p className="mt-1">Pembayaran non-tunai tidak mengubah kas laci.</p></div><label className="block text-sm font-black text-slate-700">Link bukti pembayaran {evidenceRequired ? '(wajib)' : '(opsional)'}<input type="url" value={evidenceUrl} onChange={(event) => setEvidenceUrl(event.target.value)} maxLength={2048} placeholder="https://drive.google.com/â€¦" className="mt-2 min-h-11 w-full rounded-xl border border-slate-200 px-3 font-normal outline-none focus:border-violet-500" /></label></div> : <label className="mt-5 block text-sm font-black text-slate-700">{action.type === 'reject' ? 'Alasan penolakan' : 'Alasan pembatalan'}<textarea value={reason} onChange={(event) => setReason(event.target.value)} maxLength={500} rows={4} placeholder="Tuliskan alasan yang dapat dipahami pembuat pengajuan" className="mt-2 w-full rounded-xl border border-slate-200 p-3 font-normal outline-none focus:border-rose-400" /></label>}

      <label className="mt-5 flex cursor-pointer items-start gap-3 rounded-2xl border border-slate-200 p-4 text-sm font-semibold text-slate-700"><input type="checkbox" checked={confirmed} onChange={(event) => setConfirmed(event.target.checked)} className="mt-0.5 h-4 w-4 accent-violet-600" /><span>{isDisburse ? 'Saya mengonfirmasi pembayaran sudah benar-benar dieksekusi sesuai nominal dan metode di atas.' : 'Saya sudah memeriksa kategori, nominal, metode pembayaran, penanggung jawab, keperluan, dan bukti yang tersedia.'}</span></label>
      {error && <p className="mt-4 rounded-xl bg-rose-50 p-3 text-sm font-semibold text-rose-700">{error}</p>}
      <div className="mt-6 flex justify-end gap-3"><button onClick={close} disabled={saving} className="min-h-11 rounded-xl border border-slate-200 px-5 font-black text-slate-600">Kembali</button><button onClick={run} disabled={!valid || saving} className={`inline-flex min-h-11 items-center gap-2 rounded-xl px-5 font-black text-white disabled:cursor-not-allowed disabled:bg-slate-300 ${isApprove ? 'bg-emerald-600' : isDisburse ? 'bg-violet-600' : 'bg-rose-600'}`}>{saving ? <Loader2 className="h-4 w-4 animate-spin" /> : isApprove ? <CheckCircle2 className="h-4 w-4" /> : isDisburse ? <FileCheck2 className="h-4 w-4" /> : <XCircle className="h-4 w-4" />}{isApprove ? 'Setujui Expense' : isDisburse ? 'Konfirmasi Pembayaran' : action.type === 'reject' ? 'Tolak Expense' : 'Batalkan Expense'}</button></div>
    </div>
  </div>
}

function ExpenseSettlementReviewDialog({ session, action, close, complete }: {
  session: Session
  action: SettlementAction
  close: () => void
  complete: () => Promise<void>
}) {
  const [reason, setReason] = useState('')
  const [confirmed, setConfirmed] = useState(false)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')
  useEscapeClose(saving ? () => undefined : close)

  async function run() {
    setSaving(true)
    setError('')
    try {
      const response = await fetch(
        `/api/finance/expense-settlements/${action.request.id}/review`,
        {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', ...authHeaders(session) },
          body: JSON.stringify({
            masterVersion: Number(action.request.master_version),
            action: action.type,
            ...(action.type === 'REJECT' ? { reason } : {}),
          }),
        },
      )
      const result = (await response.json()) as { error?: string }
      if (!response.ok) throw new Error(friendlyError(result.error))
      await complete()
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Review biaya aktual gagal.')
    } finally {
      setSaving(false)
    }
  }

  const reject = action.type === 'REJECT'
  const valid = confirmed && (!reject || reason.trim().length >= 3)
  return <div className="fixed inset-0 z-[80] grid place-items-center bg-slate-950/60 p-4 backdrop-blur-sm" onMouseDown={(event) => { if (event.currentTarget === event.target && !saving) close() }}>
    <div role="dialog" aria-modal="true" aria-labelledby="settlement-review-title" className="w-full max-w-xl rounded-3xl bg-white p-7 shadow-2xl">
      <div className="flex items-start justify-between gap-4"><div><p className="text-xs font-black uppercase tracking-wider text-violet-600">Review biaya aktual</p><h2 id="settlement-review-title" className="mt-2 text-xl font-black text-slate-950">{reject ? 'Tolak biaya aktual?' : 'Setujui biaya aktual?'}</h2><p className="mt-2 text-sm text-slate-500">{action.document.document_no} · {rupiah(action.request.actual_expense_amount)}</p></div><button onClick={close} disabled={saving} className="rounded-xl bg-slate-100 p-2 text-slate-500" aria-label="Tutup"><X className="h-4 w-4" /></button></div>
      <div className="mt-5 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-700"><p className="font-black">Outstanding saat ini: {rupiah(action.document.outstanding_amount)}</p><p className="mt-1">Approval mengakui biaya aktual dan mengurangi outstanding. Penolakan tidak mengubah nilai dokumen.</p></div>
      {action.request.evidence_url && <a href={action.request.evidence_url} target="_blank" rel="noreferrer" className="mt-4 inline-flex items-center gap-2 font-black text-violet-700 underline"><FileCheck2 className="h-4 w-4" /> Buka bukti aktual</a>}
      {reject && <label className="mt-5 block text-sm font-black text-slate-700">Alasan penolakan<textarea value={reason} onChange={(event) => setReason(event.target.value)} maxLength={500} rows={4} className="mt-2 w-full rounded-xl border border-slate-200 p-3 font-normal outline-none focus:border-rose-400" /></label>}
      <label className="mt-5 flex cursor-pointer items-start gap-3 rounded-2xl border border-slate-200 p-4 text-sm font-semibold text-slate-700"><input type="checkbox" checked={confirmed} onChange={(event) => setConfirmed(event.target.checked)} className="mt-0.5 h-4 w-4 accent-violet-600" /><span>Saya sudah memeriksa nominal, outstanding, dan bukti biaya aktual.</span></label>
      {error && <p className="mt-4 rounded-xl bg-rose-50 p-3 text-sm font-semibold text-rose-700">{error}</p>}
      <div className="mt-6 flex justify-end gap-3"><button onClick={close} disabled={saving} className="min-h-11 rounded-xl border border-slate-200 px-5 font-black text-slate-600">Kembali</button><button onClick={run} disabled={!valid || saving} className={`inline-flex min-h-11 items-center gap-2 rounded-xl px-5 font-black text-white disabled:bg-slate-300 ${reject ? 'bg-rose-600' : 'bg-emerald-600'}`}>{saving && <Loader2 className="h-4 w-4 animate-spin" />}{reject ? 'Tolak aktual' : 'Setujui aktual'}</button></div>
    </div>
  </div>
}

function ExpenseAdditionalReviewDialog({ session, action, close, complete }: {
  session: Session
  action: AdditionalReviewAction
  close: () => void
  complete: () => Promise<void>
}) {
  const [reason, setReason] = useState('')
  const [confirmed, setConfirmed] = useState(false)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')
  useEscapeClose(saving ? () => undefined : close)
  const reject = action.type === 'REJECT'
  const valid = confirmed && (!reject || reason.trim().length >= 3)

  async function run() {
    setSaving(true)
    setError('')
    try {
      const response = await fetch(
        `/api/finance/expense-additional-requests/${action.request.id}/review`,
        {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', ...authHeaders(session) },
          body: JSON.stringify({
            masterVersion: Number(action.request.master_version),
            action: action.type,
            ...(reject ? { reason } : {}),
          }),
        },
      )
      const result = (await response.json()) as { error?: string }
      if (!response.ok) throw new Error(friendlyError(result.error))
      await complete()
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Review dana tambahan gagal.')
    } finally {
      setSaving(false)
    }
  }

  return <div className="fixed inset-0 z-[80] grid place-items-center bg-slate-950/60 p-4 backdrop-blur-sm" onMouseDown={(event) => { if (event.currentTarget === event.target && !saving) close() }}>
    <div role="dialog" aria-modal="true" aria-labelledby="additional-review-title" className="w-full max-w-xl rounded-3xl bg-white p-7 shadow-2xl">
      <div className="flex items-start justify-between gap-4"><div><p className="text-xs font-black uppercase tracking-wider text-violet-600">Review dana tambahan</p><h2 id="additional-review-title" className="mt-2 text-xl font-black text-slate-950">{reject ? 'Tolak permintaan tambahan?' : 'Setujui permintaan tambahan?'}</h2><p className="mt-2 text-sm text-slate-500">{action.document.document_no} · {rupiah(action.request.amount)}</p></div><button onClick={close} disabled={saving} className="rounded-xl bg-slate-100 p-2 text-slate-500" aria-label="Tutup"><X className="h-4 w-4" /></button></div>
      <div className="mt-5 rounded-2xl border border-violet-200 bg-violet-50 p-4 text-sm text-violet-950"><p className="font-black">Metode: {action.request.payment_method_name_snapshot}</p><p className="mt-1">Approval hanya mengizinkan pencairan. Belum ada uang keluar dan nominal tidak dapat diubah saat dibayar.</p></div>
      {action.request.evidence_url && <a href={action.request.evidence_url} target="_blank" rel="noreferrer" className="mt-4 inline-flex items-center gap-2 font-black text-violet-700 underline"><FileCheck2 className="h-4 w-4" /> Buka bukti permintaan</a>}
      {reject && <label className="mt-5 block text-sm font-black text-slate-700">Alasan penolakan<textarea value={reason} onChange={(event) => setReason(event.target.value)} maxLength={500} rows={4} className="mt-2 w-full rounded-xl border border-slate-200 p-3 font-normal outline-none focus:border-rose-400" /></label>}
      <label className="mt-5 flex cursor-pointer items-start gap-3 rounded-2xl border border-slate-200 p-4 text-sm font-semibold text-slate-700"><input type="checkbox" checked={confirmed} onChange={(event) => setConfirmed(event.target.checked)} className="mt-0.5 h-4 w-4 accent-violet-600" /><span>Saya sudah memeriksa nominal, metode pembayaran, dan bukti permintaan tambahan.</span></label>
      {error && <p className="mt-4 rounded-xl bg-rose-50 p-3 text-sm font-semibold text-rose-700">{error}</p>}
      <div className="mt-6 flex justify-end gap-3"><button onClick={close} disabled={saving} className="min-h-11 rounded-xl border border-slate-200 px-5 font-black text-slate-600">Kembali</button><button onClick={run} disabled={!valid || saving} className={`inline-flex min-h-11 items-center gap-2 rounded-xl px-5 font-black text-white disabled:bg-slate-300 ${reject ? 'bg-rose-600' : 'bg-emerald-600'}`}>{saving && <Loader2 className="h-4 w-4 animate-spin" />}{reject ? 'Tolak tambahan' : 'Setujui tambahan'}</button></div>
    </div>
  </div>
}

function ExpenseAdditionalDisbursementDialog({ session, action, close, complete }: {
  session: Session
  action: AdditionalDisbursementAction
  close: () => void
  complete: () => Promise<void>
}) {
  const [evidenceUrl, setEvidenceUrl] = useState(action.request.evidence_url ?? '')
  const [confirmed, setConfirmed] = useState(false)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')
  const [idempotencyKey] = useState(() => crypto.randomUUID())
  useEscapeClose(saving ? () => undefined : close)
  const evidenceRequired = action.paymentMethod?.proof_mode === 'REQUIRED'
  const evidenceValid = !evidenceUrl.trim() || /^https:\/\//i.test(evidenceUrl.trim())
  const valid = confirmed && evidenceValid && (!evidenceRequired || Boolean(evidenceUrl.trim()))

  async function run() {
    setSaving(true)
    setError('')
    try {
      const response = await fetch(
        `/api/finance/expense-additional-requests/${action.request.id}/disburse`,
        {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', ...authHeaders(session) },
          body: JSON.stringify({
            requestMasterVersion: Number(action.request.master_version),
            documentMasterVersion: Number(action.document.master_version),
            evidenceUrl: evidenceUrl.trim() || null,
            idempotencyKey,
          }),
        },
      )
      const result = (await response.json()) as { error?: string }
      if (!response.ok) throw new Error(friendlyError(result.error))
      await complete()
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Pembayaran dana tambahan gagal.')
    } finally {
      setSaving(false)
    }
  }

  return <div className="fixed inset-0 z-[80] grid place-items-center bg-slate-950/60 p-4 backdrop-blur-sm" onMouseDown={(event) => { if (event.currentTarget === event.target && !saving) close() }}>
    <div role="dialog" aria-modal="true" aria-labelledby="additional-disbursement-title" className="w-full max-w-xl rounded-3xl bg-white p-7 shadow-2xl">
      <div className="flex items-start justify-between gap-4"><div><p className="text-xs font-black uppercase tracking-wider text-violet-600">Pembayaran dana tambahan</p><h2 id="additional-disbursement-title" className="mt-2 text-xl font-black text-slate-950">Konfirmasi pembayaran non-tunai?</h2><p className="mt-2 text-sm text-slate-500">{action.document.document_no} · {rupiah(action.request.amount)}</p></div><button onClick={close} disabled={saving} className="rounded-xl bg-slate-100 p-2 text-slate-500" aria-label="Tutup"><X className="h-4 w-4" /></button></div>
      <div className="mt-5 rounded-2xl border border-violet-200 bg-violet-50 p-4 text-sm text-violet-950"><p className="font-black">Metode: {action.request.payment_method_name_snapshot}</p><p className="mt-1">Nominal berasal dari permintaan approved dan tidak dapat diedit. Pembayaran ini tidak mengubah kas laci.</p></div>
      <label className="mt-5 block text-sm font-black text-slate-700">Link bukti pembayaran {evidenceRequired ? '(wajib)' : '(opsional)'}<input type="url" value={evidenceUrl} onChange={(event) => setEvidenceUrl(event.target.value)} maxLength={2048} placeholder="https://drive.google.com/…" className="mt-2 min-h-11 w-full rounded-xl border border-slate-200 px-3 font-normal outline-none focus:border-violet-500" /></label>
      <label className="mt-5 flex cursor-pointer items-start gap-3 rounded-2xl border border-slate-200 p-4 text-sm font-semibold text-slate-700"><input type="checkbox" checked={confirmed} onChange={(event) => setConfirmed(event.target.checked)} className="mt-0.5 h-4 w-4 accent-violet-600" /><span>Saya mengonfirmasi dana benar-benar sudah dibayar sesuai nominal dan metode di atas.</span></label>
      {error && <p className="mt-4 rounded-xl bg-rose-50 p-3 text-sm font-semibold text-rose-700">{error}</p>}
      <div className="mt-6 flex justify-end gap-3"><button onClick={close} disabled={saving} className="min-h-11 rounded-xl border border-slate-200 px-5 font-black text-slate-600">Kembali</button><button onClick={run} disabled={!valid || saving} className="inline-flex min-h-11 items-center gap-2 rounded-xl bg-violet-600 px-5 font-black text-white disabled:bg-slate-300">{saving && <Loader2 className="h-4 w-4 animate-spin" />}Konfirmasi Pembayaran</button></div>
    </div>
  </div>
}

function ExpenseReturnDialog({ session, document, paymentMethod, close, complete }: {
  session: Session
  document: ExpenseDocument
  paymentMethod?: Lookup
  close: () => void
  complete: () => Promise<void>
}) {
  const [amount, setAmount] = useState(String(Number(document.outstanding_amount)))
  const [evidenceUrl, setEvidenceUrl] = useState('')
  const [confirmed, setConfirmed] = useState(false)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')
  const [idempotencyKey] = useState(() => crypto.randomUUID())
  useEscapeClose(saving ? () => undefined : close)
  const numericAmount = Number(amount)
  const evidenceRequired = paymentMethod?.proof_mode === 'REQUIRED'
  const evidenceValid = !evidenceUrl.trim() || /^https:\/\//i.test(evidenceUrl.trim())
  const valid = confirmed && Number.isFinite(numericAmount) && numericAmount > 0 && numericAmount <= Number(document.outstanding_amount) && evidenceValid && (!evidenceRequired || Boolean(evidenceUrl.trim()))

  async function run() {
    setSaving(true)
    setError('')
    try {
      const response = await fetch(`/api/finance/expenses/${document.id}/return`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', ...authHeaders(session) },
        body: JSON.stringify({
          masterVersion: Number(document.master_version),
          amount: numericAmount,
          paymentMethodId: document.requested_payment_method_id,
          evidenceUrl: evidenceUrl.trim() || null,
          idempotencyKey,
        }),
      })
      const result = (await response.json()) as { error?: string }
      if (!response.ok) throw new Error(friendlyError(result.error))
      await complete()
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Pengembalian dana gagal.')
    } finally {
      setSaving(false)
    }
  }

  return <div className="fixed inset-0 z-[80] grid place-items-center bg-slate-950/60 p-4 backdrop-blur-sm" onMouseDown={(event) => { if (event.currentTarget === event.target && !saving) close() }}>
    <div role="dialog" aria-modal="true" aria-labelledby="expense-return-title" className="w-full max-w-xl rounded-3xl bg-white p-7 shadow-2xl">
      <div className="flex items-start justify-between gap-4"><div><p className="text-xs font-black uppercase tracking-wider text-sky-600">Pengembalian non-tunai</p><h2 id="expense-return-title" className="mt-2 text-xl font-black text-slate-950">Terima sisa dana Expense</h2><p className="mt-2 text-sm text-slate-500">{document.document_no} · outstanding {rupiah(document.outstanding_amount)}</p></div><button onClick={close} disabled={saving} className="rounded-xl bg-slate-100 p-2 text-slate-500" aria-label="Tutup"><X className="h-4 w-4" /></button></div>
      <div className="mt-5 space-y-4"><label className="block text-sm font-black text-slate-700">Nominal diterima<input type="number" min="0.01" max={Number(document.outstanding_amount)} step="any" value={amount} onChange={(event) => setAmount(event.target.value)} className="mt-2 min-h-11 w-full rounded-xl border border-slate-200 px-3 font-normal outline-none focus:border-sky-500" /></label><div className="rounded-2xl border border-sky-200 bg-sky-50 p-4 text-sm text-sky-950"><p className="font-black">Metode: {document.requested_payment_method_name_snapshot}</p><p className="mt-1">Dana non-tunai diterima melalui rute akun metode ini dan tidak mengubah kas laci.</p></div><label className="block text-sm font-black text-slate-700">Link bukti {evidenceRequired ? '(wajib)' : '(opsional)'}<input type="url" value={evidenceUrl} onChange={(event) => setEvidenceUrl(event.target.value)} maxLength={2048} placeholder="https://drive.google.com/…" className="mt-2 min-h-11 w-full rounded-xl border border-slate-200 px-3 font-normal outline-none focus:border-sky-500" /></label></div>
      <label className="mt-5 flex cursor-pointer items-start gap-3 rounded-2xl border border-slate-200 p-4 text-sm font-semibold text-slate-700"><input type="checkbox" checked={confirmed} onChange={(event) => setConfirmed(event.target.checked)} className="mt-0.5 h-4 w-4 accent-sky-600" /><span>Saya mengonfirmasi dana sudah benar-benar diterima melalui metode di atas.</span></label>
      {error && <p className="mt-4 rounded-xl bg-rose-50 p-3 text-sm font-semibold text-rose-700">{error}</p>}
      <div className="mt-6 flex justify-end gap-3"><button onClick={close} disabled={saving} className="min-h-11 rounded-xl border border-slate-200 px-5 font-black text-slate-600">Kembali</button><button onClick={run} disabled={!valid || saving} className="inline-flex min-h-11 items-center gap-2 rounded-xl bg-sky-600 px-5 font-black text-white disabled:bg-slate-300">{saving && <Loader2 className="h-4 w-4 animate-spin" />}Terima dana</button></div>
    </div>
  </div>
}
