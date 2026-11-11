import { ApiRouteError, apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject, throwDatabaseError, uuidValue } from '@/lib/master-data'

function dateValue(value: unknown) {
  const result = String(value ?? '')
  if (!/^\d{4}-\d{2}-\d{2}$/.test(result)) throw new ApiRouteError('AR_ACTION_DATE_INVALID', 400)
  return result
}
function amountValue(value: unknown, code = 'AR_ACTION_AMOUNT_INVALID') {
  const result = Number(value)
  if (!Number.isFinite(result) || result <= 0) throw new ApiRouteError(code, 400)
  return result
}
function expectedAmount(value: unknown, code: string) {
  const result = Number(value)
  if (!Number.isFinite(result) || result < 0) throw new ApiRouteError(code, 400)
  return result
}
function textValue(value: unknown, max = 2000) {
  return typeof value === 'string' ? value.trim().slice(0, max) || null : null
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const body = await readJsonObject(request)
    const action = String(body.action ?? '').trim().toUpperCase()
    const operationId = uuidValue(String(body.operationId ?? ''), 'IDEMPOTENCY_KEY_INVALID')
    let result
    if (action === 'APPLY_CREDIT') {
      if (!Array.isArray(body.allocations) || !body.allocations.length) {
        throw new ApiRouteError('AR_OPEN_CREDIT_ALLOCATION_REQUIRED', 400)
      }
      const allocations = body.allocations.map((candidate) => {
        const row = candidate as Record<string, unknown>
        return {
          debitItemId: uuidValue(String(row.debitItemId ?? ''), 'AR_DEBIT_ITEM_ID_INVALID'),
          amount: amountValue(row.amount),
        }
      })
      result = await caller.client.rpc('apply_backoffice_ar_open_credit', {
        p_credit_item_id: uuidValue(String(body.creditItemId ?? ''), 'AR_CREDIT_ITEM_ID_INVALID'),
        p_allocations: allocations,
        p_effective_date: dateValue(body.effectiveDate),
        p_expected_credit_residual: expectedAmount(body.expectedCreditResidual, 'AR_CREDIT_RESIDUAL_INVALID'),
        p_operation_id: operationId,
      })
    } else if (action === 'REFUND_CREDIT') {
      result = await caller.client.rpc('refund_backoffice_ar_open_credit', {
        p_credit_item_id: uuidValue(String(body.creditItemId ?? ''), 'AR_CREDIT_ITEM_ID_INVALID'),
        p_amount: amountValue(body.amount), p_effective_date: dateValue(body.effectiveDate),
        p_payment_method_id: uuidValue(String(body.paymentMethodId ?? ''), 'PAYMENT_METHOD_ID_INVALID'),
        p_reference_no: textValue(body.referenceNo, 500), p_evidence_url: textValue(body.evidenceUrl),
        p_notes: textValue(body.notes),
        p_expected_credit_residual: expectedAmount(body.expectedCreditResidual, 'AR_CREDIT_RESIDUAL_INVALID'),
        p_operation_id: operationId,
      })
    } else if (action === 'CONVERT_CREDIT_BALANCE') {
      result = await caller.client.rpc('convert_backoffice_ar_open_credit_to_customer_balance', {
        p_credit_item_id: uuidValue(String(body.creditItemId ?? ''), 'AR_CREDIT_ITEM_ID_INVALID'),
        p_amount: amountValue(body.amount), p_effective_date: dateValue(body.effectiveDate),
        p_reason: textValue(body.reason, 1000) ?? '',
        p_expected_credit_residual: expectedAmount(body.expectedCreditResidual, 'AR_CREDIT_RESIDUAL_INVALID'),
        p_operation_id: operationId,
      })
    } else if (action === 'APPLY_CUSTOMER_BALANCE') {
      result = await caller.client.rpc('apply_customer_balance_to_backoffice_invoice', {
        p_invoice_item_id: uuidValue(String(body.invoiceItemId ?? ''), 'AR_INVOICE_ITEM_ID_INVALID'),
        p_amount: amountValue(body.amount), p_effective_date: dateValue(body.effectiveDate),
        p_reason: textValue(body.reason, 1000) ?? '',
        p_expected_invoice_residual: expectedAmount(body.expectedInvoiceResidual, 'AR_INVOICE_RESIDUAL_INVALID'),
        p_expected_customer_balance: expectedAmount(body.expectedCustomerBalance, 'CUSTOMER_BALANCE_INVALID'),
        p_operation_id: operationId,
      })
    } else if (action === 'REVERSE') {
      result = await caller.client.rpc('reverse_backoffice_ar_open_credit_action', {
        p_original_operation_id: uuidValue(String(body.originalOperationId ?? ''), 'AR_OPERATION_ID_INVALID'),
        p_effective_date: dateValue(body.effectiveDate), p_reason: textValue(body.reason, 1000) ?? '',
        p_operation_id: operationId,
      })
    } else {
      throw new ApiRouteError('AR_ACTION_INVALID', 400)
    }
    if (result.error) throwDatabaseError(result.error)
    return Response.json(result.data)
  } catch (error) {
    return apiError(error)
  }
}
