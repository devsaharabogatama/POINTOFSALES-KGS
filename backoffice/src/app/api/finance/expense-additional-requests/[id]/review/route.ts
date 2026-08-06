import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject, uuidValue } from '@/lib/master-data'
import {
  parseAdditionalExpenseReviewBody,
  throwExpenseRpcError,
} from '@/lib/expense'

type RouteContext = { params: Promise<{ id: string }> }

export async function POST(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const { id } = await context.params
    const input = parseAdditionalExpenseReviewBody(await readJsonObject(request))
    const { data, error } = await caller.client.rpc(
      'review_additional_expense_disbursement',
      {
        p_request_id: uuidValue(id),
        p_master_version: input.masterVersion,
        p_action: input.action,
        p_reason: input.reason,
      },
    )
    if (error) throwExpenseRpcError(error)
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}
