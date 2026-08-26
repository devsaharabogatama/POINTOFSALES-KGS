import { apiError, requireActiveCompany, requireCaller, requirePermissionCapability } from '@/lib/server-auth'
import { throwDatabaseError } from '@/lib/master-data'

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
function requiredUuid(value: unknown, code: string) {
  const result = String(value ?? '').trim()
  if (!uuidPattern.test(result)) throw new Error(code)
  return result
}
function optionalUuid(value: unknown) {
  const result = String(value ?? '').trim()
  if (!result) return null
  if (!uuidPattern.test(result)) throw new Error('UUID_INVALID')
  return result
}
function version(value: unknown) {
  const result = Number(value)
  if (!Number.isSafeInteger(result) || result < 1) throw new Error('MASTER_VERSION_INVALID')
  return result
}
function optionalText(value: unknown) {
  const result = String(value ?? '').trim()
  return result || null
}

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const [workspace, advancePolicy] = await Promise.all([
      caller.client.rpc('get_finance_customer_receipts'),
      caller.client.rpc('get_customer_receipt_advance_policy'),
    ])
    if (workspace.error) throwDatabaseError(workspace.error)
    if (advancePolicy.error) throwDatabaseError(advancePolicy.error)
    return Response.json({ ...(workspace.data as Record<string, unknown>), advancePolicy: advancePolicy.data })
  } catch (error) { return apiError(error) }
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const body = await request.json() as Record<string, unknown>
    const action = String(body.action ?? '').toUpperCase()
    if (action === 'SAVE_DRAFT') {
      const documentId = optionalUuid(body.documentId)
      await requirePermissionCapability(caller, companyId, 'finance.customer_receipts', documentId ? 'EDIT_DRAFT' : 'CREATE_DRAFT')
      if (!/^\d{4}-\d{2}-\d{2}$/.test(String(body.receiptDate ?? ''))) throw new Error('RECEIPT_DATE_INVALID')
      const disposition = String(body.unappliedDisposition ?? 'NONE').toUpperCase()
      if (!['NONE', 'CUSTOMER_BALANCE'].includes(disposition)) throw new Error('CUSTOMER_RECEIPT_DISPOSITION_INVALID')
      if (!Array.isArray(body.allocations) || (disposition === 'NONE' && !body.allocations.length)) throw new Error('CUSTOMER_RECEIPT_ALLOCATION_REQUIRED')
      const allocations = body.allocations.map((row) => {
        const item = row as Record<string, unknown>
        const amount = Number(item.allocatedAmount)
        if (!Number.isFinite(amount) || amount <= 0) throw new Error('CUSTOMER_RECEIPT_ALLOCATION_INVALID')
        return { salesId: requiredUuid(item.salesId, 'SALES_ID_INVALID'), clientAllocationKey: requiredUuid(item.clientAllocationKey, 'CLIENT_KEY_INVALID'), allocatedAmount: amount }
      })
      const receivedAmount = Number(body.receivedAmount)
      if (!Number.isFinite(receivedAmount) || receivedAmount <= 0) throw new Error('CUSTOMER_RECEIPT_AMOUNT_INVALID')
      const { data, error } = await caller.client.rpc('save_customer_receipt_draft_with_disposition', {
        p_document_id: documentId,
        p_master_version: documentId ? version(body.masterVersion) : null,
        p_customer_id: requiredUuid(body.customerId, 'CUSTOMER_ID_INVALID'),
        p_receipt_date: body.receiptDate,
        p_payment_method_id: requiredUuid(body.paymentMethodId, 'PAYMENT_METHOD_ID_INVALID'),
        p_reference_no: optionalText(body.referenceNo), p_evidence_url: optionalText(body.evidenceUrl),
        p_notes: optionalText(body.notes), p_received_amount: receivedAmount,
        p_unapplied_disposition: disposition, p_allocations: allocations,
      })
      if (error) throwDatabaseError(error)
      return Response.json({ data })
    }
    if (action === 'POST') {
      await requirePermissionCapability(caller, companyId, 'finance.customer_receipts', 'POST')
      const { data, error } = await caller.client.rpc('post_customer_receipt_with_disposition', {
        p_document_id: requiredUuid(body.documentId, 'DOCUMENT_ID_INVALID'),
        p_master_version: version(body.masterVersion),
        p_idempotency_key: requiredUuid(body.idempotencyKey, 'IDEMPOTENCY_KEY_INVALID'),
      })
      if (error) throwDatabaseError(error)
      return Response.json({ data })
    }
    if (action === 'CANCEL') {
      await requirePermissionCapability(caller, companyId, 'finance.customer_receipts', 'EDIT_DRAFT')
      const reason = optionalText(body.reason)
      if (!reason) throw new Error('CANCEL_REASON_REQUIRED')
      const { data, error } = await caller.client.rpc('cancel_customer_receipt_draft', {
        p_document_id: requiredUuid(body.documentId, 'DOCUMENT_ID_INVALID'),
        p_master_version: version(body.masterVersion), p_reason: reason,
      })
      if (error) throwDatabaseError(error)
      return Response.json({ data })
    }
    throw new Error('ACTION_INVALID')
  } catch (error) { return apiError(error) }
}
