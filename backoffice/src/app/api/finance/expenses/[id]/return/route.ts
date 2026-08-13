import { ApiRouteError, apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject, throwDatabaseError, uuidValue } from '@/lib/master-data'
import { parseExpenseReturnBody, throwExpenseRpcError } from '@/lib/expense'

type RouteContext = { params: Promise<{ id: string }> }

export async function POST(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const { id } = await context.params
    const documentId = uuidValue(id)
    const input = parseExpenseReturnBody(await readJsonObject(request))

    const { data: methodRows, error: methodError } = await caller.client
      .rpc('get_finance_expense_payment_method_references')
    if (methodError) throwDatabaseError(methodError)
    const method = ((methodRows ?? []) as Array<{ id: string; method_type: string }>)
      .find((row) => row.id === input.paymentMethodId)
    if (!method) throw new ApiRouteError('ACTIVE_EXPENSE_PAYMENT_METHOD_NOT_FOUND', 404)
    if (method.method_type === 'CASH') {
      throw new ApiRouteError('EXPENSE_CASH_RETURN_POS_REQUIRED', 409)
    }

    const { data, error } = await caller.client.rpc('return_expense_funds', {
      p_document_id: documentId,
      p_master_version: input.masterVersion,
      p_amount: input.amount,
      p_payment_method_id: input.paymentMethodId,
      p_receiving_session_id: null,
      p_evidence_url: input.evidenceUrl,
      p_idempotency_key: input.idempotencyKey,
    })
    if (error) throwExpenseRpcError(error)
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}
