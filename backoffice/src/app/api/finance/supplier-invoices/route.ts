import { apiError, requireActiveCompany, requireCaller, requirePermissionCapability } from '@/lib/server-auth'
import { throwDatabaseError } from '@/lib/master-data'
import {
  parseCancelSupplierInvoice,
  parseSaveSupplierInvoiceDraft,
  parseValidateSupplierInvoice,
  throwSupplierInvoiceRpcError,
} from '@/lib/supplier-invoice'

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const result = await caller.client.rpc('get_finance_supplier_invoices')
    if (result.error) throwDatabaseError(result.error)
    return Response.json(result.data)
  } catch (error) {
    return apiError(error)
  }
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)

    const body = (await request.json()) as Record<string, unknown>
    const action = String(body.action || '').toUpperCase()

    if (action === 'SAVE_DRAFT') {
      const parsed = parseSaveSupplierInvoiceDraft(body)
      await requirePermissionCapability(caller, companyId,
        'finance.supplier_invoices', parsed.documentId ? 'EDIT_DRAFT' : 'CREATE_DRAFT')
      const res = await caller.client.rpc('save_supplier_invoice_draft', {
        p_document_id: parsed.documentId,
        p_master_version: parsed.masterVersion,
        p_supplier_id: parsed.supplierId,
        p_supplier_invoice_no: parsed.supplierInvoiceNo,
        p_invoice_date: parsed.invoiceDate,
        p_due_date: parsed.dueDate,
        p_price_mode: parsed.priceMode,
        p_notes: parsed.notes,
        p_evidence_url: parsed.evidenceUrl,
        p_lines: parsed.lines,
      })
      if (res.error) throwSupplierInvoiceRpcError(res.error)
      return Response.json({ success: true, data: res.data })
    }

    if (action === 'VALIDATE') {
      const parsed = parseValidateSupplierInvoice(body)
      await requirePermissionCapability(caller, companyId,
        'finance.supplier_invoices', 'POST')
      const res = await caller.client.rpc('validate_supplier_invoice', {
        p_document_id: parsed.documentId,
        p_master_version: parsed.masterVersion,
        p_idempotency_key: parsed.idempotencyKey,
      })
      if (res.error) throwSupplierInvoiceRpcError(res.error)
      return Response.json({ success: true, data: res.data })
    }

    if (action === 'CANCEL') {
      const parsed = parseCancelSupplierInvoice(body)
      await requirePermissionCapability(caller, companyId,
        'finance.supplier_invoices', 'EDIT_DRAFT')
      const res = await caller.client.rpc('cancel_supplier_invoice', {
        p_document_id: parsed.documentId,
        p_master_version: parsed.masterVersion,
        p_reason: parsed.cancelReason,
      })
      if (res.error) throwSupplierInvoiceRpcError(res.error)
      return Response.json({ success: true, data: res.data })
    }

    return Response.json(
      { error: 'ACTION_INVALID', message: 'Unknown action specified' },
      { status: 400 },
    )
  } catch (error) {
    return apiError(error)
  }
}
