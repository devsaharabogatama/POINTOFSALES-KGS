import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject } from '@/lib/master-data'
import {
  minimumStockRpcArgs,
  parseMinimumStockBody,
  throwMinimumStockRpcError,
} from '@/lib/minimum-stock'

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const { data, error } = await caller.client.rpc(
      'get_inventory_minimum_stock',
    )
    if (error) throwMinimumStockRpcError(error)
    return Response.json(data ?? { companyId, data: [] })
  } catch (error) {
    return apiError(error)
  }
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const input = parseMinimumStockBody(await readJsonObject(request), false)
    const { data, error } = await caller.client.rpc(
      'save_product_warehouse_stock_setting',
      minimumStockRpcArgs(null, input),
    )
    if (error) throwMinimumStockRpcError(error)
    return Response.json({ data }, { status: 201 })
  } catch (error) {
    return apiError(error)
  }
}
