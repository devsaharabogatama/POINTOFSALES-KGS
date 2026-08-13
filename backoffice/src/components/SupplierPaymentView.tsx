'use client'

import React, { useEffect, useState } from 'react'
import {
  AlertCircle,
  Banknote,
  CheckCircle2,
  Clock,
  CreditCard,
  DollarSign,
  FileCheck,
  FileSpreadsheet,
  FileText,
  Filter,
  Plus,
  RefreshCw,
  Search,
  ShieldAlert,
  Trash2,
  X,
  XCircle,
} from 'lucide-react'
import type { Session } from '@supabase/supabase-js'

function authHeaders(session: Session | null): HeadersInit {
  if (!session?.access_token) return {}
  return {
    Authorization: `Bearer ${session.access_token}`,
  }
}

type PaymentDocument = {
  id: string
  company_id: string
  payment_no: string
  supplier_id: string
  payment_date: string
  payment_method: 'CASH' | 'BANK_TRANSFER' | 'CHEQUE'
  source_account_id: string | null
  supplier_bank_name: string | null
  supplier_bank_account_no: string | null
  supplier_bank_account_holder: string | null
  reference_no: string | null
  total_amount: number
  notes: string | null
  evidence_url: string | null
  status: 'DRAFT' | 'VALIDATED' | 'CANCELED'
  validation_idempotency_key: string | null
  financial_event_id: string | null
  created_by: string
  validated_by: string | null
  validated_at: string | null
  canceled_by: string | null
  canceled_at: string | null
  cancel_reason: string | null
  master_version: number
  created_at: string
  updated_at: string
}

type PaymentAllocation = {
  id: string
  company_id: string
  document_id: string
  invoice_id: string
  client_allocation_key: string
  allocated_amount: number
  created_at: string
}

type ValidatedInvoice = {
  id: string
  invoice_no: string
  supplier_id: string
  supplier_invoice_no: string
  invoice_date: string
  due_date: string | null
  grand_total: number
  status: string
  matching_status: string
  created_at: string
  paid_amount: number
  remaining_balance: number
}

type Supplier = {
  id: string
  supplier_code: string
  supplier_name: string
  is_active: boolean
}

type Account = {
  id: string
  account_code: string
  account_name: string
  account_type: string
  is_active: boolean
}

type Profile = {
  id: string
  full_name: string | null
  username: string
}

function formatRupiah(num: number): string {
  return new Intl.NumberFormat('id-ID', {
    style: 'currency',
    currency: 'IDR',
    maximumFractionDigits: 0,
  }).format(num)
}

function formatDate(dateStr: string | null): string {
  if (!dateStr) return '-'
  try {
    return new Date(dateStr).toLocaleDateString('id-ID', {
      day: 'numeric',
      month: 'short',
      year: 'numeric',
    })
  } catch {
    return dateStr
  }
}

