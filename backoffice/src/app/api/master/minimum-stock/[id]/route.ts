import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject, uuidValue } from '@/lib/master-data'
import {
  minimumStockRpcArgs,
  parseMinimumStockBody,
  throwMinimumStockRpcError,
} from '@/lib/minimum-stock'

type RouteContext = { params: Promise<{ id: string }> }

export async function PATCH(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const { id } = await context.params
    const settingId = uuidValue(id)
    const input = parseMinimumStockBody(await readJsonObject(request), true)
    const { data, error } = await caller.client.rpc(
      'save_product_warehouse_stock_setting',
      minimumStockRpcArgs(settingId, input),
    )
    if (error) throwMinimumStockRpcError(error)
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}
