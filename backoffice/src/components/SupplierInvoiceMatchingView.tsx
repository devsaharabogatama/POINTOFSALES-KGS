'use client'

import { useEffect, useMemo, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import {
  AlertCircle,
  CheckCircle2,
  Clock,
  FileText,
  PackageCheck,
  Plus,
  Receipt,
  RefreshCw,
  Search,
  ShieldCheck,
  Sliders,
  Trash2,
  X,
  XCircle,
} from 'lucide-react'
import { useEscapeClose } from '@/lib/use-escape-close'

type SupplierInvoiceDoc = {
  id: string
  invoice_no: string
  supplier_invoice_no: string
  supplier_id: string
  invoice_date: string
  due_date: string | null
  price_mode: 'INCLUSIVE' | 'EXCLUSIVE'
  status: 'DRAFT' | 'HOLD' | 'VALIDATED' | 'CANCELED'
  matching_status:
    | 'UNMATCHED'
    | 'PARTIALLY_MATCHED'
    | 'MATCHED'
    | 'WITHIN_TOLERANCE'
    | 'EXCEPTION'
    | 'HOLD'
    | 'CLOSED'
  line_count: number
  invoice_total_base_qty: number
  allocated_total_base_qty: number
  subtotal_before_tax: number
  tax_total: number
  grand_total: number
  provisional_value_allocated: number
  actual_value_allocated: number
  purchase_price_variance: number
  tolerance_policy_id: string | null
  tolerance_policy_version: number | null
  notes: string | null
  evidence_url: string | null
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

type SupplierInvoiceLine = {
  id: string
  document_id: string
  line_no: number
  client_line_key: string
  product_id: string
  invoice_uom_id: string
  invoice_qty: number
  factor_to_base_snapshot: number
  invoice_base_qty: number
  unit_price_input: number
  price_mode_snapshot: string
  net_unit_price: number
  subtotal_before_tax: number
  tax_rule_id: string | null
  tax_code_snapshot: string | null
  tax_name_snapshot: string | null
  tax_rate_percent_snapshot: number
  tax_amount: number
  line_total: number
  allocated_base_qty: number
  product_sku_snapshot: string
  product_name_snapshot: string
  invoice_uom_name_snapshot: string
  base_uom_name_snapshot: string
}

type SupplierInvoiceAllocation = {
  id: string
  document_id: string
  invoice_line_id: string
  client_allocation_key: string
  source_ap_provisional_id: string
  allocated_base_qty: number
  actual_value: number
  provisional_unit_cost_snapshot: number
  provisional_value: number
  price_variance: number
}

type SupplierInvoiceToleranceResult = {
  id: string
  document_id: string
  tolerance_policy_id: string | null
  tolerance_policy_version: number | null
  invoice_base_qty: number
  allocated_base_qty: number
  quantity_variance_base_qty: number
  quantity_tolerance_percent_snapshot: number
  quantity_tolerance_base_qty_snapshot: number | null
  provisional_value: number
  actual_value: number
  value_variance: number
  value_tolerance_percent_snapshot: number
  value_tolerance_amount_snapshot: number | null
  result_status: string
  created_at: string
}

type OpenApProvisional = {
  id: string
  receipt_id: string
  receipt_line_id: string
  supplier_id: string
  amount: number
  status: string
  created_at: string
  goods_receipt_documents: {
    id?: string
    receipt_no: string
    supplier_delivery_no: string | null
    received_at: string
    status: string
  }
  goods_receipt_lines: {
    id?: string
    product_id: string
    accepted_good_base_qty: number
    damaged_base_qty: number
    estimated_base_unit_cost: number
    product_sku_snapshot: string
    product_name_snapshot: string
    base_uom_name_snapshot: string
  }
}

type Supplier = {
  id: string
  supplier_name: string
  supplier_code: string
  is_active: boolean
}

type Product = {
  id: string
  sku: string
  name: string
  uom_id: string
  is_active: boolean
}

type ProductUom = {
  product_id: string
  uom_id: string
  factor_to_base: number
  is_active: boolean
  uoms: {
    id: string
    name: string
    allow_decimal: boolean
    decimal_precision: number
  }
}

type TaxRule = {
  id: string
  tax_code: string
  tax_name: string
  tax_scope: string
  is_active: boolean
  tax_rule_versions: Array<{
    id: string
    rate_percent: number
    calculation_scope: string
    status: string
  }>
}

type Profile = {
  id: string
  name: string
}

type TolerancePolicy = {
  id: string
  company_id: string
  supplier_id: string | null
  quantity_tolerance_percent: number
  quantity_tolerance_base_qty: number | null
  value_tolerance_percent: number
  value_tolerance_amount: number | null
  effective_from: string
  is_active: boolean
  master_version: number
}

function rupiah(amount: number) {
  return new Intl.NumberFormat('id-ID', {
    style: 'currency',
    currency: 'IDR',
    maximumFractionDigits: 2,
  }).format(amount)
}

function fmtNum(n: number) {
  return new Intl.NumberFormat('id-ID', { maximumFractionDigits: 4 }).format(n)
}

const authHeaders = (session: Session) => ({ Authorization: `Bearer ${session.access_token}` })

export function SupplierInvoiceMatchingView({
  session, canCreate, canEdit, canPost, canManagePolicy,
}: {
  session: Session
  canCreate: boolean
  canEdit: boolean
  canPost: boolean
  canManagePolicy: boolean
}) {
  const [activeTab, setActiveTab] = useState<'invoices' | 'create-draft' | 'policies'>('invoices')
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [successMsg, setSuccessMsg] = useState<string | null>(null)

  // Data states
  const [documents, setDocuments] = useState<SupplierInvoiceDoc[]>([])
  const [lines, setLines] = useState<SupplierInvoiceLine[]>([])
  const [allocations, setAllocations] = useState<SupplierInvoiceAllocation[]>([])
  const [toleranceResults, setToleranceResults] = useState<SupplierInvoiceToleranceResult[]>([])
  const [openApProvisionals, setOpenApProvisionals] = useState<OpenApProvisional[]>([])
  const [suppliers, setSuppliers] = useState<Supplier[]>([])
  const [products, setProducts] = useState<Product[]>([])
  const [productUoms, setProductUoms] = useState<ProductUom[]>([])
  const [taxRules, setTaxRules] = useState<TaxRule[]>([])
  const [profiles, setProfiles] = useState<Profile[]>([])
  const [policies, setPolicies] = useState<TolerancePolicy[]>([])

  // Filters
  const [searchQuery, setSearchQuery] = useState('')
  const [statusFilter, setStatusFilter] = useState<string>('ALL')
  const [supplierFilter, setSupplierFilter] = useState<string>('ALL')

  // Modals
  const [selectedDoc, setSelectedDoc] = useState<SupplierInvoiceDoc | null>(null)
  const [validateModalDoc, setValidateModalDoc] = useState<SupplierInvoiceDoc | null>(null)
  const [cancelModalDoc, setCancelModalDoc] = useState<SupplierInvoiceDoc | null>(null)
  const [cancelReason, setCancelReason] = useState('')
  const [isSubmitting, setIsSubmitting] = useState(false)

  // Policy Modal
  const [policyModal, setPolicyModal] = useState<{
    open: boolean
    editing: TolerancePolicy | null
  }>({ open: false, editing: null })
  const [policyForm, setPolicyForm] = useState({
    supplierId: '',
    quantityTolerancePercent: 0,
    quantityToleranceBaseQty: '',
    valueTolerancePercent: 0,
    valueToleranceAmount: '',
    effectiveFrom: new Date().toISOString().split('T')[0],
    isActive: true,
  })

  // Draft Form State
  const [draftDocId, setDraftDocId] = useState<string | null>(null)
  const [draftMasterVersion, setDraftMasterVersion] = useState<number | null>(null)
  const [draftSupplierId, setDraftSupplierId] = useState('')
  const [draftReceiptId, setDraftReceiptId] = useState('')
  const [draftInvoiceNo, setDraftInvoiceNo] = useState('')
  const [draftInvoiceDate, setDraftInvoiceDate] = useState(
    new Date().toISOString().split('T')[0],
  )
  const [draftDueDate, setDraftDueDate] = useState('')
  const [draftPriceMode, setDraftPriceMode] = useState<'INCLUSIVE' | 'EXCLUSIVE'>('EXCLUSIVE')
  const [draftNotes, setDraftNotes] = useState('')
  const [draftEvidenceUrl, setDraftEvidenceUrl] = useState('')

  type FormLine = {
    clientLineKey: string
    productId: string
    invoiceUomId: string
    invoiceQty: number
    unitPrice: number
    taxRuleId: string
    allocations: Array<{
      clientAllocationKey: string
      sourceApProvisionalId: string
      quantityBase: number
    }>
  }
  const [draftLines, setDraftLines] = useState<FormLine[]>([])

  useEscapeClose(() => {
    if (selectedDoc) setSelectedDoc(null)
    if (validateModalDoc) setValidateModalDoc(null)
    if (cancelModalDoc) setCancelModalDoc(null)
    if (policyModal.open) setPolicyModal({ open: false, editing: null })
  })

  const fetchData = async (isRefresh = false) => {
    if (isRefresh) setLoading(true)
    setError(null)
    try {
      const invRes = await fetch('/api/finance/supplier-invoices', {
        headers: authHeaders(session),
      })
      const invData = await invRes.json()

      if (!invRes.ok) throw new Error(invData.message || invData.error || 'Gagal memuat data faktur supplier')

      setDocuments(invData.data || [])
      setLines(invData.lines || [])
      setAllocations(invData.allocations || [])
      setToleranceResults(invData.toleranceResults || [])
      setOpenApProvisionals(invData.openApProvisionals || [])
      setSuppliers(invData.suppliers || [])
      setProducts(invData.products || [])
      setProductUoms(invData.productUoms || [])
      setTaxRules(invData.taxRules || [])
      setProfiles(invData.profiles || [])
      setPolicies(invData.policies || [])
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Terjadi kesalahan')
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => {
    void (async () => {
      await fetchData(false)
    })()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  // Filtered documents
  const filteredDocs = useMemo(() => {
    return documents.filter((doc) => {
      const supp = suppliers.find((s) => s.id === doc.supplier_id)
      const suppName = supp ? supp.supplier_name.toLowerCase() : ''
      const q = searchQuery.toLowerCase()

      const matchSearch =
        doc.invoice_no.toLowerCase().includes(q) ||
        doc.supplier_invoice_no.toLowerCase().includes(q) ||
        suppName.includes(q)

      const matchStatus = statusFilter === 'ALL' || doc.status === statusFilter
      const matchSupplier = supplierFilter === 'ALL' || doc.supplier_id === supplierFilter

      return matchSearch && matchStatus && matchSupplier
    })
  }, [documents, suppliers, searchQuery, statusFilter, supplierFilter])

  // Profile map helper
  const profileMap = useMemo(() => {
    const map: Record<string, string> = {}
    profiles.forEach((p) => {
      map[p.id] = p.name
    })
    return map
  }, [profiles])

  // Supplier map helper
  const supplierMap = useMemo(() => {
    const map: Record<string, Supplier> = {}
    suppliers.forEach((s) => {
      map[s.id] = s
    })
    return map
  }, [suppliers])

  // Group open AP provisionals by Receipt
  const openReceiptsForSupplier = useMemo(() => {
    if (!draftSupplierId) return []
    const suppAps = openApProvisionals.filter((ap) => ap.supplier_id === draftSupplierId)
    const map = new Map<string, { receiptNo: string; receivedAt: string; totalAmount: number; aps: OpenApProvisional[] }>()

    suppAps.forEach((ap) => {
      const rId = ap.receipt_id
      const existing = map.get(rId)
      if (existing) {
        existing.totalAmount += ap.amount
        existing.aps.push(ap)
      } else {
        map.set(rId, {
          receiptNo: ap.goods_receipt_documents?.receipt_no || 'Goods Receipt',
          receivedAt: ap.goods_receipt_documents?.received_at || ap.created_at,
          totalAmount: ap.amount,
          aps: [ap],
        })
      }
    })

    return Array.from(map.entries()).map(([receiptId, value]) => ({
      receiptId,
      ...value,
    }))
  }, [draftSupplierId, openApProvisionals])

  // Auto-populate draft lines from selected Goods Receipt AP Provisionals
  const handleAutoPopulateFromReceipt = (receiptId: string) => {
    setDraftReceiptId(receiptId)
    const targetReceipt = openReceiptsForSupplier.find((r) => r.receiptId === receiptId)
    if (!targetReceipt) return

    const newFormLines: FormLine[] = targetReceipt.aps.map((ap) => {
      const prodId = ap.goods_receipt_lines.product_id
      const prod = products.find((p) => p.id === prodId)
      const uomId = prod ? prod.uom_id : ''

      return {
        clientLineKey: crypto.randomUUID(),
        productId: prodId,
        invoiceUomId: uomId,
        invoiceQty: ap.goods_receipt_lines.accepted_good_base_qty,
        unitPrice: ap.goods_receipt_lines.estimated_base_unit_cost,
        taxRuleId: '',
        allocations: [
          {
            clientAllocationKey: crypto.randomUUID(),
            sourceApProvisionalId: ap.id,
            quantityBase: ap.goods_receipt_lines.accepted_good_base_qty,
          },
        ],
      }
    })

    setDraftLines(newFormLines)
  }

  // Reset Draft Form
  const resetDraftForm = () => {
    setDraftDocId(null)
    setDraftMasterVersion(null)
    setDraftSupplierId('')
    setDraftReceiptId('')
    setDraftInvoiceNo('')
    setDraftInvoiceDate(new Date().toISOString().split('T')[0])
    setDraftDueDate('')
    setDraftPriceMode('EXCLUSIVE')
    setDraftNotes('')
    setDraftEvidenceUrl('')
    setDraftLines([])
  }

  // Load document into edit form
  const handleEditDraft = (doc: SupplierInvoiceDoc) => {
    setDraftDocId(doc.id)
    setDraftMasterVersion(doc.master_version)
    setDraftSupplierId(doc.supplier_id)
    setDraftInvoiceNo(doc.supplier_invoice_no)
    setDraftInvoiceDate(doc.invoice_date)
    setDraftDueDate(doc.due_date || '')
    setDraftPriceMode(doc.price_mode)
    setDraftNotes(doc.notes || '')
    setDraftEvidenceUrl(doc.evidence_url || '')

    const docLines = lines.filter((l) => l.document_id === doc.id)
    const formattedLines: FormLine[] = docLines.map((l) => {
      const lineAllocs = allocations.filter((a) => a.invoice_line_id === l.id)
      return {
        clientLineKey: l.client_line_key,
        productId: l.product_id,
        invoiceUomId: l.invoice_uom_id,
        invoiceQty: l.invoice_qty,
        unitPrice: l.unit_price_input,
        taxRuleId: l.tax_rule_id || '',
        allocations: lineAllocs.map((a) => ({
          clientAllocationKey: a.client_allocation_key,
          sourceApProvisionalId: a.source_ap_provisional_id,
          quantityBase: a.allocated_base_qty,
        })),
      }
    })

    setDraftLines(formattedLines)
    setActiveTab('create-draft')
  }

  // Add line manually if needed
  const handleAddLine = () => {
    if (!products.length) return
    const firstProd = products[0]
    const prodUoms = productUoms.filter((pu) => pu.product_id === firstProd.id)
    const firstUomId = prodUoms.length ? prodUoms[0].uom_id : firstProd.uom_id

    setDraftLines((prev) => [
      ...prev,
      {
        clientLineKey: crypto.randomUUID(),
        productId: firstProd.id,
        invoiceUomId: firstUomId,
        invoiceQty: 1,
        unitPrice: 0,
        taxRuleId: '',
        allocations: [],
      },
    ])
  }

  // Save Draft Submission
  const handleSaveDraftSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    setIsSubmitting(true)
    setError(null)
    setSuccessMsg(null)

    try {
      if (!draftSupplierId) throw new Error('Pilih supplier terlebih dahulu')
      if (!draftInvoiceNo.trim()) throw new Error('Nomor faktur supplier wajib diisi')
      if (!draftLines.length) throw new Error('Minimal tambahkan 1 baris barang faktur')

      const payload = {
        action: 'SAVE_DRAFT',
        documentId: draftDocId,
        masterVersion: draftMasterVersion,
        supplierId: draftSupplierId,
        supplierInvoiceNo: draftInvoiceNo.trim(),
        invoiceDate: draftInvoiceDate,
        dueDate: draftDueDate || null,
        priceMode: draftPriceMode,
        notes: draftNotes.trim() || null,
        evidenceUrl: draftEvidenceUrl.trim() || null,
        lines: draftLines.map((l) => ({
          clientLineKey: l.clientLineKey,
          productId: l.productId,
          invoiceUomId: l.invoiceUomId,
          invoiceQty: l.invoiceQty,
          unitPrice: l.unitPrice,
          taxRuleId: l.taxRuleId || null,
          allocations: l.allocations.length ? l.allocations : null,
        })),
      }

      const res = await fetch('/api/finance/supplier-invoices', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', ...authHeaders(session) },
        body: JSON.stringify(payload),
      })
      const data = await res.json()
      if (!res.ok) throw new Error(data.message || 'Gagal menyimpan draf faktur supplier')

      setSuccessMsg('Draf Faktur Supplier berhasil disimpan')
      resetDraftForm()
      setActiveTab('invoices')
      await fetchData()
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Terjadi kesalahan')
    } finally {
      setIsSubmitting(false)
    }
  }

  // Validate Submission
  const handleValidateSubmit = async () => {
    if (!validateModalDoc) return
    setIsSubmitting(true)
    setError(null)

    try {
      const payload = {
        action: 'VALIDATE',
        documentId: validateModalDoc.id,
        masterVersion: validateModalDoc.master_version,
        idempotencyKey: crypto.randomUUID(),
      }
      const res = await fetch('/api/finance/supplier-invoices', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', ...authHeaders(session) },
        body: JSON.stringify(payload),
      })
      const data = await res.json()
      if (!res.ok) throw new Error(data.message || data.error || 'Gagal memvalidasi faktur supplier')

      if (data.data?.status === 'HOLD') {
        setSuccessMsg('Faktur dialihkan ke status HOLD karena matching status belum MATCHED / WITHIN_TOLERANCE')
      } else {
        setSuccessMsg('Faktur Supplier berhasil divalidasi (VALIDATED)')
      }
      setValidateModalDoc(null)
      await fetchData()
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Terjadi kesalahan')
    } finally {
      setIsSubmitting(false)
    }
  }

  // Cancel Submission
  const handleCancelSubmit = async () => {
    if (!cancelModalDoc) return
    if (!cancelReason.trim()) {
      setError('Alasan pembatalan wajib diisi')
      return
    }
    setIsSubmitting(true)
    setError(null)

    try {
      const payload = {
        action: 'CANCEL',
        documentId: cancelModalDoc.id,
        masterVersion: cancelModalDoc.master_version,
        cancelReason: cancelReason.trim(),
      }
      const res = await fetch('/api/finance/supplier-invoices', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', ...authHeaders(session) },
        body: JSON.stringify(payload),
      })
      const data = await res.json()
      if (!res.ok) throw new Error(data.message || 'Gagal membatalkan faktur supplier')

      setSuccessMsg('Faktur Supplier berhasil dibatalkan')
      setCancelModalDoc(null)
      setCancelReason('')
      await fetchData()
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Terjadi kesalahan')
    } finally {
      setIsSubmitting(false)
    }
  }

  // Policy Form Save
  const handleSavePolicySubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    setIsSubmitting(true)
    setError(null)

    try {
      const payload = {
        policyId: policyModal.editing ? policyModal.editing.id : null,
        masterVersion: policyModal.editing ? policyModal.editing.master_version : null,
        supplierId: policyForm.supplierId || null,
        quantityTolerancePercent: policyForm.quantityTolerancePercent,
        quantityToleranceBaseQty: policyForm.quantityToleranceBaseQty !== '' ? Number(policyForm.quantityToleranceBaseQty) : null,
        valueTolerancePercent: policyForm.valueTolerancePercent,
        valueToleranceAmount: policyForm.valueToleranceAmount !== '' ? Number(policyForm.valueToleranceAmount) : null,
        effectiveFrom: policyForm.effectiveFrom,
        isActive: policyForm.isActive,
      }

      const res = await fetch('/api/finance/supplier-invoices/policies', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', ...authHeaders(session) },
        body: JSON.stringify(payload),
      })
      const data = await res.json()
      if (!res.ok) throw new Error(data.message || 'Gagal menyimpan kebijakan toleransi')

      setSuccessMsg('Kebijakan toleransi berhasil disimpan')
      setPolicyModal({ open: false, editing: null })
      await fetchData()
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'Terjadi kesalahan')
    } finally {
      setIsSubmitting(false)
    }
  }

  // Matching status badge UI
  const renderMatchingBadge = (status: string) => {
    switch (status) {
      case 'MATCHED':
        return (
          <span className="inline-flex items-center gap-1 rounded-full bg-emerald-50 px-2.5 py-1 text-xs font-semibold text-emerald-700 border border-emerald-200">
            <ShieldCheck className="h-3.5 w-3.5" /> MATCHED
          </span>
        )
      case 'WITHIN_TOLERANCE':
        return (
          <span className="inline-flex items-center gap-1 rounded-full bg-cyan-50 px-2.5 py-1 text-xs font-semibold text-cyan-700 border border-cyan-200">
            <CheckCircle2 className="h-3.5 w-3.5" /> TOLERANCE OK
          </span>
        )
      case 'PARTIALLY_MATCHED':
        return (
          <span className="inline-flex items-center gap-1 rounded-full bg-blue-50 px-2.5 py-1 text-xs font-semibold text-blue-700 border border-blue-200">
            <Clock className="h-3.5 w-3.5" /> PARTIAL
          </span>
        )
      case 'EXCEPTION':
        return (
          <span className="inline-flex items-center gap-1 rounded-full bg-rose-50 px-2.5 py-1 text-xs font-semibold text-rose-700 border border-rose-200">
            <AlertCircle className="h-3.5 w-3.5" /> EXCEPTION
          </span>
        )
      default:
        return (
          <span className="inline-flex items-center gap-1 rounded-full bg-slate-100 px-2.5 py-1 text-xs font-semibold text-slate-700 border border-slate-200">
            {status}
          </span>
        )
    }
  }

  // Document status badge UI
  const renderDocStatusBadge = (status: string) => {
    switch (status) {
      case 'DRAFT':
        return <span className="rounded-full bg-amber-50 px-2.5 py-1 text-xs font-semibold text-amber-700 border border-amber-200">DRAFT</span>
      case 'HOLD':
        return <span className="rounded-full bg-orange-50 px-2.5 py-1 text-xs font-semibold text-orange-700 border border-orange-200">HOLD</span>
      case 'VALIDATED':
        return <span className="rounded-full bg-emerald-50 px-2.5 py-1 text-xs font-semibold text-emerald-700 border border-emerald-200">VALIDATED</span>
      case 'CANCELED':
        return <span className="rounded-full bg-rose-50 px-2.5 py-1 text-xs font-semibold text-rose-700 border border-rose-200">CANCELED</span>
      default:
        return <span className="rounded-full bg-slate-100 px-2.5 py-1 text-xs font-semibold text-slate-700">{status}</span>
    }
  }

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex flex-col gap-4 md:flex-row md:items-center md:justify-between">
        <div>
          <h1 className="text-2xl font-bold text-slate-900">Pencocokan Faktur Supplier (Invoice Matching)</h1>
          <p className="text-sm text-slate-500">
            Pencocokan tiga arah (*Three-Way Matching*) Faktur Supplier terhadap Penerimaan Barang (Goods Receipt / AP Provisional) & Kebijakan Toleransi.
          </p>
        </div>
        <div className="flex items-center gap-3">
          <button
            onClick={() => fetchData(true)}
            disabled={loading}
            className="inline-flex items-center gap-2 rounded-xl border border-slate-200 bg-white px-4 py-2.5 text-sm font-semibold text-slate-700 shadow-sm hover:bg-slate-50 disabled:opacity-50"
          >
            <RefreshCw className={`h-4 w-4 ${loading ? 'animate-spin' : ''}`} /> Refresh
          </button>
          {canCreate && <button
            onClick={() => {
              resetDraftForm()
              setActiveTab('create-draft')
            }}
            className="inline-flex items-center gap-2 rounded-xl bg-violet-600 px-4 py-2.5 text-sm font-semibold text-white shadow-sm hover:bg-violet-700"
          >
            <Plus className="h-4 w-4" /> Pencocokan Faktur Baru
          </button>}
        </div>
      </div>

      {/* Notifications */}
      {error && (
        <div className="flex items-center justify-between rounded-xl bg-rose-50 border border-rose-200 p-4 text-sm text-rose-800">
          <div className="flex items-center gap-3">
            <AlertCircle className="h-5 w-5 shrink-0 text-rose-600" />
            <span>{error}</span>
          </div>
          <button onClick={() => setError(null)} className="text-rose-500 hover:text-rose-700">
            <X className="h-4 w-4" />
          </button>
        </div>
      )}
      {successMsg && (
        <div className="flex items-center justify-between rounded-xl bg-emerald-50 border border-emerald-200 p-4 text-sm text-emerald-800">
          <div className="flex items-center gap-3">
            <CheckCircle2 className="h-5 w-5 shrink-0 text-emerald-600" />
            <span>{successMsg}</span>
          </div>
          <button onClick={() => setSuccessMsg(null)} className="text-emerald-500 hover:text-emerald-700">
            <X className="h-4 w-4" />
          </button>
        </div>
      )}

      {/* Navigation Tabs */}
      <div className="border-b border-slate-200">
        <nav className="-mb-px flex gap-6">
          <button
            onClick={() => setActiveTab('invoices')}
            className={`flex items-center gap-2 border-b-2 pb-3 pt-2 text-sm font-semibold transition-colors ${
              activeTab === 'invoices'
                ? 'border-violet-600 text-violet-600'
                : 'border-transparent text-slate-500 hover:text-slate-700'
            }`}
          >
            <Receipt className="h-4 w-4" /> Daftar Faktur Supplier ({documents.length})
          </button>
          {(canCreate || (canEdit && Boolean(draftDocId))) && <button
            onClick={() => setActiveTab('create-draft')}
            className={`flex items-center gap-2 border-b-2 pb-3 pt-2 text-sm font-semibold transition-colors ${
              activeTab === 'create-draft'
                ? 'border-violet-600 text-violet-600'
                : 'border-transparent text-slate-500 hover:text-slate-700'
            }`}
          >
            <FileText className="h-4 w-4" /> {draftDocId ? 'Edit Draf Faktur' : 'Form Pencocokan Faktur'}
          </button>}
          <button
            onClick={() => setActiveTab('policies')}
            className={`flex items-center gap-2 border-b-2 pb-3 pt-2 text-sm font-semibold transition-colors ${
              activeTab === 'policies'
                ? 'border-violet-600 text-violet-600'
                : 'border-transparent text-slate-500 hover:text-slate-700'
            }`}
          >
            <Sliders className="h-4 w-4" /> Kebijakan Toleransi ({policies.length})
          </button>
        </nav>
      </div>

      {/* TAB 1: INVOICES LIST */}
      {activeTab === 'invoices' && (
        <div className="space-y-4">
          {/* Filters Bar */}
          <div className="flex flex-wrap items-center justify-between gap-4 rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
            <div className="relative flex-1 min-w-[240px]">
              <Search className="absolute left-3.5 top-2.5 h-4 w-4 text-slate-400" />
              <input
                type="text"
                placeholder="Cari no faktur, no invoice supplier, nama supplier..."
                value={searchQuery}
                onChange={(e) => setSearchQuery(e.target.value)}
                className="w-full rounded-xl border border-slate-200 pl-10 pr-4 py-2 text-sm focus:border-violet-500 focus:outline-none"
              />
            </div>
            <div className="flex items-center gap-3">
              <select
                value={statusFilter}
                onChange={(e) => setStatusFilter(e.target.value)}
                className="rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm font-medium text-slate-700 focus:border-violet-500 focus:outline-none"
              >
                <option value="ALL">Semua Status Dokumen</option>
                <option value="DRAFT">DRAFT</option>
                <option value="HOLD">HOLD</option>
                <option value="VALIDATED">VALIDATED</option>
                <option value="CANCELED">CANCELED</option>
              </select>

              <select
                value={supplierFilter}
                onChange={(e) => setSupplierFilter(e.target.value)}
                className="rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm font-medium text-slate-700 focus:border-violet-500 focus:outline-none"
              >
                <option value="ALL">Semua Supplier</option>
                {suppliers.map((s) => (
                  <option key={s.id} value={s.id}>
                    {s.supplier_name} ({s.supplier_code})
                  </option>
                ))}
              </select>
            </div>
          </div>

          {/* Table */}
          <div className="overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-sm">
            {loading ? (
              <div className="p-8 text-center text-sm text-slate-500">Memuat data faktur supplier...</div>
            ) : filteredDocs.length === 0 ? (
              <div className="p-8 text-center text-sm text-slate-500">Belum ada faktur supplier yang sesuai filter.</div>
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full text-left text-sm">
                  <thead className="border-b border-slate-100 bg-slate-50 text-xs font-semibold uppercase tracking-wider text-slate-500">
                    <tr>
                      <th className="px-5 py-4">No. Faktur (Sistem)</th>
                      <th className="px-5 py-4">No. Invoice Supplier</th>
                      <th className="px-5 py-4">Supplier</th>
                      <th className="px-5 py-4">Tgl Faktur / Jth Tempo</th>
                      <th className="px-5 py-4 text-right">Grand Total</th>
                      <th className="px-5 py-4">Matching Status</th>
                      <th className="px-5 py-4">Status Dokumen</th>
                      <th className="px-5 py-4 text-right">Aksi</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-slate-100">
                    {filteredDocs.map((doc) => {
                      const supp = supplierMap[doc.supplier_id]
                      return (
                        <tr key={doc.id} className="hover:bg-slate-50/50">
                          <td className="px-5 py-4 font-bold text-slate-900">{doc.invoice_no}</td>
                          <td className="px-5 py-4 font-medium text-slate-700">{doc.supplier_invoice_no}</td>
                          <td className="px-5 py-4 font-medium text-slate-900">
                            {supp ? supp.supplier_name : 'Supplier N/A'}
                          </td>
                          <td className="px-5 py-4 text-slate-600">
                            <div>{new Date(doc.invoice_date).toLocaleDateString('id-ID')}</div>
                            {doc.due_date && (
                              <div className="text-xs text-slate-400">
                                Jth: {new Date(doc.due_date).toLocaleDateString('id-ID')}
                              </div>
                            )}
                          </td>
                          <td className="px-5 py-4 text-right font-bold text-slate-900">
                            {rupiah(doc.grand_total)}
                          </td>
                          <td className="px-5 py-4">{renderMatchingBadge(doc.matching_status)}</td>
                          <td className="px-5 py-4">{renderDocStatusBadge(doc.status)}</td>
                          <td className="px-5 py-4 text-right space-x-2">
                            <button
                              onClick={() => setSelectedDoc(doc)}
                              className="rounded-lg border border-slate-200 bg-white px-3 py-1.5 text-xs font-semibold text-slate-700 shadow-sm hover:bg-slate-50"
                            >
                              Detail
                            </button>

                            {(doc.status === 'DRAFT' || doc.status === 'HOLD') && (
                              <>
                                {canEdit && <button
                                  onClick={() => handleEditDraft(doc)}
                                  className="rounded-lg border border-amber-200 bg-amber-50 px-3 py-1.5 text-xs font-semibold text-amber-800 hover:bg-amber-100"
                                >
                                  Edit Draf
                                </button>}
                                {canPost && <button
                                  onClick={() => setValidateModalDoc(doc)}
                                  className="rounded-lg bg-emerald-600 px-3 py-1.5 text-xs font-semibold text-white shadow-sm hover:bg-emerald-700"
                                >
                                  Validate
                                </button>}
                              </>
                            )}

                            {canEdit && doc.status !== 'CANCELED' && (
                              <button
                                onClick={() => setCancelModalDoc(doc)}
                                className="rounded-lg border border-rose-200 bg-rose-50 px-3 py-1.5 text-xs font-semibold text-rose-700 hover:bg-rose-100"
                              >
                                Cancel
                              </button>
                            )}
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

      {/* TAB 2: CREATE / EDIT DRAFT FORM WITH GOODS RECEIPT AUTO-POPULATE */}
      {activeTab === 'create-draft' && (canCreate || (canEdit && Boolean(draftDocId))) && (
        <form onSubmit={handleSaveDraftSubmit} className="space-y-6">
          <div className="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm space-y-6">
            <h2 className="text-lg font-bold text-slate-900 border-b border-slate-100 pb-4">
              {draftDocId ? 'Edit Draf Faktur Supplier' : 'Form Pencocokan Faktur Supplier (Three-Way Matching)'}
            </h2>

            {/* Goods Receipt Selection / Auto-Populate Bar */}
            <div className="rounded-xl border border-violet-200 bg-violet-50/50 p-4 space-y-3">
              <div className="flex items-center gap-2 text-violet-900 font-bold text-sm">
                <PackageCheck className="h-5 w-5 text-violet-600" />
                <span>Langkah 1: Pilih Supplier & Dokumen Penerimaan Barang (Goods Receipt)</span>
              </div>
              <p className="text-xs text-slate-600">
                Pilih Supplier dan dokumen Penerimaan Barang (POSTED) untuk mengisikan seluruh baris produk, kuantitas penerimaan (*accepted qty*), dan estimasi harga secara otomatis.
              </p>

              <div className="grid gap-4 md:grid-cols-2 pt-2">
                <div>
                  <label className="block text-xs font-bold uppercase tracking-wider text-slate-700 mb-1.5">
                    1. Supplier *
                  </label>
                  <select
                    value={draftSupplierId}
                    onChange={(e) => {
                      setDraftSupplierId(e.target.value)
                      setDraftReceiptId('')
                      setDraftLines([])
                    }}
                    required
                    className="w-full rounded-xl border border-slate-200 bg-white px-4 py-2.5 text-sm font-medium focus:border-violet-500 focus:outline-none"
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
                  <label className="block text-xs font-bold uppercase tracking-wider text-slate-700 mb-1.5">
                    2. Dokumen Penerimaan Barang (Goods Receipt OPEN AP) *
                  </label>
                  <select
                    value={draftReceiptId}
                    onChange={(e) => {
                      const rId = e.target.value
                      if (rId) {
                        handleAutoPopulateFromReceipt(rId)
                      } else {
                        setDraftReceiptId('')
                      }
                    }}
                    disabled={!draftSupplierId}
                    className="w-full rounded-xl border border-slate-200 bg-white px-4 py-2.5 text-sm font-medium focus:border-violet-500 focus:outline-none disabled:opacity-50"
                  >
                    <option value="">-- Pilih Goods Receipt --</option>
                    {openReceiptsForSupplier.map((r) => (
                      <option key={r.receiptId} value={r.receiptId}>
                        {r.receiptNo} ({new Date(r.receivedAt).toLocaleDateString('id-ID')}) - AP Provisional: {rupiah(r.totalAmount)}
                      </option>
                    ))}
                  </select>
                </div>
              </div>
            </div>

            {/* Invoice Header Details */}
            <div className="grid gap-6 md:grid-cols-3">
              <div>
                <label className="block text-xs font-bold uppercase tracking-wider text-slate-600 mb-2">
                  No. Invoice Supplier (Faktur Fisik) *
                </label>
                <input
                  type="text"
                  placeholder="Contoh: INV-SUPP-2026/08/001"
                  value={draftInvoiceNo}
                  onChange={(e) => setDraftInvoiceNo(e.target.value)}
                  required
                  className="w-full rounded-xl border border-slate-200 px-4 py-2.5 text-sm focus:border-violet-500 focus:outline-none"
                />
              </div>

              <div>
                <label className="block text-xs font-bold uppercase tracking-wider text-slate-600 mb-2">
                  Mode Harga Pajak *
                </label>
                <select
                  value={draftPriceMode}
                  onChange={(e) => setDraftPriceMode(e.target.value as 'INCLUSIVE' | 'EXCLUSIVE')}
                  required
                  className="w-full rounded-xl border border-slate-200 px-4 py-2.5 text-sm font-medium focus:border-violet-500 focus:outline-none"
                >
                  <option value="EXCLUSIVE">EXCLUSIVE (Belum Termasuk Pajak)</option>
                  <option value="INCLUSIVE">INCLUSIVE (Sudah Termasuk Pajak)</option>
                </select>
              </div>

              <div>
                <label className="block text-xs font-bold uppercase tracking-wider text-slate-600 mb-2">
                  Tanggal Faktur *
                </label>
                <input
                  type="date"
                  value={draftInvoiceDate}
                  onChange={(e) => setDraftInvoiceDate(e.target.value)}
                  required
                  className="w-full rounded-xl border border-slate-200 px-4 py-2.5 text-sm focus:border-violet-500 focus:outline-none"
                />
              </div>

              <div>
                <label className="block text-xs font-bold uppercase tracking-wider text-slate-600 mb-2">
                  Tanggal Jatuh Tempo (Opsional)
                </label>
                <input
                  type="date"
                  value={draftDueDate}
                  onChange={(e) => setDraftDueDate(e.target.value)}
                  className="w-full rounded-xl border border-slate-200 px-4 py-2.5 text-sm focus:border-violet-500 focus:outline-none"
                />
              </div>

              <div className="md:col-span-2">
                <label className="block text-xs font-bold uppercase tracking-wider text-slate-600 mb-2">
                  URL Bukti / Document (HTTPS, Opsional)
                </label>
                <input
                  type="url"
                  placeholder="https://..."
                  value={draftEvidenceUrl}
                  onChange={(e) => setDraftEvidenceUrl(e.target.value)}
                  className="w-full rounded-xl border border-slate-200 px-4 py-2.5 text-sm focus:border-violet-500 focus:outline-none"
                />
              </div>
            </div>

            <div>
              <label className="block text-xs font-bold uppercase tracking-wider text-slate-600 mb-2">
                Catatan (Opsional)
              </label>
              <textarea
                rows={2}
                value={draftNotes}
                onChange={(e) => setDraftNotes(e.target.value)}
                placeholder="Catatan tambahan mengenai pencocokan faktur ini..."
                className="w-full rounded-xl border border-slate-200 p-3 text-sm focus:border-violet-500 focus:outline-none"
              />
            </div>
          </div>

          {/* Form Lines Section */}
          <div className="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm space-y-4">
            <div className="flex items-center justify-between border-b border-slate-100 pb-4">
              <div>
                <h3 className="text-base font-bold text-slate-900">Pencocokan Baris Barang (Invoice Lines vs Receipt)</h3>
                <p className="text-xs text-slate-500">
                  Periksa kuantitas dan sesuaikan harga satuan tagihan fisik dari supplier untuk memicu kalkulasi varian (PPV).
                </p>
              </div>
              <button
                type="button"
                onClick={handleAddLine}
                className="inline-flex items-center gap-1.5 rounded-xl border border-slate-200 bg-white px-3 py-1.5 text-xs font-semibold text-slate-700 hover:bg-slate-50"
              >
                <Plus className="h-4 w-4" /> Tambah Baris Manual
              </button>
            </div>

            {draftLines.length === 0 ? (
              <div className="p-8 text-center text-sm text-slate-400 border-2 border-dashed border-slate-200 rounded-xl space-y-2">
                <p className="font-semibold text-slate-600">Belum ada baris barang yang dimuat.</p>
                <p className="text-xs text-slate-400">
                  Pilih Supplier dan dokumen **Goods Receipt** di atas untuk mengisi baris barang secara otomatis.
                </p>
              </div>
            ) : (
              <div className="space-y-4">
                {draftLines.map((line, idx) => {
                  const prodUoms = productUoms.filter((pu) => pu.product_id === line.productId)
                  const availableApForProd = openApProvisionals.filter(
                    (ap) =>
                      ap.supplier_id === draftSupplierId &&
                      ap.goods_receipt_lines.product_id === line.productId,
                  )

                  return (
                    <div
                      key={line.clientLineKey}
                      className="rounded-xl border border-slate-200 p-4 space-y-3 bg-slate-50/50"
                    >
                      <div className="flex items-center justify-between">
                        <span className="text-xs font-bold text-slate-500 uppercase">
                          Baris #{idx + 1}
                        </span>
                        <button
                          type="button"
                          onClick={() =>
                            setDraftLines((prev) => prev.filter((_, i) => i !== idx))
                          }
                          className="text-rose-500 hover:text-rose-700"
                        >
                          <Trash2 className="h-4 w-4" />
                        </button>
                      </div>

                      <div className="grid gap-4 md:grid-cols-4">
                        <div>
                          <label className="block text-xs font-semibold text-slate-600 mb-1">
                            Produk
                          </label>
                          <select
                            value={line.productId}
                            onChange={(e) => {
                              const newProdId = e.target.value
                              const uoms = productUoms.filter((pu) => pu.product_id === newProdId)
                              const newUomId = uoms.length ? uoms[0].uom_id : ''
                              setDraftLines((prev) =>
                                prev.map((l, i) =>
                                  i === idx
                                    ? { ...l, productId: newProdId, invoiceUomId: newUomId, allocations: [] }
                                    : l,
                                ),
                              )
                            }}
                            className="w-full rounded-lg border border-slate-200 bg-white px-3 py-2 text-sm focus:border-violet-500 focus:outline-none font-medium"
                          >
                            {products.map((p) => (
                              <option key={p.id} value={p.id}>
                                {p.name} ({p.sku})
                              </option>
                            ))}
                          </select>
                        </div>

                        <div>
                          <label className="block text-xs font-semibold text-slate-600 mb-1">
                            Satuan Invoice (UOM)
                          </label>
                          <select
                            value={line.invoiceUomId}
                            onChange={(e) => {
                              const newUomId = e.target.value
                              setDraftLines((prev) =>
                                prev.map((l, i) =>
                                  i === idx ? { ...l, invoiceUomId: newUomId } : l,
                                ),
                              )
                            }}
                            className="w-full rounded-lg border border-slate-200 bg-white px-3 py-2 text-sm focus:border-violet-500 focus:outline-none font-medium"
                          >
                            {prodUoms.map((pu) => (
                              <option key={pu.uom_id} value={pu.uom_id}>
                                {pu.uoms.name} (Faktor: {pu.factor_to_base})
                              </option>
                            ))}
                          </select>
                        </div>

                        <div>
                          <label className="block text-xs font-semibold text-slate-600 mb-1">
                            Qty Invoice (Tagihan)
                          </label>
                          <input
                            type="number"
                            step="any"
                            min="0.0001"
                            value={line.invoiceQty}
                            onChange={(e) => {
                              const v = Number(e.target.value)
                              setDraftLines((prev) =>
                                prev.map((l, i) => (i === idx ? { ...l, invoiceQty: v } : l)),
                              )
                            }}
                            className="w-full rounded-lg border border-slate-200 bg-white px-3 py-2 text-sm font-semibold focus:border-violet-500 focus:outline-none"
                          />
                        </div>

                        <div>
                          <label className="block text-xs font-semibold text-slate-600 mb-1">
                            Harga Satuan Tagihan (Rp)
                          </label>
                          <input
                            type="number"
                            step="any"
                            min="0"
                            value={line.unitPrice}
                            onChange={(e) => {
                              const v = Number(e.target.value)
                              setDraftLines((prev) =>
                                prev.map((l, i) => (i === idx ? { ...l, unitPrice: v } : l)),
                              )
                            }}
                            className="w-full rounded-lg border border-slate-200 bg-white px-3 py-2 text-sm font-bold text-slate-900 focus:border-violet-500 focus:outline-none"
                          />
                        </div>

                        <div className="md:col-span-2">
                          <label className="block text-xs font-semibold text-slate-600 mb-1">
                            Aturan Pajak Pembelian (Opsional)
                          </label>
                          <select
                            value={line.taxRuleId}
                            onChange={(e) => {
                              const v = e.target.value
                              setDraftLines((prev) =>
                                prev.map((l, i) => (i === idx ? { ...l, taxRuleId: v } : l)),
                              )
                            }}
                            className="w-full rounded-lg border border-slate-200 bg-white px-3 py-2 text-sm focus:border-violet-500 focus:outline-none"
                          >
                            <option value="">-- Tanpa Pajak --</option>
                            {taxRules.map((t) => (
                              <option key={t.id} value={t.id}>
                                {t.tax_name} ({t.tax_code}) - Rate: {t.tax_rule_versions[0]?.rate_percent}%
                              </option>
                            ))}
                          </select>
                        </div>
                      </div>

                      {/* Allocations Sub-Section */}
                      <div className="mt-3 border-t border-slate-200 pt-3">
                        <div className="flex items-center justify-between mb-2">
                          <span className="text-xs font-bold text-slate-700">
                            Alokasi ke Goods Receipt (AP Provisional)
                          </span>
                          {availableApForProd.length > 0 && (
                            <button
                              type="button"
                              onClick={() => {
                                const firstAp = availableApForProd[0]
                                setDraftLines((prev) =>
                                  prev.map((l, i) => {
                                    if (i !== idx) return l
                                    return {
                                      ...l,
                                      allocations: [
                                        ...l.allocations,
                                        {
                                          clientAllocationKey: crypto.randomUUID(),
                                          sourceApProvisionalId: firstAp.id,
                                          quantityBase: 1,
                                        },
                                      ],
                                    }
                                  }),
                                )
                              }}
                              className="text-xs font-semibold text-violet-600 hover:text-violet-800"
                            >
                              + Tambah Alokasi Manual
                            </button>
                          )}
                        </div>

                        {line.allocations.length === 0 ? (
                          <div className="text-xs text-slate-400 italic">
                            {availableApForProd.length === 0
                              ? 'Tidak ada Penerimaan Barang (AP Provisional) OPEN yang cocok untuk supplier & produk ini.'
                              : 'Belum dialokasikan ke Penerimaan Barang mana pun.'}
                          </div>
                        ) : (
                          <div className="space-y-2">
                            {line.allocations.map((alloc, aIdx) => (
                              <div
                                key={alloc.clientAllocationKey}
                                className="flex items-center gap-3 bg-white p-2.5 rounded-lg border border-slate-200 text-xs"
                              >
                                <div className="flex-1">
                                  <label className="block text-[10px] text-slate-400 mb-0.5">
                                    Sumber Receipt AP Provisional
                                  </label>
                                  <select
                                    value={alloc.sourceApProvisionalId}
                                    onChange={(e) => {
                                      const newApId = e.target.value
                                      setDraftLines((prev) =>
                                        prev.map((l, i) => {
                                          if (i !== idx) return l
                                          const newAllocs = l.allocations.map((a, ai) =>
                                            ai === aIdx ? { ...a, sourceApProvisionalId: newApId } : a,
                                          )
                                          return { ...l, allocations: newAllocs }
                                        }),
                                      )
                                    }}
                                    className="w-full rounded border border-slate-200 p-1 font-medium"
                                  >
                                    {availableApForProd.map((ap) => (
                                      <option key={ap.id} value={ap.id}>
                                        {ap.goods_receipt_documents?.receipt_no || 'Receipt'} - Qty Base Accepted:{' '}
                                        {ap.goods_receipt_lines?.accepted_good_base_qty || 0} - Estimasi Nominal:{' '}
                                        {rupiah(ap.amount)}
                                      </option>
                                    ))}
                                  </select>
                                </div>

                                <div className="w-32">
                                  <label className="block text-[10px] text-slate-400 mb-0.5">
                                    Alloc Base Qty
                                  </label>
                                  <input
                                    type="number"
                                    step="any"
                                    min="0.0001"
                                    value={alloc.quantityBase}
                                    onChange={(e) => {
                                      const v = Number(e.target.value)
                                      setDraftLines((prev) =>
                                        prev.map((l, i) => {
                                          if (i !== idx) return l
                                          const newAllocs = l.allocations.map((a, ai) =>
                                            ai === aIdx ? { ...a, quantityBase: v } : a,
                                          )
                                          return { ...l, allocations: newAllocs }
                                        }),
                                      )
                                    }}
                                    className="w-full rounded border border-slate-200 p-1 font-semibold"
                                  />
                                </div>

                                <button
                                  type="button"
                                  onClick={() => {
                                    setDraftLines((prev) =>
                                      prev.map((l, i) => {
                                        if (i !== idx) return l
                                        return {
                                          ...l,
                                          allocations: l.allocations.filter((_, ai) => ai !== aIdx),
                                        }
                                      }),
                                    )
                                  }}
                                  className="text-rose-500 hover:text-rose-700 pt-3"
                                >
                                  <X className="h-4 w-4" />
                                </button>
                              </div>
                            ))}
                          </div>
                        )}
                      </div>
                    </div>
                  )
                })}
              </div>
            )}

            {/* Actions */}
            <div className="flex items-center justify-end gap-3 border-t border-slate-100 pt-4">
              <button
                type="button"
                onClick={() => setActiveTab('invoices')}
                className="rounded-xl border border-slate-200 px-5 py-2.5 text-sm font-semibold text-slate-600 hover:bg-slate-50"
              >
                Batal
              </button>
              <button
                type="submit"
                disabled={isSubmitting || draftLines.length === 0}
                className="inline-flex items-center gap-2 rounded-xl bg-violet-600 px-6 py-2.5 text-sm font-semibold text-white shadow-sm hover:bg-violet-700 disabled:opacity-50"
              >
                {isSubmitting ? 'Memproses...' : 'Simpan Draf Faktur & Cocokkan'}
              </button>
            </div>
          </div>
        </form>
      )}

      {/* TAB 3: POLICIES */}
      {activeTab === 'policies' && (
        <div className="space-y-4">
          <div className="flex items-center justify-between">
            <h2 className="text-lg font-bold text-slate-900">Kebijakan Toleransi Three-Way Matching</h2>
            {canManagePolicy && <button
              onClick={() => {
                setPolicyForm({
                  supplierId: '',
                  quantityTolerancePercent: 0,
                  quantityToleranceBaseQty: '',
                  valueTolerancePercent: 0,
                  valueToleranceAmount: '',
                  effectiveFrom: new Date().toISOString().split('T')[0],
                  isActive: true,
                })
                setPolicyModal({ open: true, editing: null })
              }}
              className="inline-flex items-center gap-2 rounded-xl bg-violet-600 px-4 py-2.5 text-sm font-semibold text-white shadow-sm hover:bg-violet-700"
            >
              <Plus className="h-4 w-4" /> Tambah Kebijakan
            </button>}
          </div>

          <div className="overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-sm">
            <table className="w-full text-left text-sm">
              <thead className="border-b border-slate-100 bg-slate-50 text-xs font-semibold uppercase tracking-wider text-slate-500">
                <tr>
                  <th className="px-5 py-4">Cakupan (Supplier)</th>
                  <th className="px-5 py-4">Toleransi Kuantitas (%)</th>
                  <th className="px-5 py-4">Batas Max Kuantitas</th>
                  <th className="px-5 py-4">Toleransi Nilai (%)</th>
                  <th className="px-5 py-4">Batas Nominal Nilai</th>
                  <th className="px-5 py-4">Efektif Dari</th>
                  <th className="px-5 py-4">Status</th>
                  <th className="px-5 py-4 text-right">Aksi</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {policies.map((p) => {
                  const supp = p.supplier_id ? supplierMap[p.supplier_id] : null
                  return (
                    <tr key={p.id} className="hover:bg-slate-50/50">
                      <td className="px-5 py-4 font-bold text-slate-900">
                        {supp ? `${supp.supplier_name} (${supp.supplier_code})` : 'Company Default (Semua Supplier)'}
                      </td>
                      <td className="px-5 py-4 font-semibold text-slate-700">{p.quantity_tolerance_percent}%</td>
                      <td className="px-5 py-4 text-slate-600">
                        {p.quantity_tolerance_base_qty !== null ? fmtNum(p.quantity_tolerance_base_qty) : '-'}
                      </td>
                      <td className="px-5 py-4 font-semibold text-slate-700">{p.value_tolerance_percent}%</td>
                      <td className="px-5 py-4 text-slate-600">
                        {p.value_tolerance_amount !== null ? rupiah(p.value_tolerance_amount) : '-'}
                      </td>
                      <td className="px-5 py-4 text-slate-600">
                        {new Date(p.effective_from).toLocaleDateString('id-ID')}
                      </td>
                      <td className="px-5 py-4">
                        {p.is_active ? (
                          <span className="rounded-full bg-emerald-50 px-2.5 py-1 text-xs font-semibold text-emerald-700 border border-emerald-200">
                            Aktif
                          </span>
                        ) : (
                          <span className="rounded-full bg-slate-100 px-2.5 py-1 text-xs font-semibold text-slate-600">
                            Nonaktif
                          </span>
                        )}
                      </td>
                      <td className="px-5 py-4 text-right">
                        {canManagePolicy && <button
                          onClick={() => {
                            setPolicyForm({
                              supplierId: p.supplier_id || '',
                              quantityTolerancePercent: p.quantity_tolerance_percent,
                              quantityToleranceBaseQty: p.quantity_tolerance_base_qty !== null ? String(p.quantity_tolerance_base_qty) : '',
                              valueTolerancePercent: p.value_tolerance_percent,
                              valueToleranceAmount: p.value_tolerance_amount !== null ? String(p.value_tolerance_amount) : '',
                              effectiveFrom: p.effective_from,
                              isActive: p.is_active,
                            })
                            setPolicyModal({ open: true, editing: p })
                          }}
                          className="rounded-lg border border-slate-200 bg-white px-3 py-1.5 text-xs font-semibold text-slate-700 shadow-sm hover:bg-slate-50"
                        >
                          Edit
                        </button>}
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {/* DETAIL MODAL */}
      {selectedDoc && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-slate-900/50 p-4 backdrop-blur-sm">
          <div className="w-full max-w-4xl max-h-[90vh] overflow-y-auto rounded-2xl bg-white p-6 shadow-xl space-y-6">
            <div className="flex items-center justify-between border-b border-slate-100 pb-4">
              <div>
                <h3 className="text-xl font-bold text-slate-900">
                  Detail Faktur Supplier: {selectedDoc.invoice_no}
                </h3>
                <p className="text-sm text-slate-500">No Invoice Supplier: {selectedDoc.supplier_invoice_no}</p>
              </div>
              <button onClick={() => setSelectedDoc(null)} className="text-slate-400 hover:text-slate-600">
                <X className="h-6 w-6" />
              </button>
            </div>

            {/* Header info */}
            <div className="grid gap-4 md:grid-cols-3 bg-slate-50 p-4 rounded-xl text-sm">
              <div>
                <span className="text-xs text-slate-400 block">Supplier</span>
                <span className="font-bold text-slate-900">
                  {supplierMap[selectedDoc.supplier_id]?.supplier_name || 'N/A'}
                </span>
              </div>
              <div>
                <span className="text-xs text-slate-400 block">Status Dokumen</span>
                {renderDocStatusBadge(selectedDoc.status)}
              </div>
              <div>
                <span className="text-xs text-slate-400 block">Status Matching</span>
                {renderMatchingBadge(selectedDoc.matching_status)}
              </div>
              <div>
                <span className="text-xs text-slate-400 block">Tanggal Faktur</span>
                <span className="font-medium text-slate-700">{selectedDoc.invoice_date}</span>
              </div>
              <div>
                <span className="text-xs text-slate-400 block">Mode Harga</span>
                <span className="font-medium text-slate-700">{selectedDoc.price_mode}</span>
              </div>
              <div>
                <span className="text-xs text-slate-400 block">Grand Total</span>
                <span className="font-bold text-slate-900">{rupiah(selectedDoc.grand_total)}</span>
              </div>
              <div>
                <span className="text-xs text-slate-400 block">Dibuat Oleh</span>
                <span className="font-medium text-slate-700">
                  {profileMap[selectedDoc.created_by] || selectedDoc.created_by}
                </span>
              </div>
            </div>

            {/* Items */}
            <div>
              <h4 className="text-sm font-bold text-slate-900 mb-3">Rincian Barang</h4>
              <div className="overflow-x-auto rounded-xl border border-slate-200">
                <table className="w-full text-left text-xs">
                  <thead className="bg-slate-50 font-semibold text-slate-500 uppercase">
                    <tr>
                      <th className="px-4 py-3">Produk</th>
                      <th className="px-4 py-3">Satuan</th>
                      <th className="px-4 py-3 text-right">Qty Invoice</th>
                      <th className="px-4 py-3 text-right">Harga Satuan</th>
                      <th className="px-4 py-3 text-right">Pajak</th>
                      <th className="px-4 py-3 text-right">Total Line</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-slate-100">
                    {lines
                      .filter((l) => l.document_id === selectedDoc.id)
                      .map((l) => (
                        <tr key={l.id}>
                          <td className="px-4 py-3 font-medium text-slate-900">
                            {l.product_name_snapshot} ({l.product_sku_snapshot})
                          </td>
                          <td className="px-4 py-3 text-slate-600">{l.invoice_uom_name_snapshot}</td>
                          <td className="px-4 py-3 text-right font-medium">{fmtNum(l.invoice_qty)}</td>
                          <td className="px-4 py-3 text-right font-medium">{rupiah(l.unit_price_input)}</td>
                          <td className="px-4 py-3 text-right text-slate-600">
                            {l.tax_code_snapshot ? `${l.tax_code_snapshot} (${rupiah(l.tax_amount)})` : '-'}
                          </td>
                          <td className="px-4 py-3 text-right font-bold text-slate-900">{rupiah(l.line_total)}</td>
                        </tr>
                      ))}
                  </tbody>
                </table>
              </div>
            </div>

            {/* Allocations */}
            <div>
              <h4 className="text-sm font-bold text-slate-900 mb-3">Alokasi Penerimaan Barang (AP Provisional)</h4>
              <div className="overflow-x-auto rounded-xl border border-slate-200">
                <table className="w-full text-left text-xs">
                  <thead className="bg-slate-50 font-semibold text-slate-500 uppercase">
                    <tr>
                      <th className="px-4 py-3">Sumber AP Provisional ID</th>
                      <th className="px-4 py-3 text-right">Allocated Base Qty</th>
                      <th className="px-4 py-3 text-right">Nominal Provisional</th>
                      <th className="px-4 py-3 text-right">Nominal Aktual</th>
                      <th className="px-4 py-3 text-right">Selisih Varian (PPV)</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-slate-100">
                    {allocations
                      .filter((a) => a.document_id === selectedDoc.id)
                      .map((a) => (
                        <tr key={a.id}>
                          <td className="px-4 py-3 font-mono text-[11px] text-slate-600">
                            {a.source_ap_provisional_id}
                          </td>
                          <td className="px-4 py-3 text-right font-medium">{fmtNum(a.allocated_base_qty)}</td>
                          <td className="px-4 py-3 text-right text-slate-600">
                            {rupiah(a.provisional_value)}
                          </td>
                          <td className="px-4 py-3 text-right text-slate-700 font-medium">
                            {rupiah(a.actual_value)}
                          </td>
                          <td className="px-4 py-3 text-right font-bold text-amber-700">
                            {rupiah(a.price_variance)}
                          </td>
                        </tr>
                      ))}
                  </tbody>
                </table>
              </div>
            </div>

            {/* Tolerance evaluation result */}
            {toleranceResults.some((tr) => tr.document_id === selectedDoc.id) && (
              <div className="rounded-xl border border-slate-200 bg-slate-50 p-4 space-y-2">
                <h4 className="text-xs font-bold uppercase tracking-wider text-slate-600">Hasil Evaluasi Toleransi</h4>
                {toleranceResults
                  .filter((tr) => tr.document_id === selectedDoc.id)
                  .map((tr) => (
                    <div key={tr.id} className="text-xs space-y-1 text-slate-700">
                      <div>
                        • Status Result Matching: <strong>{tr.result_status}</strong>
                      </div>
                      <div>
                        • Varian Kuantitas Base: {fmtNum(tr.quantity_variance_base_qty)} (Toleransi: {tr.quantity_tolerance_percent_snapshot}%)
                      </div>
                      <div>
                        • Varian Nilai Total: {rupiah(tr.value_variance)} (Toleransi: {tr.value_tolerance_percent_snapshot}%)
                      </div>
                    </div>
                  ))}
              </div>
            )}

            <div className="flex justify-end border-t border-slate-100 pt-4">
              <button
                onClick={() => setSelectedDoc(null)}
                className="rounded-xl bg-slate-900 px-5 py-2.5 text-sm font-semibold text-white shadow-sm hover:bg-slate-800"
              >
                Tutup
              </button>
            </div>
          </div>
        </div>
      )}

      {/* VALIDATE MODAL */}
      {validateModalDoc && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-slate-900/50 p-4 backdrop-blur-sm">
          <div className="w-full max-w-md rounded-2xl bg-white p-6 shadow-xl space-y-6">
            <div className="flex items-center gap-3 text-emerald-600">
              <ShieldCheck className="h-7 w-7 shrink-0" />
              <h3 className="text-lg font-bold text-slate-900">Validasi Faktur Supplier</h3>
            </div>
            <p className="text-sm text-slate-600">
              Apakah Anda yakin ingin memvalidasi Faktur Supplier <strong>{validateModalDoc.invoice_no}</strong>?
              Validasi akan mengunci faktur, mencatat alokasi penerimaan barang, dan menerbitkan Financial Event <code>SUPPLIER_INVOICE_VALIDATED</code>.
            </p>

            <div className="flex justify-end gap-3 pt-4 border-t border-slate-100">
              <button
                onClick={() => setValidateModalDoc(null)}
                className="rounded-xl border border-slate-200 px-4 py-2 text-sm font-semibold text-slate-600 hover:bg-slate-50"
              >
                Batal
              </button>
              <button
                onClick={handleValidateSubmit}
                disabled={isSubmitting}
                className="rounded-xl bg-emerald-600 px-5 py-2 text-sm font-semibold text-white shadow-sm hover:bg-emerald-700 disabled:opacity-50"
              >
                {isSubmitting ? 'Memproses...' : 'Ya, Validasi Faktur'}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* CANCEL MODAL */}
      {cancelModalDoc && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-slate-900/50 p-4 backdrop-blur-sm">
          <div className="w-full max-w-md rounded-2xl bg-white p-6 shadow-xl space-y-6">
            <div className="flex items-center gap-3 text-rose-600">
              <XCircle className="h-7 w-7 shrink-0" />
              <h3 className="text-lg font-bold text-slate-900">Pembatalan Faktur Supplier</h3>
            </div>
            <p className="text-sm text-slate-600">
              Anda akan membatalkan Faktur Supplier <strong>{cancelModalDoc.invoice_no}</strong>. Tindakan ini tidak dapat dibatalkan.
            </p>

            <div>
              <label className="block text-xs font-bold uppercase tracking-wider text-slate-600 mb-2">
                Alasan Pembatalan *
              </label>
              <textarea
                rows={3}
                value={cancelReason}
                onChange={(e) => setCancelReason(e.target.value)}
                placeholder="Masukkan alasan lengkap pembatalan faktur..."
                required
                className="w-full rounded-xl border border-slate-200 p-3 text-sm focus:border-rose-500 focus:outline-none"
              />
            </div>

            <div className="flex justify-end gap-3 pt-4 border-t border-slate-100">
              <button
                onClick={() => {
                  setCancelModalDoc(null)
                  setCancelReason('')
                }}
                className="rounded-xl border border-slate-200 px-4 py-2 text-sm font-semibold text-slate-600 hover:bg-slate-50"
              >
                Batal
              </button>
              <button
                onClick={handleCancelSubmit}
                disabled={isSubmitting || !cancelReason.trim()}
                className="rounded-xl bg-rose-600 px-5 py-2 text-sm font-semibold text-white shadow-sm hover:bg-rose-700 disabled:opacity-50"
              >
                {isSubmitting ? 'Membatalkan...' : 'Konfirmasi Pembatalan'}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* POLICY MODAL */}
      {policyModal.open && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-slate-900/50 p-4 backdrop-blur-sm">
          <form onSubmit={handleSavePolicySubmit} className="w-full max-w-lg rounded-2xl bg-white p-6 shadow-xl space-y-6">
            <div className="flex items-center justify-between border-b border-slate-100 pb-4">
              <h3 className="text-lg font-bold text-slate-900">
                {policyModal.editing ? 'Edit Kebijakan Toleransi' : 'Tambah Kebijakan Toleransi'}
              </h3>
              <button
                type="button"
                onClick={() => setPolicyModal({ open: false, editing: null })}
                className="text-slate-400 hover:text-slate-600"
              >
                <X className="h-5 w-5" />
              </button>
            </div>

            <div className="space-y-4 text-sm">
              <div>
                <label className="block text-xs font-bold uppercase text-slate-600 mb-1">
                  Supplier (Opsional)
                </label>
                <select
                  value={policyForm.supplierId}
                  onChange={(e) => setPolicyForm({ ...policyForm, supplierId: e.target.value })}
                  className="w-full rounded-xl border border-slate-200 px-3 py-2 text-sm focus:border-violet-500 focus:outline-none"
                >
                  <option value="">-- Company Default (Semua Supplier) --</option>
                  {suppliers.map((s) => (
                    <option key={s.id} value={s.id}>
                      {s.supplier_name} ({s.supplier_code})
                    </option>
                  ))}
                </select>
              </div>

              <div className="grid gap-4 sm:grid-cols-2">
                <div>
                  <label className="block text-xs font-bold uppercase text-slate-600 mb-1">
                    Toleransi Kuantitas (%) *
                  </label>
                  <input
                    type="number"
                    step="any"
                    min="0"
                    max="100"
                    value={policyForm.quantityTolerancePercent}
                    onChange={(e) =>
                      setPolicyForm({ ...policyForm, quantityTolerancePercent: Number(e.target.value) })
                    }
                    required
                    className="w-full rounded-xl border border-slate-200 px-3 py-2 text-sm focus:border-violet-500 focus:outline-none"
                  />
                </div>

                <div>
                  <label className="block text-xs font-bold uppercase text-slate-600 mb-1">
                    Batas Qty Base (Opsional)
                  </label>
                  <input
                    type="number"
                    step="any"
                    min="0"
                    value={policyForm.quantityToleranceBaseQty}
                    onChange={(e) =>
                      setPolicyForm({ ...policyForm, quantityToleranceBaseQty: e.target.value })
                    }
                    placeholder="Contoh: 10"
                    className="w-full rounded-xl border border-slate-200 px-3 py-2 text-sm focus:border-violet-500 focus:outline-none"
                  />
                </div>
              </div>

              <div className="grid gap-4 sm:grid-cols-2">
                <div>
                  <label className="block text-xs font-bold uppercase text-slate-600 mb-1">
                    Toleransi Nilai (%) *
                  </label>
                  <input
                    type="number"
                    step="any"
                    min="0"
                    max="100"
                    value={policyForm.valueTolerancePercent}
                    onChange={(e) =>
                      setPolicyForm({ ...policyForm, valueTolerancePercent: Number(e.target.value) })
                    }
                    required
                    className="w-full rounded-xl border border-slate-200 px-3 py-2 text-sm focus:border-violet-500 focus:outline-none"
                  />
                </div>

                <div>
                  <label className="block text-xs font-bold uppercase text-slate-600 mb-1">
                    Batas Nominal Nominal (Rp)
                  </label>
                  <input
                    type="number"
                    step="any"
                    min="0"
                    value={policyForm.valueToleranceAmount}
                    onChange={(e) =>
                      setPolicyForm({ ...policyForm, valueToleranceAmount: e.target.value })
                    }
                    placeholder="Contoh: 50000"
                    className="w-full rounded-xl border border-slate-200 px-3 py-2 text-sm focus:border-violet-500 focus:outline-none"
                  />
                </div>
              </div>

              <div>
                <label className="block text-xs font-bold uppercase text-slate-600 mb-1">
                  Efektif Dari *
                </label>
                <input
                  type="date"
                  value={policyForm.effectiveFrom}
                  onChange={(e) => setPolicyForm({ ...policyForm, effectiveFrom: e.target.value })}
                  required
                  className="w-full rounded-xl border border-slate-200 px-3 py-2 text-sm focus:border-violet-500 focus:outline-none"
                />
              </div>

              <div className="flex items-center gap-2 pt-2">
                <input
                  type="checkbox"
                  id="isActiveCheck"
                  checked={policyForm.isActive}
                  onChange={(e) => setPolicyForm({ ...policyForm, isActive: e.target.checked })}
                  className="h-4 w-4 rounded border-slate-300 text-violet-600 focus:ring-violet-500"
                />
                <label htmlFor="isActiveCheck" className="text-sm font-semibold text-slate-700">
                  Kebijakan Aktif
                </label>
              </div>
            </div>

            <div className="flex justify-end gap-3 pt-4 border-t border-slate-100">
              <button
                type="button"
                onClick={() => setPolicyModal({ open: false, editing: null })}
                className="rounded-xl border border-slate-200 px-4 py-2 text-sm font-semibold text-slate-600 hover:bg-slate-50"
              >
                Batal
              </button>
              <button
                type="submit"
                disabled={isSubmitting}
                className="rounded-xl bg-violet-600 px-5 py-2 text-sm font-semibold text-white shadow-sm hover:bg-violet-700 disabled:opacity-50"
              >
                {isSubmitting ? 'Memproses...' : 'Simpan Kebijakan'}
              </button>
            </div>
          </form>
        </div>
      )}
    </div>
  )
}