export default function SupplierPaymentView({
  session,
  canCreate,
  canEdit,
  canPost,
}: {
  session: Session | null
  canCreate: boolean
  canEdit: boolean
  canPost: boolean
}) {
  const [activeTab, setActiveTab] = useState<'list' | 'form'>('list')
  const [loading, setLoading] = useState(true)
  const [submitting, setSubmitting] = useState(false)
  const [errorMsg, setErrorMsg] = useState<string | null>(null)
  const [successMsg, setSuccessMsg] = useState<string | null>(null)

  // Data state
  const [documents, setDocuments] = useState<PaymentDocument[]>([])
  const [allocations, setAllocations] = useState<PaymentAllocation[]>([])
  const [validatedInvoices, setValidatedInvoices] = useState<ValidatedInvoice[]>([])
  const [suppliers, setSuppliers] = useState<Supplier[]>([])
  const [accounts, setAccounts] = useState<Account[]>([])
  const [profiles, setProfiles] = useState<Profile[]>([])

  // Filters & Search
  const [searchQuery, setSearchQuery] = useState('')
  const [statusFilter, setStatusFilter] = useState<'ALL' | 'DRAFT' | 'VALIDATED' | 'CANCELED'>('ALL')
  const [supplierFilter, setSupplierFilter] = useState<string>('ALL')

  // Form State
  const [draftDocId, setDraftDocId] = useState<string | null>(null)
  const [draftMasterVersion, setDraftMasterVersion] = useState<number | null>(null)
  const [selectedSupplierId, setSelectedSupplierId] = useState<string>('')
  const [paymentDate, setPaymentDate] = useState<string>(new Date().toISOString().split('T')[0])
  const [paymentMethod, setPaymentMethod] = useState<'CASH' | 'BANK_TRANSFER' | 'CHEQUE'>('BANK_TRANSFER')
  const [sourceAccountId, setSourceAccountId] = useState<string>('')
  const [supplierBankName, setSupplierBankName] = useState('')
  const [supplierBankAccountNo, setSupplierBankAccountNo] = useState('')
  const [supplierBankAccountHolder, setSupplierBankAccountHolder] = useState('')
  const [referenceNo, setReferenceNo] = useState('')
  const [evidenceUrl, setEvidenceUrl] = useState('')
  const [notes, setNotes] = useState('')

  // Form Invoice Allocations: Record<invoiceId, { clientAllocationKey: string, allocatedAmount: number }>
  const [formAllocations, setFormAllocations] = useState<Record<string, { clientAllocationKey: string; allocatedAmount: number }>>({})

  // Modals
  const [selectedDoc, setSelectedDoc] = useState<PaymentDocument | null>(null)
  const [validateModalDoc, setValidateModalDoc] = useState<PaymentDocument | null>(null)
  const [cancelModalDoc, setCancelModalDoc] = useState<PaymentDocument | null>(null)
  const [cancelReason, setCancelReason] = useState('')

  const fetchData = React.useCallback(async () => {
    setLoading(true)
    setErrorMsg(null)
    try {
      const res = await fetch('/api/finance/supplier-payments', {
        headers: authHeaders(session),
      })
      const json = await res.json()
      if (!res.ok) throw new Error(json.error?.message || 'Gagal memuat data pembayaran supplier')
      setDocuments(json.data.documents || [])
      setAllocations(json.data.allocations || [])
      setValidatedInvoices(json.data.validatedInvoices || [])
      setSuppliers(json.data.suppliers || [])
      setAccounts(json.data.accounts || [])
      setProfiles(json.data.profiles || [])
    } catch (err: unknown) {
      setErrorMsg((err as Error).message || 'Terjadi kesalahan sistem')
    } finally {
      setLoading(false)
    }
  }, [session])

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    void fetchData()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  // Profile lookup
  const getProfileName = (id: string | null) => {
    if (!id) return '-'
    const p = profiles.find((item) => item.id === id)
    return p ? p.full_name || p.username : id.slice(0, 8)
  }

  // Supplier lookup
  const getSupplierName = (id: string) => {
    const s = suppliers.find((item) => item.id === id)
    return s ? `${s.supplier_name} (${s.supplier_code})` : id.slice(0, 8)
  }

  // Account lookup
  const getAccountName = (id: string | null) => {
    if (!id) return '-'
    const a = accounts.find((item) => item.id === id)
    return a ? `${a.account_code} - ${a.account_name}` : id.slice(0, 8)
  }

  // Handle supplier select in Form
  const handleSupplierChange = (supId: string) => {
    setSelectedSupplierId(supId)
    setFormAllocations({})
  }

  // Handle allocation amount change in Form
  const handleAllocationChange = (invoiceId: string, amountStr: string, maxBalance: number) => {
    const num = Number(amountStr)
    if (isNaN(num) || num <= 0) {
      setFormAllocations((prev) => {
        const copy = { ...prev }
        delete copy[invoiceId]
        return copy
      })
      return
    }

    const validAmount = Math.min(num, maxBalance)
    setFormAllocations((prev) => ({
      ...prev,
      [invoiceId]: {
        clientAllocationKey: prev[invoiceId]?.clientAllocationKey || crypto.randomUUID(),
        allocatedAmount: validAmount,
      },
    }))
  }

  // Calculate total allocated in Form
  const totalFormAllocated = Object.values(formAllocations).reduce(
    (acc, item) => acc + (item.allocatedAmount || 0),
    0,
  )

  // Reset Form
  const resetForm = () => {
    setDraftDocId(null)
    setDraftMasterVersion(null)
    setSelectedSupplierId('')
    setPaymentDate(new Date().toISOString().split('T')[0])
    setPaymentMethod('BANK_TRANSFER')
    setSourceAccountId('')
    setSupplierBankName('')
    setSupplierBankAccountNo('')
    setSupplierBankAccountHolder('')
    setReferenceNo('')
    setEvidenceUrl('')
    setNotes('')
    setFormAllocations({})
  }

  // Load Document into Form for Editing Draft
  const handleEditDraft = (doc: PaymentDocument) => {
    setDraftDocId(doc.id)
    setDraftMasterVersion(doc.master_version)
    setSelectedSupplierId(doc.supplier_id)
    setPaymentDate(doc.payment_date)
    setPaymentMethod(doc.payment_method)
    setSourceAccountId(doc.source_account_id || '')
    setSupplierBankName(doc.supplier_bank_name || '')
    setSupplierBankAccountNo(doc.supplier_bank_account_no || '')
    setSupplierBankAccountHolder(doc.supplier_bank_account_holder || '')
    setReferenceNo(doc.reference_no || '')
    setEvidenceUrl(doc.evidence_url || '')
    setNotes(doc.notes || '')

    // Load allocations for this document
    const docAllocs = allocations.filter((a) => a.document_id === doc.id)
    const allocMap: Record<string, { clientAllocationKey: string; allocatedAmount: number }> = {}
    docAllocs.forEach((a) => {
      allocMap[a.invoice_id] = {
        clientAllocationKey: a.client_allocation_key || crypto.randomUUID(),
        allocatedAmount: Number(a.allocated_amount),
      }
    })
    setFormAllocations(allocMap)
    setActiveTab('form')
  }

  // Submit Save Draft
  const handleSaveDraftSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    setErrorMsg(null)
    setSuccessMsg(null)

    if (!selectedSupplierId) {
      setErrorMsg('Pilih Supplier terlebih dahulu')
      return
    }

    const allocList = Object.entries(formAllocations).map(([invoiceId, item]) => ({
      clientAllocationKey: item.clientAllocationKey,
      invoiceId,
      allocatedAmount: item.allocatedAmount,
    }))

    if (allocList.length === 0) {
      setErrorMsg('Pilih dan alokasikan setidaknya 1 Faktur Supplier VALIDATED')
      return
    }

    if (evidenceUrl && !evidenceUrl.toLowerCase().startsWith('https://')) {
      setErrorMsg('URL Bukti Pembayaran wajib diawali dengan https://')
      return
    }

    setSubmitting(true)
    try {
      const payload = {
        action: 'SAVE_DRAFT',
        documentId: draftDocId,
        masterVersion: draftMasterVersion,
        supplierId: selectedSupplierId,
        paymentDate,
        paymentMethod,
        sourceAccountId: sourceAccountId || null,
        supplierBankName: supplierBankName.trim() || null,
        supplierBankAccountNo: supplierBankAccountNo.trim() || null,
        supplierBankAccountHolder: supplierBankAccountHolder.trim() || null,
        referenceNo: referenceNo.trim() || null,
        notes: notes.trim() || null,
        evidenceUrl: evidenceUrl.trim() || null,
        allocations: allocList,
      }

      const res = await fetch('/api/finance/supplier-payments', {
        method: 'POST',
        headers: { ...authHeaders(session), 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      })
      const json = await res.json()
      if (!res.ok) throw new Error(json.error?.message || 'Gagal menyimpan draf pembayaran')

      setSuccessMsg('Draf Pembayaran Supplier berhasil disimpan')
      resetForm()
      await fetchData()
      setActiveTab('list')
    } catch (err: unknown) {
      setErrorMsg((err as Error).message || 'Terjadi kesalahan saat menyimpan draf')
    } finally {
      setSubmitting(false)
    }
  }

  // Submit Validate Payment
  const handleValidateSubmit = async () => {
    if (!validateModalDoc) return
    setErrorMsg(null)
    setSuccessMsg(null)
    setSubmitting(true)

    try {
      const payload = {
        action: 'VALIDATE',
        documentId: validateModalDoc.id,
        masterVersion: validateModalDoc.master_version,
        idempotencyKey: crypto.randomUUID(),
      }

      const res = await fetch('/api/finance/supplier-payments', {
        method: 'POST',
        headers: { ...authHeaders(session), 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      })
      const json = await res.json()
      if (!res.ok) throw new Error(json.error?.message || 'Gagal memvalidasi pembayaran supplier')

      setSuccessMsg(`Pembayaran Supplier ${validateModalDoc.payment_no} berhasil divalidasi (VALIDATED)`)
      setValidateModalDoc(null)
      await fetchData()
    } catch (err: unknown) {
      setErrorMsg((err as Error).message || 'Terjadi kesalahan saat memvalidasi pembayaran')
    } finally {
      setSubmitting(false)
    }
  }

  // Submit Cancel Payment
  const handleCancelSubmit = async () => {
    if (!cancelModalDoc || !cancelReason.trim()) return
    setErrorMsg(null)
    setSuccessMsg(null)
    setSubmitting(true)

    try {
      const payload = {
        action: 'CANCEL',
        documentId: cancelModalDoc.id,
        masterVersion: cancelModalDoc.master_version,
        reason: cancelReason.trim(),
      }

      const res = await fetch('/api/finance/supplier-payments', {
        method: 'POST',
        headers: { ...authHeaders(session), 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      })
      const json = await res.json()
      if (!res.ok) throw new Error(json.error?.message || 'Gagal membatalkan pembayaran supplier')

      setSuccessMsg(`Pembayaran Supplier ${cancelModalDoc.payment_no} berhasil dibatalkan`)
      setCancelModalDoc(null)
      setCancelReason('')
      await fetchData()
    } catch (err: unknown) {
      setErrorMsg((err as Error).message || 'Terjadi kesalahan saat membatalkan pembayaran')
    } finally {
      setSubmitting(false)
    }
  }

  // Filtered documents list
  const filteredDocs = documents.filter((doc) => {
    if (statusFilter !== 'ALL' && doc.status !== statusFilter) return false
    if (supplierFilter !== 'ALL' && doc.supplier_id !== supplierFilter) return false
    if (searchQuery.trim()) {
      const q = searchQuery.toLowerCase()
      const matchNo = doc.payment_no.toLowerCase().includes(q)
      const matchRef = (doc.reference_no || '').toLowerCase().includes(q)
      const matchSup = getSupplierName(doc.supplier_id).toLowerCase().includes(q)
      return matchNo || matchRef || matchSup
    }
    return true
  })

  // Validated invoices for selected supplier in Form
  const formSupplierInvoices = validatedInvoices.filter(
    (inv) => inv.supplier_id === selectedSupplierId && inv.remaining_balance > 0,
  )

  return (
    <div className="p-6 max-w-7xl mx-auto space-y-6">
      {/* Header */}
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4 bg-white p-6 rounded-2xl border border-slate-200 shadow-sm">
        <div>
          <div className="flex items-center gap-2">
            <Banknote className="h-6 w-6 text-violet-600" />
            <h1 className="text-2xl font-bold text-slate-900">Pembayaran Supplier (AP Settlement)</h1>
          </div>
          <p className="text-sm text-slate-5-00 mt-1">
            Pelunasan Faktur Supplier berstatus <span className="font-semibold text-emerald-600">VALIDATED</span> dengan kontrol transaksi server-authoritative & akuntansi G5.
          </p>
        </div>
        <div className="flex items-center gap-3">
          <button
            onClick={fetchData}
            disabled={loading}
            className="flex items-center gap-2 px-3 py-2 text-sm font-medium text-slate-700 bg-slate-100 hover:bg-slate-200 rounded-xl transition"
          >
            <RefreshCw className={`h-4 w-4 ${loading ? 'animate-spin' : ''}`} />
            Refresh
          </button>
          {canCreate && <button
            onClick={() => {
              resetForm()
              setActiveTab('form')
            }}
            className="flex items-center gap-2 px-4 py-2 text-sm font-semibold text-white bg-violet-600 hover:bg-violet-700 rounded-xl shadow-sm transition"
          >
            <Plus className="h-4 w-4" />
            Buat Draf Pembayaran
          </button>}
        </div>
      </div>

      {/* Error & Success Messages */}
      {errorMsg && (
        <div className="p-4 bg-rose-50 border border-rose-200 text-rose-800 rounded-xl flex items-start gap-3 shadow-sm">
          <ShieldAlert className="h-5 w-5 text-rose-600 shrink-0 mt-0.5" />
          <div className="flex-1 text-sm font-medium">{errorMsg}</div>
          <button onClick={() => setErrorMsg(null)} className="text-rose-500 hover:text-rose-700">
            <X className="h-4 w-4" />
          </button>
        </div>
      )}

      {successMsg && (
        <div className="p-4 bg-emerald-50 border border-emerald-200 text-emerald-800 rounded-xl flex items-start gap-3 shadow-sm">
          <CheckCircle2 className="h-5 w-5 text-emerald-600 shrink-0 mt-0.5" />
          <div className="flex-1 text-sm font-medium">{successMsg}</div>
          <button onClick={() => setSuccessMsg(null)} className="text-emerald-500 hover:text-emerald-700">
            <X className="h-4 w-4" />
          </button>
        </div>
      )}

      {/* Navigation Tabs */}
      <div className="flex border-b border-slate-200">
        <button
          onClick={() => setActiveTab('list')}
          className={`flex items-center gap-2 py-3 px-6 text-sm font-semibold border-b-2 transition ${
            activeTab === 'list'
              ? 'border-violet-600 text-violet-600'
              : 'border-transparent text-slate-500 hover:text-slate-700'
          }`}
        >
          <FileText className="h-4 w-4" />
          Daftar Pembayaran Supplier ({documents.length})
        </button>
        {canCreate && <button
          onClick={() => {
            if (activeTab === 'list') resetForm()
            setActiveTab('form')
          }}
          className={`flex items-center gap-2 py-3 px-6 text-sm font-semibold border-b-2 transition ${
            activeTab === 'form'
              ? 'border-violet-600 text-violet-600'
              : 'border-transparent text-slate-500 hover:text-slate-700'
          }`}
        >
          <Plus className="h-4 w-4" />
          {draftDocId ? 'Edit Draf Pembayaran' : 'Form Draf Pembayaran'}
        </button>}
      </div>

      {/* TAB 1: LIST VIEW */}
      {activeTab === 'list' && (
        <div className="space-y-4">
          {/* Filters Bar */}
          <div className="bg-white p-4 rounded-xl border border-slate-200 flex flex-wrap items-center justify-between gap-4">
            <div className="flex flex-wrap items-center gap-3">
              <div className="relative min-w-[240px]">
                <Search className="h-4 w-4 text-slate-400 absolute left-3 top-1/2 -translate-y-1/2" />
                <input
                  type="text"
                  placeholder="Cari No Pembayaran / Ref / Supplier..."
                  value={searchQuery}
                  onChange={(e) => setSearchQuery(e.target.value)}
                  className="w-full pl-9 pr-3 py-2 border border-slate-300 rounded-xl text-sm focus:outline-none focus:ring-2 focus:ring-violet-500"
                />
              </div>

              <div className="flex items-center gap-2 text-sm text-slate-600">
                <Filter className="h-4 w-4 text-slate-400" />
                <span>Status:</span>
                <select
                  value={statusFilter}
                  onChange={(e) => setStatusFilter(e.target.value as 'ALL' | 'DRAFT' | 'VALIDATED' | 'CANCELED')}
                  className="border border-slate-300 rounded-xl px-3 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-violet-500"
                >
                  <option value="ALL">Semua Status</option>
                  <option value="DRAFT">DRAFT</option>
                  <option value="VALIDATED">VALIDATED</option>
                  <option value="CANCELED">CANCELED</option>
                </select>
              </div>

              <div className="flex items-center gap-2 text-sm text-slate-600">
                <span>Supplier:</span>
                <select
                  value={supplierFilter}
                  onChange={(e) => setSupplierFilter(e.target.value)}
                  className="border border-slate-300 rounded-xl px-3 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-violet-500 max-w-[200px]"
                >
                  <option value="ALL">Semua Supplier</option>
                  {suppliers.map((s) => (
                    <option key={s.id} value={s.id}>
                      {s.supplier_name}
                    </option>
                  ))}
                </select>
              </div>
            </div>

            <div className="text-xs font-medium text-slate-500">
              Menampilkan {filteredDocs.length} dari {documents.length} dokumen
            </div>
          </div>

          {/* Table */}
          <div className="bg-white rounded-2xl border border-slate-200 shadow-sm overflow-hidden">
            {loading ? (
              <div className="p-12 text-center text-slate-500 flex flex-col items-center justify-center gap-2">
                <RefreshCw className="h-6 w-6 animate-spin text-violet-600" />
                <span>Memuat data pembayaran supplier...</span>
              </div>
            ) : filteredDocs.length === 0 ? (
              <div className="p-12 text-center text-slate-500 space-y-2">
                <FileSpreadsheet className="h-10 w-10 text-slate-300 mx-auto" />
                <p className="font-semibold text-slate-700">Tidak ada dokumen pembayaran supplier</p>
                <p className="text-xs text-slate-500">Silakan buat Draf Pembayaran Supplier baru.</p>
              </div>
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full text-left text-sm border-collapse">
                  <thead>
                    <tr className="bg-slate-50 border-b border-slate-200 text-xs font-semibold text-slate-600 uppercase tracking-wider">
                      <th className="py-3.5 px-4">No Pembayaran</th>
                      <th className="py-3.5 px-4">Tanggal</th>
                      <th className="py-3.5 px-4">Supplier</th>
                      <th className="py-3.5 px-4">Metode Bayar</th>
                      <th className="py-3.5 px-4 text-right">Total Bayar</th>
                      <th className="py-3.5 px-4 text-center">Status</th>
                      <th className="py-3.5 px-4 text-right">Aksi</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-slate-100">
                    {filteredDocs.map((doc) => {
                      const isDraft = doc.status === 'DRAFT'
                      const isValidated = doc.status === 'VALIDATED'
                      const isCanceled = doc.status === 'CANCELED'

                      return (
                        <tr key={doc.id} className="hover:bg-slate-50/80 transition">
                          <td className="py-3.5 px-4">
                            <button
                              onClick={() => setSelectedDoc(doc)}
                              className="font-bold text-violet-600 hover:text-violet-800 hover:underline"
                            >
                              {doc.payment_no}
                            </button>
                            {doc.reference_no && (
                              <div className="text-xs text-slate-500">Ref: {doc.reference_no}</div>
                            )}
                          </td>
                          <td className="py-3.5 px-4 text-slate-600">{formatDate(doc.payment_date)}</td>
                          <td className="py-3.5 px-4 text-slate-800 font-medium">
                            {getSupplierName(doc.supplier_id)}
                          </td>
                          <td className="py-3.5 px-4">
                            <span className="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-lg text-xs font-medium bg-slate-100 text-slate-700 border border-slate-200">
                              <CreditCard className="h-3.5 w-3.5 text-slate-500" />
                              {doc.payment_method}
                            </span>
                          </td>
                          <td className="py-3.5 px-4 text-right font-bold text-slate-900">
                            {formatRupiah(doc.total_amount)}
                          </td>
                          <td className="py-3.5 px-4 text-center">
                            {isDraft && (
                              <span className="inline-flex items-center gap-1 px-2.5 py-1 rounded-full text-xs font-bold bg-amber-50 text-amber-700 border border-amber-200">
                                <Clock className="h-3.5 w-3.5" /> DRAFT
                              </span>
                            )}
                            {isValidated && (
                              <span className="inline-flex items-center gap-1 px-2.5 py-1 rounded-full text-xs font-bold bg-emerald-50 text-emerald-700 border border-emerald-200">
                                <FileCheck className="h-3.5 w-3.5" /> VALIDATED
                              </span>
                            )}
                            {isCanceled && (
                              <span className="inline-flex items-center gap-1 px-2.5 py-1 rounded-full text-xs font-bold bg-rose-50 text-rose-700 border border-rose-200">
                                <XCircle className="h-3.5 w-3.5" /> CANCELED
                              </span>
                            )}
                          </td>
                          <td className="py-3.5 px-4 text-right">
                            <div className="flex items-center justify-end gap-2">
                              <button
                                onClick={() => setSelectedDoc(doc)}
                                className="px-2.5 py-1.5 text-xs font-semibold text-slate-600 hover:text-slate-900 bg-slate-100 hover:bg-slate-200 rounded-lg transition"
                              >
                                Detail
                              </button>

                              {isDraft && (
                                <>
                                  {canEdit && <button
                                    onClick={() => handleEditDraft(doc)}
                                    className="px-2.5 py-1.5 text-xs font-semibold text-amber-700 bg-amber-50 hover:bg-amber-100 rounded-lg border border-amber-200 transition"
                                  >
                                    Edit Draf
                                  </button>}
                                  {canPost && <button
                                    onClick={() => setValidateModalDoc(doc)}
                                    className="px-2.5 py-1.5 text-xs font-semibold text-white bg-emerald-600 hover:bg-emerald-700 rounded-lg transition shadow-sm"
                                  >
                                    Validasi
                                  </button>}
                                  {canEdit && <button
                                    onClick={() => setCancelModalDoc(doc)}
                                    className="px-2.5 py-1.5 text-xs font-semibold text-rose-700 bg-rose-50 hover:bg-rose-100 rounded-lg border border-rose-200 transition"
                                  >
                                    Batal
                                  </button>}
                                </>
                              )}
                            </div>
                          </td>
                        </tr>
                      )
                    })}
                  </tbody>
                </table>
              </div>
            )}
          </div>
        </div>
      )}

      {/* TAB 2: FORM VIEW */}
      {activeTab === 'form' && (
        <form onSubmit={handleSaveDraftSubmit} className="space-y-6">
          <div className="bg-white p-6 rounded-2xl border border-slate-200 shadow-sm space-y-6">
            <h2 className="text-lg font-bold text-slate-900 flex items-center gap-2">
              <FileText className="h-5 w-5 text-violet-600" />
              {draftDocId ? 'Edit Draf Pembayaran Supplier' : 'Form Draf Pembayaran Supplier Baru'}
            </h2>

            {/* Supplier & Header Fields */}
            <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
              <div>
                <label className="block text-xs font-bold text-slate-700 mb-1">
                  Supplier <span className="text-rose-500">*</span>
                </label>
                <select
                  disabled={Boolean(draftDocId)}
                  value={selectedSupplierId}
                  onChange={(e) => handleSupplierChange(e.target.value)}
                  className="w-full border border-slate-300 rounded-xl px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-violet-500 bg-slate-50/50"
                  required
                >
                  <option value="">-- Pilih Supplier --</option>
                  {suppliers.map((s) => (
                    <option key={s.id} value={s.id}>
                      {s.supplier_name} ({s.supplier_code})
                    </option>
                  ))}
                </select>
              </div>

              <div>
                <label className="block text-xs font-bold text-slate-700 mb-1">
                  Tanggal Pembayaran <span className="text-rose-500">*</span>
                </label>
                <input
                  type="date"
                  value={paymentDate}
                  onChange={(e) => setPaymentDate(e.target.value)}
                  className="w-full border border-slate-300 rounded-xl px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-violet-500"
                  required
                />
              </div>

              <div>
                <label className="block text-xs font-bold text-slate-700 mb-1">
                  Metode Pembayaran <span className="text-rose-500">*</span>
                </label>
                <select
                  value={paymentMethod}
                  onChange={(e) => setPaymentMethod(e.target.value as 'CASH' | 'BANK_TRANSFER' | 'CHEQUE')}
                  className="w-full border border-slate-300 rounded-xl px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-violet-500"
                  required
                >
                  <option value="BANK_TRANSFER font-medium">BANK_TRANSFER (Transfer Bank)</option>
                  <option value="CASH">CASH (Kas Tunai)</option>
                  <option value="CHEQUE">CHEQUE (Cek / Bilyet Giro)</option>
                </select>
              </div>
            </div>

            {/* Optional Bank & Reference Details */}
            <div className="grid grid-cols-1 md:grid-cols-4 gap-4 p-4 bg-slate-50 rounded-xl border border-slate-200">
              <div>
                <label className="block text-xs font-medium text-slate-600 mb-1">Akun Sumber Pembayaran</label>
                <select
                  value={sourceAccountId}
                  onChange={(e) => setSourceAccountId(e.target.value)}
                  className="w-full border border-slate-300 rounded-xl px-3 py-1.5 text-xs focus:outline-none focus:ring-2 focus:ring-violet-500 bg-white"
                >
                  <option value="">-- Bebas / Bawaan Kas --</option>
                  {accounts.map((a) => (
                    <option key={a.id} value={a.id}>
                      {a.account_code} - {a.account_name}
                    </option>
                  ))}
                </select>
              </div>

              <div>
                <label className="block text-xs font-medium text-slate-600 mb-1">Bank Tujuan Supplier</label>
                <input
                  type="text"
                  placeholder="Contoh: BCA / Mandiri"
                  value={supplierBankName}
                  onChange={(e) => setSupplierBankName(e.target.value)}
                  className="w-full border border-slate-300 rounded-xl px-3 py-1.5 text-xs focus:outline-none focus:ring-2 focus:ring-violet-500 bg-white"
                />
              </div>

              <div>
                <label className="block text-xs font-medium text-slate-600 mb-1">No Rekening Supplier</label>
                <input
                  type="text"
                  placeholder="Contoh: 1234567890"
                  value={supplierBankAccountNo}
                  onChange={(e) => setSupplierBankAccountNo(e.target.value)}
                  className="w-full border border-slate-300 rounded-xl px-3 py-1.5 text-xs focus:outline-none focus:ring-2 focus:ring-violet-500 bg-white"
                />
              </div>

              <div>
                <label className="block text-xs font-medium text-slate-600 mb-1">Nama Pemilik Rekening</label>
                <input
                  type="text"
                  placeholder="Nama Pemilik Rekening"
                  value={supplierBankAccountHolder}
                  onChange={(e) => setSupplierBankAccountHolder(e.target.value)}
                  className="w-full border border-slate-300 rounded-xl px-3 py-1.5 text-xs focus:outline-none focus:ring-2 focus:ring-violet-500 bg-white"
                />
              </div>

              <div>
                <label className="block text-xs font-medium text-slate-600 mb-1">No Referensi / Transaksi</label>
                <input
                  type="text"
                  placeholder="Contoh: REF-123456"
                  value={referenceNo}
                  onChange={(e) => setReferenceNo(e.target.value)}
                  className="w-full border border-slate-300 rounded-xl px-3 py-1.5 text-xs focus:outline-none focus:ring-2 focus:ring-violet-500 bg-white"
                />
              </div>

              <div className="md:col-span-2">
                <label className="block text-xs font-medium text-slate-600 mb-1">
                  URL Bukti Pembayaran (Wajib HTTPS)
                </label>
                <input
                  type="url"
                  placeholder="https://..."
                  value={evidenceUrl}
                  onChange={(e) => setEvidenceUrl(e.target.value)}
                  className="w-full border border-slate-300 rounded-xl px-3 py-1.5 text-xs focus:outline-none focus:ring-2 focus:ring-violet-500 bg-white"
                />
              </div>

              <div>
                <label className="block text-xs font-medium text-slate-600 mb-1">Catatan</label>
                <input
                  type="text"
                  placeholder="Catatan pelunasan..."
                  value={notes}
                  onChange={(e) => setNotes(e.target.value)}
                  className="w-full border border-slate-300 rounded-xl px-3 py-1.5 text-xs focus:outline-none focus:ring-2 focus:ring-violet-500 bg-white"
                />
              </div>
            </div>

            {/* Invoices Selection Table */}
            <div className="space-y-3">
              <div className="flex items-center justify-between">
                <h3 className="text-sm font-bold text-slate-900 flex items-center gap-2">
                  <FileCheck className="h-4 w-4 text-emerald-600" />
                  Pilih Faktur Supplier VALIDATED untuk Dilunasi
                </h3>
                {selectedSupplierId && (
                  <span className="text-xs text-slate-500">
                    Tersedia {formSupplierInvoices.length} faktur VALIDATED ber-saldo hutang.
                  </span>
                )}
              </div>

              {!selectedSupplierId ? (
                <div className="p-8 text-center bg-slate-50 rounded-xl border border-dashed border-slate-300 text-slate-500 text-xs">
                  Silakan pilih Supplier di atas terlebih dahulu untuk menampilkan daftar Faktur VALIDATED.
                </div>
              ) : formSupplierInvoices.length === 0 ? (
                <div className="p-8 text-center bg-amber-50/50 rounded-xl border border-amber-200 text-amber-800 text-xs">
                  Tidak ditemukan Faktur Supplier berstatus <strong className="font-semibold text-emerald-700">VALIDATED</strong> dengan sisa saldo hutang untuk supplier ini.
                </div>
              ) : (
                <div className="border border-slate-200 rounded-xl overflow-hidden">
                  <table className="w-full text-left text-xs">
                    <thead>
                      <tr className="bg-slate-100 text-slate-700 font-semibold border-b border-slate-200">
                        <th className="py-2.5 px-3">Pilih</th>
                        <th className="py-2.5 px-3">No Faktur System</th>
                        <th className="py-2.5 px-3">No Faktur Supplier</th>
                        <th className="py-2.5 px-3">Tgl Faktur</th>
                        <th className="py-2.5 px-3 text-right">Grand Total</th>
                        <th className="py-2.5 px-3 text-right">Sudah Dibayar</th>
                        <th className="py-2.5 px-3 text-right">Sisa Hutang (AP)</th>
                        <th className="py-2.5 px-3 text-right w-44">Nominal Alokasi (IDR)</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-slate-100">
                      {formSupplierInvoices.map((inv) => {
                        const isAllocated = Boolean(formAllocations[inv.id])
                        const allocatedVal = formAllocations[inv.id]?.allocatedAmount || ''

                        return (
                          <tr key={inv.id} className={isAllocated ? 'bg-violet-50/40' : 'hover:bg-slate-50'}>
                            <td className="py-2.5 px-3">
                              <input
                                type="checkbox"
                                checked={isAllocated}
                                onChange={(e) => {
                                  if (e.target.checked) {
                                    handleAllocationChange(inv.id, String(inv.remaining_balance), inv.remaining_balance)
                                  } else {
                                    handleAllocationChange(inv.id, '0', inv.remaining_balance)
                                  }
                                }}
                                className="h-4 w-4 text-violet-600 rounded border-slate-300 focus:ring-violet-500 cursor-pointer"
                              />
                            </td>
                            <td className="py-2.5 px-3 font-semibold text-slate-900">{inv.invoice_no}</td>
                            <td className="py-2.5 px-3 text-slate-600">{inv.supplier_invoice_no}</td>
                            <td className="py-2.5 px-3 text-slate-500">{formatDate(inv.invoice_date)}</td>
                            <td className="py-2.5 px-3 text-right font-medium text-slate-700">
                              {formatRupiah(inv.grand_total)}
                            </td>
                            <td className="py-2.5 px-3 text-right text-slate-500">
                              {formatRupiah(inv.paid_amount)}
                            </td>
                            <td className="py-2.5 px-3 text-right font-bold text-amber-700">
                              {formatRupiah(inv.remaining_balance)}
                            </td>
                            <td className="py-2.5 px-3 text-right">
                              <input
                                type="number"
                                step="1"
                                min="0"
                                max={inv.remaining_balance}
                                placeholder="0"
                                value={allocatedVal}
                                onChange={(e) => handleAllocationChange(inv.id, e.target.value, inv.remaining_balance)}
                                className="w-full border border-slate-300 rounded-lg px-2.5 py-1 text-right text-xs font-bold text-slate-900 focus:outline-none focus:ring-2 focus:ring-violet-500 bg-white"
                              />
                            </td>
                          </tr>
                        )
                      })}
                    </tbody>
                  </table>
                </div>
              )}
            </div>

            {/* Total Allocation Footer & Action Buttons */}
            <div className="pt-4 border-t border-slate-200 flex flex-col sm:flex-row items-center justify-between gap-4">
              <div className="bg-violet-50 p-4 rounded-xl border border-violet-200 flex items-center gap-4 w-full sm:w-auto">
                <DollarSign className="h-6 w-6 text-violet-600 shrink-0" />
                <div>
                  <div className="text-xs font-semibold text-violet-800">Total Nominal Pelunasan:</div>
                  <div className="text-xl font-extrabold text-violet-950">{formatRupiah(totalFormAllocated)}</div>
                </div>
              </div>

              <div className="flex items-center gap-3 w-full sm:w-auto justify-end">
                <button
                  type="button"
                  onClick={() => {
                    resetForm()
                    setActiveTab('list')
                  }}
                  className="px-4 py-2 text-sm font-semibold text-slate-700 bg-slate-100 hover:bg-slate-200 rounded-xl transition"
                >
                  Batal
                </button>
                <button
                  type="submit"
                  disabled={submitting || totalFormAllocated <= 0}
                  className="flex items-center gap-2 px-6 py-2 text-sm font-bold text-white bg-violet-600 hover:bg-violet-700 rounded-xl shadow-md transition disabled:opacity-50 disabled:cursor-not-allowed"
                >
                  {submitting ? (
                    <>
                      <RefreshCw className="h-4 w-4 animate-spin" />
                      Menyimpan...
                    </>
                  ) : (
                    <>
                      <CheckCircle2 className="h-4 w-4" />
                      Simpan Draf Pembayaran
                    </>
                  )}
                </button>
              </div>
            </div>
          </div>
        </form>
      )}

      {/* MODAL 1: DETAIL VIEW */}
      {selectedDoc && (
        <div className="fixed inset-0 z-50 bg-slate-900/60 backdrop-blur-sm flex items-center justify-center p-4">
          <div className="bg-white rounded-2xl max-w-2xl w-full max-h-[90vh] overflow-y-auto shadow-2xl border border-slate-100">
            <div className="p-6 border-b border-slate-200 flex items-center justify-between">
              <div>
                <div className="flex items-center gap-2">
                  <h3 className="text-xl font-bold text-slate-900">Detail Pembayaran Supplier</h3>
                  <span
                    className={`px-2.5 py-0.5 rounded-full text-xs font-bold ${
                      selectedDoc.status === 'DRAFT'
                        ? 'bg-amber-100 text-amber-800'
                        : selectedDoc.status === 'VALIDATED'
                        ? 'bg-emerald-100 text-emerald-800'
                        : 'bg-rose-100 text-rose-800'
                    }`}
                  >
                    {selectedDoc.status}
                  </span>
                </div>
                <p className="text-xs text-slate-500 mt-1">{selectedDoc.payment_no}</p>
              </div>
              <button onClick={() => setSelectedDoc(null)} className="text-slate-400 hover:text-slate-600">
                <X className="h-5 w-5" />
              </button>
            </div>

            <div className="p-6 space-y-6 text-sm">
              <div className="grid grid-cols-2 sm:grid-cols-3 gap-4 p-4 bg-slate-50 rounded-xl">
                <div>
                  <div className="text-xs text-slate-500">Supplier</div>
                  <div className="font-semibold text-slate-900">{getSupplierName(selectedDoc.supplier_id)}</div>
                </div>
                <div>
                  <div className="text-xs text-slate-500">Tanggal Bayar</div>
                  <div className="font-semibold text-slate-900">{formatDate(selectedDoc.payment_date)}</div>
                </div>
                <div>
                  <div className="text-xs text-slate-500">Metode Bayar</div>
                  <div className="font-semibold text-slate-900">{selectedDoc.payment_method}</div>
                </div>
                <div>
                  <div className="text-xs text-slate-500">Total Nominal</div>
                  <div className="font-extrabold text-violet-700 text-base">{formatRupiah(selectedDoc.total_amount)}</div>
                </div>
                <div>
                  <div className="text-xs text-slate-500">No Referensi</div>
                  <div className="font-semibold text-slate-900">{selectedDoc.reference_no || '-'}</div>
                </div>
                <div>
                  <div className="text-xs text-slate-500">Akun Sumber</div>
                  <div className="font-semibold text-slate-900">{getAccountName(selectedDoc.source_account_id)}</div>
                </div>
              </div>

              {/* Bank Info */}
              {(selectedDoc.supplier_bank_name || selectedDoc.supplier_bank_account_no) && (
                <div className="p-4 bg-slate-50 rounded-xl space-y-1">
                  <div className="text-xs font-bold text-slate-700">Informasi Rekening Bank Supplier</div>
                  <div className="text-xs text-slate-600">
                    Bank: <strong>{selectedDoc.supplier_bank_name || '-'}</strong> | No Rek: <strong>{selectedDoc.supplier_bank_account_no || '-'}</strong> | Atas Nama: <strong>{selectedDoc.supplier_bank_account_holder || '-'}</strong>
                  </div>
                </div>
              )}

              {/* Evidence URL */}
              {selectedDoc.evidence_url && (
                <div className="text-xs">
                  <span className="text-slate-500">Bukti Pembayaran: </span>
                  <a
                    href={selectedDoc.evidence_url}
                    target="_blank"
                    rel="noreferrer"
                    className="text-violet-600 hover:underline font-semibold"
                  >
                    {selectedDoc.evidence_url}
                  </a>
                </div>
              )}

              {/* Notes */}
              {selectedDoc.notes && (
                <div className="text-xs text-slate-600 bg-slate-50 p-3 rounded-lg border border-slate-200">
                  <strong>Catatan:</strong> {selectedDoc.notes}
                </div>
              )}

              {/* Allocated Invoices Table */}
              <div className="space-y-2">
                <h4 className="text-xs font-bold text-slate-900">Alokasi Faktur Supplier</h4>
                <div className="border border-slate-200 rounded-xl overflow-hidden">
                  <table className="w-full text-left text-xs">
                    <thead>
                      <tr className="bg-slate-100 text-slate-700 font-semibold border-b border-slate-200">
                        <th className="py-2 px-3">No Faktur</th>
                        <th className="py-2 px-3 text-right">Nominal Alokasi</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-slate-100">
                      {allocations
                        .filter((a) => a.document_id === selectedDoc.id)
                        .map((allocItem) => {
                          const inv = validatedInvoices.find((i) => i.id === allocItem.invoice_id)
                          return (
                            <tr key={allocItem.id}>
                              <td className="py-2 px-3 font-semibold text-slate-900">
                                {inv ? inv.invoice_no : allocItem.invoice_id.slice(0, 8)}
                              </td>
                              <td className="py-2 px-3 text-right font-bold text-slate-900">
                                {formatRupiah(allocItem.allocated_amount)}
                              </td>
                            </tr>
                          )
                        })}
                    </tbody>
                  </table>
                </div>
              </div>

              {/* Audit / Timeline */}
              <div className="text-xs text-slate-500 space-y-1 pt-4 border-t border-slate-200">
                <div>Dibuat oleh: {getProfileName(selectedDoc.created_by)} pada {formatDate(selectedDoc.created_at)}</div>
                {selectedDoc.validated_by && (
                  <div className="text-emerald-700 font-medium">
                    Divalidasi oleh: {getProfileName(selectedDoc.validated_by)} pada {formatDate(selectedDoc.validated_at)}
                  </div>
                )}
                {selectedDoc.canceled_by && (
                  <div className="text-rose-700 font-medium">
                    Dibatalkan oleh: {getProfileName(selectedDoc.canceled_by)} pada {formatDate(selectedDoc.canceled_at)} (Alasan: {selectedDoc.cancel_reason})
                  </div>
                )}
              </div>
            </div>

            <div className="p-4 bg-slate-50 border-t border-slate-200 flex justify-end">
              <button
                onClick={() => setSelectedDoc(null)}
                className="px-4 py-2 text-xs font-semibold text-slate-700 bg-white border border-slate-300 hover:bg-slate-100 rounded-xl transition"
              >
                Tutup
              </button>
            </div>
          </div>
        </div>
      )}

      {/* MODAL 2: VALIDATE CONFIRMATION */}
      {validateModalDoc && (
        <div className="fixed inset-0 z-50 bg-slate-900/60 backdrop-blur-sm flex items-center justify-center p-4">
          <div className="bg-white rounded-2xl max-w-md w-full p-6 space-y-4 shadow-2xl border border-slate-100">
            <div className="flex items-center gap-3 text-emerald-600">
              <FileCheck className="h-6 w-6" />
              <h3 className="text-lg font-bold text-slate-900">Validasi Pembayaran Supplier</h3>
            </div>
            <p className="text-xs text-slate-600">
              Apakah Anda yakin ingin memvalidasi Pembayaran Supplier <strong>{validateModalDoc.payment_no}</strong> sebesar <strong>{formatRupiah(validateModalDoc.total_amount)}</strong>?
            </p>
            <div className="p-3 bg-amber-50 border border-amber-200 rounded-xl text-xs text-amber-800">
              Dokumen yang sudah divalidasi bersifat <strong className="font-semibold text-amber-950">IMMUTABLE (tidak dapat diubah)</strong> dan akan diterbitkan ke Financial Queue G5.
            </div>
            <div className="flex items-center justify-end gap-3 pt-2">
              <button
                onClick={() => setValidateModalDoc(null)}
                disabled={submitting}
                className="px-4 py-2 text-xs font-semibold text-slate-700 bg-slate-100 hover:bg-slate-200 rounded-xl transition"
              >
                Batal
              </button>
              <button
                onClick={handleValidateSubmit}
                disabled={submitting}
                className="flex items-center gap-2 px-4 py-2 text-xs font-bold text-white bg-emerald-600 hover:bg-emerald-700 rounded-xl shadow-md transition"
              >
                {submitting ? <RefreshCw className="h-4 w-4 animate-spin" /> : <CheckCircle2 className="h-4 w-4" />}
                Validasi Sekarang
              </button>
            </div>
          </div>
        </div>
      )}

      {/* MODAL 3: CANCEL CONFIRMATION */}
      {cancelModalDoc && (
        <div className="fixed inset-0 z-50 bg-slate-900/60 backdrop-blur-sm flex items-center justify-center p-4">
          <div className="bg-white rounded-2xl max-w-md w-full p-6 space-y-4 shadow-2xl border border-slate-100">
            <div className="flex items-center gap-3 text-rose-600">
              <AlertCircle className="h-6 w-6" />
              <h3 className="text-lg font-bold text-slate-900">Pembatalan Draf Pembayaran</h3>
            </div>
            <p className="text-xs text-slate-600">
              Anda akan membatalkan Pembayaran Supplier <strong>{cancelModalDoc.payment_no}</strong>. Tindakan ini tidak dapat dibatalkan kembali.
            </p>
            <div>
              <label className="block text-xs font-bold text-slate-700 mb-1">
                Alasan Pembatalan <span className="text-rose-500">*</span>
              </label>
              <textarea
                rows={3}
                placeholder="Masukkan alasan pembatalan..."
                value={cancelReason}
                onChange={(e) => setCancelReason(e.target.value)}
                className="w-full border border-slate-300 rounded-xl p-2.5 text-xs focus:outline-none focus:ring-2 focus:ring-rose-500"
                required
              />
            </div>
            <div className="flex items-center justify-end gap-3 pt-2">
              <button
                onClick={() => {
                  setCancelModalDoc(null)
                  setCancelReason('')
                }}
                disabled={submitting}
                className="px-4 py-2 text-xs font-semibold text-slate-700 bg-slate-100 hover:bg-slate-200 rounded-xl transition"
              >
                Kembali
              </button>
              <button
                onClick={handleCancelSubmit}
                disabled={submitting || !cancelReason.trim()}
                className="flex items-center gap-2 px-4 py-2 text-xs font-bold text-white bg-rose-600 hover:bg-rose-700 rounded-xl shadow-md transition disabled:opacity-50"
              >
                {submitting ? <RefreshCw className="h-4 w-4 animate-spin" /> : <Trash2 className="h-4 w-4" />}
                Batalkan Pembayaran
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
