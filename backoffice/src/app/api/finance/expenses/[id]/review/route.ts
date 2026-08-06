import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject, uuidValue } from '@/lib/master-data'
import { parseExpenseReviewBody, throwExpenseRpcError } from '@/lib/expense'

type RouteContext = { params: Promise<{ id: string }> }

export async function POST(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const { id } = await context.params
    const input = parseExpenseReviewBody(await readJsonObject(request))
    const { data, error } = await caller.client.rpc('review_expense_request', {
      p_document_id: uuidValue(id),
      p_master_version: input.masterVersion,
      p_approve: input.approve,
      p_reason: input.reason,
    })
    if (error) throwExpenseRpcError(error)
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}
