'use client'

import { useCallback, useEffect, useMemo, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import { Banknote, CheckCircle2, Download, Loader2, Plus, RefreshCcw, Search, XCircle } from 'lucide-react'

type Document = {
  id: string; receipt_no: string; customer_id: string; receipt_date: string
  payment_method_id: string; payment_method_name_snapshot: string; reference_no: string | null
  evidence_url: string | null; notes: string | null; total_amount: number
  status: 'DRAFT' | 'POSTED' | 'CANCELED'; master_version: number; created_at: string
  received_amount: number; unapplied_amount: number; unapplied_disposition: 'NONE' | 'CUSTOMER_BALANCE'
}
type Allocation = { document_id: string; sales_id: string; client_allocation_key: string; allocated_amount: number }
type Invoice = { salesId: string; invoiceNo: string; customerId: string; transactionDate: string; dueDate: string | null; originalReceivable: number; allocatedAmount: number; remainingAmount: number }
type Customer = { id: string; code: string; name: string }
type Method = { id: string; name: string; type: string; settlementRoute: string }
type Payload = { documents: Document[]; allocations: Allocation[]; openInvoices: Invoice[]; customers: Customer[]; paymentMethods: Method[]; advancePolicy: { lifecycleState: string; advanceEnabled: boolean } }
type AgingInvoice = { salesId: string; invoiceNo: string; customerId: string; customerCode: string; customerName: string; storeName: string | null; transactionDate: string; dueDate: string | null; originalReceivable: number; allocatedAmount: number; outstanding: number; agingBucket: string; overdueDays: number }
type Aging = { asOf: string; summary: { invoiceCount: number; customerCount: number; outstanding: number; overdue: number }; buckets: Array<{ bucket: string; invoiceCount: number; customerCount: number; outstanding: number }>; invoices: AgingInvoice[] }
type StatementRow = { sequence: number; sourceType: 'INVOICE' | 'RECEIPT'; documentNo: string; businessDate: string; dueDate: string | null; storeName: string | null; description: string; debit: number; credit: number; runningBalance: number }
type Statement = { customer: Customer; dateFrom: string; asOf: string; openingBalance: number; periodDebit: number; periodCredit: number; endingBalance: number; rows: StatementRow[] }
type ReportPayload = { aging: Aging; statement: Statement | null }

const rupiah = (value: number) => new Intl.NumberFormat('id-ID', { style: 'currency', currency: 'IDR', maximumFractionDigits: 0 }).format(Number(value) || 0)
const date = (value: string | null) => value ? new Date(value).toLocaleDateString('id-ID', { day: '2-digit', month: 'short', year: 'numeric' }) : '-'
const headers = (session: Session) => ({ Authorization: `Bearer ${session.access_token}`, 'Content-Type': 'application/json' })
const today = () => new Date().toISOString().slice(0, 10)

export function CustomerReceiptView({ session, canCreate, canEdit, canPost, canExport }: { session: Session; canCreate: boolean; canEdit: boolean; canPost: boolean; canExport: boolean }) {
  const [payload, setPayload] = useState<Payload | null>(null)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const [query, setQuery] = useState('')
  const [status, setStatus] = useState('ALL')
  const [formOpen, setFormOpen] = useState(false)
  const [documentId, setDocumentId] = useState<string | null>(null)
  const [masterVersion, setMasterVersion] = useState<number | null>(null)
  const [customerId, setCustomerId] = useState('')
  const [receiptDate, setReceiptDate] = useState(today())
  const [methodId, setMethodId] = useState('')
  const [referenceNo, setReferenceNo] = useState('')
  const [evidenceUrl, setEvidenceUrl] = useState('')
  const [notes, setNotes] = useState('')
  const [amounts, setAmounts] = useState<Record<string, string>>({})
  const [keys, setKeys] = useState<Record<string, string>>({})
  const [disposition, setDisposition] = useState<'NONE' | 'CUSTOMER_BALANCE'>('NONE')
  const [advanceAmount, setAdvanceAmount] = useState('')
  const [report, setReport] = useState<ReportPayload | null>(null)
  const [reportLoading, setReportLoading] = useState(false)
  const [reportCustomerId, setReportCustomerId] = useState('')
  const [asOf, setAsOf] = useState(today())
  const [dateFrom, setDateFrom] = useState(() => `${today().slice(0, 8)}01`)

  const load = useCallback(async () => {
    setLoading(true); setError('')
    try {
      const response = await fetch('/api/finance/customer-receipts', { headers: headers(session), cache: 'no-store' })
      const result = await response.json() as Payload & { error?: string }
      if (!response.ok) throw new Error(result.error ?? 'Gagal memuat penerimaan Customer.')
      setPayload(result)
    } catch (caught) { setError(caught instanceof Error ? caught.message : 'Gagal memuat data.') }
    finally { setLoading(false) }
  }, [session])
  useEffect(() => {
    const timer = window.setTimeout(() => { void load() }, 0)
    return () => window.clearTimeout(timer)
  }, [load])

  const loadReport = useCallback(async () => {
    setReportLoading(true); setError('')
    try {
      const query = new URLSearchParams({ asOf, dateFrom })
      if (reportCustomerId) query.set('customerId', reportCustomerId)
      const response = await fetch(`/api/finance/customer-receipts/reports?${query}`, { headers: headers(session), cache: 'no-store' })
      const result = await response.json() as ReportPayload & { error?: string }
      if (!response.ok) throw new Error(result.error ?? 'Gagal memuat laporan piutang.')
      setReport(result)
    } catch (caught) { setError(caught instanceof Error ? caught.message : 'Gagal memuat laporan piutang.') }
    finally { setReportLoading(false) }
  }, [asOf, dateFrom, reportCustomerId, session])
  useEffect(() => {
    const timer = window.setTimeout(() => { void loadReport() }, 0)
    return () => window.clearTimeout(timer)
  }, [loadReport])

  async function downloadReport(type: 'AGING' | 'STATEMENT') {
    if (type === 'STATEMENT' && !reportCustomerId) return setError('Pilih Customer untuk export statement.')
    setReportLoading(true); setError('')
    try {
      const query = new URLSearchParams({ type, asOf, dateFrom })
      if (reportCustomerId) query.set('customerId', reportCustomerId)
      const response = await fetch(`/api/finance/customer-receipts/reports/export?${query}`, { headers: headers(session), cache: 'no-store' })
      if (!response.ok) { const result = await response.json() as { error?: string }; throw new Error(result.error ?? 'Export gagal.') }
      const blob = await response.blob(); const disposition = response.headers.get('content-disposition') ?? ''
      const fileName = disposition.match(/filename="([^"]+)"/)?.[1] ?? `${type}.xlsx`
      const url = URL.createObjectURL(blob); const anchor = document.createElement('a')
      anchor.href = url; anchor.download = fileName; anchor.click(); URL.revokeObjectURL(url)
    } catch (caught) { setError(caught instanceof Error ? caught.message : 'Export gagal.') }
    finally { setReportLoading(false) }
  }

  const customers = useMemo(() => new Map((payload?.customers ?? []).map((row) => [row.id, row])), [payload])
  const invoices = useMemo(() => (payload?.openInvoices ?? []).filter((row) => row.customerId === customerId), [payload, customerId])
  const selectedAllocations = useMemo(() => invoices.map((invoice) => ({ invoice, amount: Number(amounts[invoice.salesId] ?? 0) })).filter((row) => row.amount > 0), [invoices, amounts])
  const allocatedTotal = selectedAllocations.reduce((sum, row) => sum + row.amount, 0)
  const total = disposition === 'CUSTOMER_BALANCE' ? Number(advanceAmount || 0) : allocatedTotal
  const documents = useMemo(() => (payload?.documents ?? []).filter((row) => {
    const customer = customers.get(row.customer_id)
    const haystack = `${row.receipt_no} ${row.reference_no ?? ''} ${customer?.name ?? ''}`.toLowerCase()
    return (status === 'ALL' || row.status === status) && haystack.includes(query.trim().toLowerCase())
  }), [payload, customers, query, status])

  function reset() {
    setDocumentId(null); setMasterVersion(null); setCustomerId(''); setReceiptDate(today())
    setMethodId(''); setReferenceNo(''); setEvidenceUrl(''); setNotes(''); setAmounts({}); setKeys({});
    setDisposition('NONE'); setAdvanceAmount(''); setFormOpen(false)
  }
  function openDraft(row: Document) {
    const allocations = (payload?.allocations ?? []).filter((item) => item.document_id === row.id)
    setDocumentId(row.id); setMasterVersion(Number(row.master_version)); setCustomerId(row.customer_id)
    setReceiptDate(row.receipt_date); setMethodId(row.payment_method_id); setReferenceNo(row.reference_no ?? '')
    setEvidenceUrl(row.evidence_url ?? ''); setNotes(row.notes ?? '')
    setDisposition(row.unapplied_disposition ?? 'NONE')
    setAdvanceAmount(row.unapplied_disposition === 'CUSTOMER_BALANCE' ? String(row.received_amount) : '')
    setAmounts(Object.fromEntries(allocations.map((item) => [item.sales_id, String(item.allocated_amount)])))
    setKeys(Object.fromEntries(allocations.map((item) => [item.sales_id, item.client_allocation_key])))
    setFormOpen(true); setError(''); setNotice('')
  }
  async function action(body: Record<string, unknown>, success: string) {
    setBusy(true); setError(''); setNotice('')
    try {
      const response = await fetch('/api/finance/customer-receipts', { method: 'POST', headers: headers(session), body: JSON.stringify(body) })
      const result = await response.json() as { error?: string }
      if (!response.ok) throw new Error(result.error ?? 'Operasi gagal.')
      reset(); setNotice(success); await load()
    } catch (caught) { setError(caught instanceof Error ? caught.message : 'Operasi gagal.') }
    finally { setBusy(false) }
  }
  async function saveDraft() {
    if (!customerId || !methodId) return setError('Customer dan metode pembayaran wajib dipilih.')
    if (disposition === 'NONE' && !selectedAllocations.length) return setError('Isi minimal satu alokasi invoice.')
    if (disposition === 'NONE' && selectedAllocations.some(({ invoice, amount }) => amount > Number(invoice.remainingAmount))) return setError('Alokasi tidak boleh melebihi sisa piutang.')
    if (disposition === 'CUSTOMER_BALANCE' && (!Number.isFinite(Number(advanceAmount)) || Number(advanceAmount) <= 0)) return setError('Nominal advance harus lebih dari nol.')
    const allocations = disposition === 'NONE' ? selectedAllocations.map(({ invoice, amount }) => ({ salesId: invoice.salesId, clientAllocationKey: keys[invoice.salesId] ?? crypto.randomUUID(), allocatedAmount: amount })) : []
    await action({ action: 'SAVE_DRAFT', documentId, masterVersion, customerId, receiptDate, paymentMethodId: methodId, referenceNo, evidenceUrl, notes, receivedAmount: total, unappliedDisposition: disposition, allocations }, 'Draft penerimaan Customer tersimpan.')
  }
  async function post(row: Document) {
    if (!window.confirm(`Posting ${row.receipt_no} senilai ${rupiah(row.total_amount)}?`)) return
    await action({ action: 'POST', documentId: row.id, masterVersion: Number(row.master_version), idempotencyKey: crypto.randomUUID() }, 'Penerimaan Customer berhasil diposting.')
  }
  async function cancel(row: Document) {
    const reason = window.prompt('Alasan pembatalan draft:')?.trim()
    if (!reason) return
    await action({ action: 'CANCEL', documentId: row.id, masterVersion: Number(row.master_version), reason }, 'Draft penerimaan dibatalkan.')
  }

  return <div>
    <header className="flex flex-wrap items-start justify-between gap-4"><div><p className="text-xs font-black uppercase tracking-[0.2em] text-violet-600">Finance · Piutang</p><h1 className="mt-1 text-3xl font-black">Penerimaan Customer</h1><p className="mt-2 text-sm text-slate-600">Catat pembayaran tempo dan alokasikan ke satu atau beberapa invoice Customer.</p></div>{canCreate && <button type="button" onClick={() => { reset(); setFormOpen(true) }} className="inline-flex min-h-11 items-center gap-2 rounded-xl bg-violet-600 px-4 font-black text-white"><Plus className="h-4 w-4" /> Penerimaan baru</button>}</header>
    {notice && <p className="mt-5 rounded-xl border border-emerald-200 bg-emerald-50 p-3 text-sm font-bold text-emerald-800">{notice}</p>}
    {error && <p className="mt-5 rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm font-bold text-rose-800">{error}</p>}
    <section className="mt-6 rounded-2xl border border-slate-200 bg-white shadow-sm">
      <div className="flex flex-wrap items-end gap-3 border-b border-slate-200 p-4">
        <Field label="Per tanggal"><input type="date" max={today()} value={asOf} onChange={(event) => setAsOf(event.target.value)} /></Field>
        <Field label="Mulai statement"><input type="date" max={asOf} value={dateFrom} onChange={(event) => setDateFrom(event.target.value)} /></Field>
        <Field label="Customer (opsional untuk aging)"><select value={reportCustomerId} onChange={(event) => setReportCustomerId(event.target.value)}><option value="">Semua Customer</option>{payload?.customers.map((row) => <option key={row.id} value={row.id}>{row.code} · {row.name}</option>)}</select></Field>
        <button type="button" onClick={() => void loadReport()} disabled={reportLoading} className="inline-flex min-h-11 items-center gap-2 rounded-xl border border-slate-200 px-4 font-black"><RefreshCcw className={`h-4 w-4 ${reportLoading ? 'animate-spin' : ''}`} /> Terapkan</button>
        {canExport && <button type="button" onClick={() => void downloadReport('AGING')} disabled={reportLoading} className="inline-flex min-h-11 items-center gap-2 rounded-xl bg-slate-900 px-4 font-black text-white"><Download className="h-4 w-4" /> Excel aging</button>}
        {canExport && reportCustomerId && <button type="button" onClick={() => void downloadReport('STATEMENT')} disabled={reportLoading} className="inline-flex min-h-11 items-center gap-2 rounded-xl bg-violet-600 px-4 font-black text-white"><Download className="h-4 w-4" /> Excel statement</button>}
      </div>
      <div className="grid gap-3 p-4 sm:grid-cols-2 xl:grid-cols-4">
        <Metric label="Invoice terbuka" value={String(report?.aging.summary.invoiceCount ?? 0)} />
        <Metric label="Customer" value={String(report?.aging.summary.customerCount ?? 0)} />
        <Metric label="Outstanding" value={rupiah(report?.aging.summary.outstanding ?? 0)} />
        <Metric label="Sudah lewat tempo" value={rupiah(report?.aging.summary.overdue ?? 0)} danger />
      </div>
      <div className="overflow-x-auto border-t border-slate-100"><table className="w-full min-w-[980px] text-left text-sm"><thead className="bg-slate-50 text-xs uppercase text-slate-500"><tr><th className="p-3">Invoice</th><th className="p-3">Customer</th><th className="p-3">Tanggal / tempo</th><th className="p-3">Aging</th><th className="p-3 text-right">Awal</th><th className="p-3 text-right">Terbayar</th><th className="p-3 text-right">Outstanding</th></tr></thead><tbody className="divide-y divide-slate-100">{report?.aging.invoices.map((row) => <tr key={row.salesId}><td className="p-3 font-black">{row.invoiceNo}<span className="block text-xs font-normal text-slate-500">{row.storeName ?? 'Tanpa toko'}</span></td><td className="p-3">{row.customerName}<span className="block text-xs text-slate-500">{row.customerCode}</span></td><td className="p-3">{date(row.transactionDate)}<span className="block text-xs text-slate-500">Tempo {date(row.dueDate)}</span></td><td className="p-3"><span className="rounded-full bg-amber-50 px-2 py-1 text-xs font-bold text-amber-800">{agingLabel(row.agingBucket)}</span>{row.overdueDays > 0 && <span className="ml-2 text-xs text-slate-500">{row.overdueDays} hari</span>}</td><td className="p-3 text-right">{rupiah(row.originalReceivable)}</td><td className="p-3 text-right text-emerald-700">{rupiah(row.allocatedAmount)}</td><td className="p-3 text-right font-black">{rupiah(row.outstanding)}</td></tr>)}{!reportLoading && !report?.aging.invoices.length && <tr><td colSpan={7} className="p-8 text-center text-slate-500">Tidak ada piutang terbuka pada filter ini.</td></tr>}</tbody></table></div>
      {report?.statement && <div className="border-t border-slate-200 p-4"><div className="flex flex-wrap items-end justify-between gap-3"><div><p className="text-xs font-black uppercase text-violet-600">Customer Statement</p><h2 className="text-xl font-black">{report.statement.customer.name}</h2><p className="text-sm text-slate-500">{date(report.statement.dateFrom)}–{date(report.statement.asOf)} · Saldo awal {rupiah(report.statement.openingBalance)} · Saldo akhir {rupiah(report.statement.endingBalance)}</p></div></div><div className="mt-4 overflow-x-auto rounded-xl border border-slate-200"><table className="w-full min-w-[900px] text-left text-sm"><thead className="bg-slate-50 text-xs uppercase text-slate-500"><tr><th className="p-3">Tanggal</th><th className="p-3">Dokumen</th><th className="p-3">Keterangan</th><th className="p-3 text-right">Debit</th><th className="p-3 text-right">Kredit</th><th className="p-3 text-right">Saldo</th></tr></thead><tbody className="divide-y divide-slate-100">{report.statement.rows.map((row) => <tr key={`${row.sourceType}-${row.sequence}`}><td className="p-3">{date(row.businessDate)}</td><td className="p-3 font-bold">{row.documentNo}<span className="block text-xs font-normal text-slate-500">{row.sourceType === 'INVOICE' ? 'Invoice' : 'Penerimaan'}</span></td><td className="p-3">{row.description}</td><td className="p-3 text-right">{row.debit ? rupiah(row.debit) : '-'}</td><td className="p-3 text-right text-emerald-700">{row.credit ? rupiah(row.credit) : '-'}</td><td className="p-3 text-right font-black">{rupiah(row.runningBalance)}</td></tr>)}{!report.statement.rows.length && <tr><td colSpan={6} className="p-8 text-center text-slate-500">Tidak ada mutasi pada rentang tanggal ini.</td></tr>}</tbody></table></div></div>}
    </section>
    {formOpen && <section className="mt-6 rounded-2xl border border-violet-200 bg-white p-5 shadow-sm"><div className="flex items-center justify-between"><div><h2 className="text-xl font-black">{documentId ? 'Lanjutkan draft' : 'Penerimaan baru'}</h2><p className="text-sm text-slate-500">Satu penerimaan hanya untuk satu Customer.</p></div><button type="button" onClick={reset} className="rounded-xl border border-slate-200 px-3 py-2 font-bold">Tutup</button></div><div className="mt-5 grid gap-4 lg:grid-cols-3"><Field label="Customer"><select disabled={Boolean(documentId)} value={customerId} onChange={(event) => { setCustomerId(event.target.value); setAmounts({}); setKeys({}) }}><option value="">Pilih Customer</option>{payload?.customers.map((row) => <option key={row.id} value={row.id}>{row.code} · {row.name}</option>)}</select></Field><Field label="Tanggal penerimaan aktual"><input type="date" max={today()} value={receiptDate} onChange={(event) => setReceiptDate(event.target.value)} /></Field><Field label="Metode pembayaran"><select value={methodId} onChange={(event) => setMethodId(event.target.value)}><option value="">Pilih metode</option>{payload?.paymentMethods.map((row) => <option key={row.id} value={row.id}>{row.name} · {row.settlementRoute === 'CASH_DRAWER' ? 'Kas' : 'Bank'}</option>)}</select></Field><Field label="Referensi"><input value={referenceNo} onChange={(event) => setReferenceNo(event.target.value)} placeholder="Nomor transfer / bukti" /></Field><Field label="Link bukti HTTPS"><input type="url" value={evidenceUrl} onChange={(event) => setEvidenceUrl(event.target.value)} placeholder="https://..." /></Field><Field label="Catatan"><input value={notes} onChange={(event) => setNotes(event.target.value)} /></Field></div><div className="mt-5 grid gap-2 sm:grid-cols-2"><button type="button" disabled={Boolean(documentId)} onClick={() => setDisposition('NONE')} className={`rounded-xl border p-3 text-left ${disposition === 'NONE' ? 'border-violet-500 bg-violet-50' : 'border-slate-200'}`}><strong className="block">Alokasikan ke invoice</strong><span className="text-xs text-slate-500">Termasuk pembayaran aktual yang diterima sebelum backorder diinput.</span></button><button type="button" disabled={Boolean(documentId) || !payload?.advancePolicy.advanceEnabled} onClick={() => setDisposition('CUSTOMER_BALANCE')} className={`rounded-xl border p-3 text-left disabled:opacity-50 ${disposition === 'CUSTOMER_BALANCE' ? 'border-violet-500 bg-violet-50' : 'border-slate-200'}`}><strong className="block">Simpan sebagai advance</strong><span className="text-xs text-slate-500">{payload?.advancePolicy.advanceEnabled ? 'Masuk Saldo Customer; tidak menjadi revenue.' : 'Customer Balance Company sedang nonaktif.'}</span></button></div>{disposition === 'CUSTOMER_BALANCE' ? <div className="mt-5 rounded-xl border border-slate-200 p-4"><Field label="Nominal advance"><input type="number" min="0.01" step="0.01" value={advanceAmount} onChange={(event) => setAdvanceAmount(event.target.value)} placeholder="0" /></Field><p className="mt-2 text-xs text-slate-500">Dana belum membayar invoice. Saldo dapat digunakan saat transaksi Customer tersedia.</p></div> : <div className="mt-5 overflow-x-auto rounded-xl border border-slate-200"><table className="w-full min-w-[760px] text-left text-sm"><thead className="bg-slate-50 text-xs uppercase text-slate-500"><tr><th className="p-3">Invoice</th><th className="p-3">Tanggal / jatuh tempo</th><th className="p-3 text-right">Sisa piutang</th><th className="p-3">Alokasi bayar</th></tr></thead><tbody className="divide-y divide-slate-100">{invoices.map((row) => <tr key={row.salesId}><td className="p-3 font-black">{row.invoiceNo}</td><td className="p-3">{date(row.transactionDate)}<span className="block text-xs text-slate-500">Tempo {date(row.dueDate)}</span></td><td className="p-3 text-right font-bold">{rupiah(row.remainingAmount)}</td><td className="p-3"><input type="number" min="0" max={row.remainingAmount} step="0.01" value={amounts[row.salesId] ?? ''} onChange={(event) => { setAmounts((current) => ({ ...current, [row.salesId]: event.target.value })); setKeys((current) => current[row.salesId] ? current : ({ ...current, [row.salesId]: crypto.randomUUID() })) }} className="min-h-10 w-48 rounded-lg border border-slate-200 px-3" placeholder="0" /></td></tr>)}{customerId && !invoices.length && <tr><td colSpan={4} className="p-8 text-center text-slate-500">Tidak ada invoice tempo yang masih terbuka.</td></tr>}{!customerId && <tr><td colSpan={4} className="p-8 text-center text-slate-500">Pilih Customer untuk melihat invoice.</td></tr>}</tbody></table></div>}<div className="mt-5 flex flex-wrap items-center justify-between gap-3 rounded-xl bg-violet-50 p-4"><div><span className="text-xs font-bold uppercase text-violet-700">Total penerimaan</span><strong className="block text-2xl text-violet-950">{rupiah(total)}</strong></div><button type="button" disabled={busy || !(documentId ? canEdit : canCreate)} onClick={() => void saveDraft()} className="inline-flex min-h-11 items-center gap-2 rounded-xl bg-violet-600 px-5 font-black text-white disabled:opacity-50">{busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <Banknote className="h-4 w-4" />} Simpan draft</button></div></section>}
    <section className="mt-6 rounded-2xl border border-slate-200 bg-white shadow-sm"><div className="flex flex-wrap gap-3 border-b border-slate-200 p-4"><label className="relative min-w-64 flex-1"><Search className="absolute left-3 top-3.5 h-4 w-4 text-slate-400"/><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Cari nomor, Customer, atau referensi" className="min-h-11 w-full rounded-xl border border-slate-200 pl-10 pr-3"/></label><select value={status} onChange={(event) => setStatus(event.target.value)} className="min-h-11 rounded-xl border border-slate-200 px-3 font-bold"><option value="ALL">Semua status</option><option value="DRAFT">Draft</option><option value="POSTED">Posted</option><option value="CANCELED">Dibatalkan</option></select><button type="button" onClick={() => void load()} className="grid h-11 w-11 place-items-center rounded-xl border border-slate-200"><RefreshCcw className={`h-4 w-4 ${loading ? 'animate-spin' : ''}`}/></button></div><div className="overflow-x-auto"><table className="w-full min-w-[900px] text-left text-sm"><thead className="bg-slate-50 text-xs uppercase text-slate-500"><tr><th className="p-4">Dokumen</th><th className="p-4">Customer</th><th className="p-4">Metode</th><th className="p-4 text-right">Total</th><th className="p-4">Status</th><th className="p-4">Aksi</th></tr></thead><tbody className="divide-y divide-slate-100">{documents.map((row) => <tr key={row.id}><td className="p-4"><strong>{row.receipt_no}</strong><span className="block text-xs text-slate-500">{date(row.receipt_date)} · {row.reference_no || 'Tanpa referensi'}</span></td><td className="p-4 font-bold">{customers.get(row.customer_id)?.name ?? 'Customer'}</td><td className="p-4">{row.payment_method_name_snapshot}</td><td className="p-4 text-right font-black">{rupiah(row.total_amount)}</td><td className="p-4"><Status value={row.status}/></td><td className="p-4"><div className="flex gap-2">{row.status === 'DRAFT' && canEdit && <button onClick={() => openDraft(row)} className="rounded-lg border border-slate-200 px-3 py-2 font-bold">Edit</button>}{row.status === 'DRAFT' && canPost && <button onClick={() => void post(row)} disabled={busy} className="inline-flex items-center gap-1 rounded-lg bg-emerald-600 px-3 py-2 font-black text-white"><CheckCircle2 className="h-4 w-4"/> Post</button>}{row.status === 'DRAFT' && canEdit && <button onClick={() => void cancel(row)} disabled={busy} className="inline-flex items-center gap-1 rounded-lg border border-rose-200 px-3 py-2 font-bold text-rose-700"><XCircle className="h-4 w-4"/> Batal</button>}</div></td></tr>)}{!documents.length && <tr><td colSpan={6} className="p-10 text-center text-slate-500">Belum ada penerimaan Customer.</td></tr>}</tbody></table></div></section>
  </div>
}

