import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject, uuidValue } from '@/lib/master-data'
import {
  parseStockAdjustmentBody,
  stockAdjustmentRpcArgs,
  throwStockAdjustmentRpcError,
} from '@/lib/stock-adjustment'

type RouteContext = { params: Promise<{ id: string }> }

export async function PATCH(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const { id } = await context.params
    const input = parseStockAdjustmentBody(await readJsonObject(request), true)
    const { data, error } = await caller.client.rpc(
      'save_stock_adjustment_document',
      stockAdjustmentRpcArgs(uuidValue(id), input),
    )
    if (error) throwStockAdjustmentRpcError(error)
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}
