import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject, uuidValue } from '@/lib/master-data'
import { parseExpenseCancelBody, throwExpenseRpcError } from '@/lib/expense'

type RouteContext = { params: Promise<{ id: string }> }

export async function POST(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const { id } = await context.params
    const input = parseExpenseCancelBody(await readJsonObject(request))
    const { data, error } = await caller.client.rpc('cancel_expense_request', {
      p_document_id: uuidValue(id),
      p_master_version: input.masterVersion,
      p_reason: input.reason,
    })
    if (error) throwExpenseRpcError(error)
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}
