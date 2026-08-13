import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject, uuidValue } from '@/lib/master-data'
import { parseExpenseDisbursementBody, throwExpenseRpcError } from '@/lib/expense'

type RouteContext = { params: Promise<{ id: string }> }

export async function POST(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const { id } = await context.params
    const documentId = uuidValue(id)
    const input = parseExpenseDisbursementBody(await readJsonObject(request))

    const { data, error } = await caller.client.rpc('disburse_expense', {
      p_document_id: documentId,
      p_master_version: input.masterVersion,
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
