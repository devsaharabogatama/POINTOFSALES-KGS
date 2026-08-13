import { apiError, requireActiveCompany, requireCaller, requirePermissionCapability } from '@/lib/server-auth'
import { throwDatabaseError } from '@/lib/master-data'
import {
  parseCancelSupplierPayment,
  parseSaveSupplierPaymentDraft,
  parseValidateSupplierPayment,
  throwSupplierPaymentRpcError,
} from '@/lib/supplier-payment'

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const result = await caller.client.rpc('get_finance_supplier_payments')
    if (result.error) throwDatabaseError(result.error)
    return Response.json({ data: result.data })
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
      const parsed = parseSaveSupplierPaymentDraft(body)
      await requirePermissionCapability(caller, companyId,
        'finance.supplier_payments', parsed.documentId ? 'EDIT_DRAFT' : 'CREATE_DRAFT')
      const { data, error } = await caller.client.rpc('save_supplier_payment_draft', {
        p_document_id: parsed.documentId,
        p_master_version: parsed.masterVersion,
        p_supplier_id: parsed.supplierId,
        p_payment_date: parsed.paymentDate,
        p_payment_method: parsed.paymentMethod,
        p_source_account_id: parsed.sourceAccountId,
        p_supplier_bank_name: parsed.supplierBankName,
        p_supplier_bank_account_no: parsed.supplierBankAccountNo,
        p_supplier_bank_account_holder: parsed.supplierBankAccountHolder,
        p_reference_no: parsed.referenceNo,
        p_notes: parsed.notes,
        p_evidence_url: parsed.evidenceUrl,
        p_allocations: parsed.allocations,
      })

      if (error) throwSupplierPaymentRpcError(error)
      return Response.json({ data })
    }

    if (action === 'VALIDATE') {
      const parsed = parseValidateSupplierPayment(body)
      await requirePermissionCapability(caller, companyId,
        'finance.supplier_payments', 'POST')
      const { data, error } = await caller.client.rpc('validate_supplier_payment', {
        p_document_id: parsed.documentId,
        p_master_version: parsed.masterVersion,
        p_idempotency_key: parsed.idempotencyKey,
      })

      if (error) throwSupplierPaymentRpcError(error)
      return Response.json({ data })
    }

    if (action === 'CANCEL') {
      const parsed = parseCancelSupplierPayment(body)
      await requirePermissionCapability(caller, companyId,
        'finance.supplier_payments', 'EDIT_DRAFT')
      const { data, error } = await caller.client.rpc('cancel_supplier_payment', {
        p_document_id: parsed.documentId,
        p_master_version: parsed.masterVersion,
        p_reason: parsed.reason,
      })

      if (error) throwSupplierPaymentRpcError(error)
      return Response.json({ data })
    }

    return apiError(new Error('ACTION_INVALID'))
  } catch (error) {
    return apiError(error)
  }
}
