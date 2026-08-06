import { ApiRouteError, apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject, throwDatabaseError, uuidValue } from '@/lib/master-data'
import {
  parseAdditionalExpenseDisbursementBody,
  throwExpenseRpcError,
} from '@/lib/expense'

type RouteContext = { params: Promise<{ id: string }> }

export async function POST(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const { id } = await context.params
    const requestId = uuidValue(id)
    const input = parseAdditionalExpenseDisbursementBody(await readJsonObject(request))

    const { data: additionalRequest, error: requestError } = await caller.client
      .from('expense_additional_disbursement_requests')
      .select('id,payment_method_type_snapshot')
      .eq('company_id', companyId)
      .eq('id', requestId)
      .maybeSingle()
    if (requestError) throwDatabaseError(requestError)
    if (!additionalRequest) {
      throw new ApiRouteError('EXPENSE_ADDITIONAL_REQUEST_NOT_FOUND', 404)
    }
    if (additionalRequest.payment_method_type_snapshot === 'CASH') {
      throw new ApiRouteError('EXPENSE_ADDITIONAL_CASH_DISBURSEMENT_POS_REQUIRED', 409)
    }

    const { data, error } = await caller.client.rpc('disburse_additional_expense', {
      p_request_id: requestId,
      p_request_master_version: input.requestMasterVersion,
      p_document_master_version: input.documentMasterVersion,
      p_cashier_session_id: null,
      p_evidence_url: input.evidenceUrl,
      p_idempotency_key: input.idempotencyKey,
    })
    if (error) throwExpenseRpcError(error)
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}
