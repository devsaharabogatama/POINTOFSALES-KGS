import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject, uuidValue } from '@/lib/master-data'
import {
  categoryRpcArgs,
  parseTransactionCategory,
  throwFinanceMasterRpcError,
} from '@/lib/finance-master'

type RouteContext = { params: Promise<{ id: string }> }

export async function PATCH(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const { id } = await context.params
    const categoryId = uuidValue(id)
    const input = parseTransactionCategory(await readJsonObject(request), true)
    const { data, error } = await caller.client.rpc(
      'save_transaction_category', categoryRpcArgs(categoryId, input),
    )
    if (error) throwFinanceMasterRpcError(error)
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}