function Field({ label, children }: { label: string; children: React.ReactElement<{ className?: string }> }) { return <label className="block text-sm font-black">{label}<span className="mt-2 block">{children && Object.assign(children, {})}</span><style jsx>{`label :global(input),label :global(select){min-height:44px;width:100%;border:1px solid rgb(226 232 240);border-radius:12px;padding:0 12px;background:white;font-weight:400}`}</style></label> }
function Status({ value }: { value: Document['status'] }) { const style = value === 'POSTED' ? 'bg-emerald-100 text-emerald-800' : value === 'CANCELED' ? 'bg-rose-100 text-rose-800' : 'bg-amber-100 text-amber-800'; return <span className={`rounded-full px-2.5 py-1 text-xs font-black ${style}`}>{value === 'POSTED' ? 'Posted' : value === 'CANCELED' ? 'Dibatalkan' : 'Draft'}</span> }
function Metric({ label, value, danger = false }: { label: string; value: string; danger?: boolean }) { return <div className={`rounded-xl border p-4 ${danger ? 'border-rose-100 bg-rose-50' : 'border-slate-100 bg-slate-50'}`}><span className="text-xs font-bold uppercase text-slate-500">{label}</span><strong className={`mt-1 block text-xl ${danger ? 'text-rose-700' : 'text-slate-900'}`}>{value}</strong></div> }
function agingLabel(value: string) { return ({ NOT_DUE: 'Belum jatuh tempo', OVERDUE_1_30: 'Lewat 1–30 hari', OVERDUE_31_60: 'Lewat 31–60 hari', OVERDUE_61_90: 'Lewat 61–90 hari', OVERDUE_GT_90: 'Lewat >90 hari', NO_DUE_DATE: 'Tanpa jatuh tempo' } as Record<string, string>)[value] ?? value }
