import { apiError, requireActiveCompany, requireCaller, requirePermissionCapability } from '@/lib/server-auth'
import { readJsonObject, throwDatabaseError } from '@/lib/master-data'
import {
  parseStockAdjustmentBody,
  stockAdjustmentRpcArgs,
  throwStockAdjustmentRpcError,
} from '@/lib/stock-adjustment'

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    await requirePermissionCapability(
      caller, companyId, 'inventory.stock_adjustments', 'VIEW',
    )
    const { data, error } = await caller.client.rpc(
      'get_inventory_stock_adjustments',
    )
    if (error) throwDatabaseError(error)
    return Response.json(data)
  } catch (error) {
    return apiError(error)
  }
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    await requirePermissionCapability(
      caller, companyId, 'inventory.stock_adjustments', 'CREATE_DRAFT',
    )
    const input = parseStockAdjustmentBody(await readJsonObject(request), false)
    const { data, error } = await caller.client.rpc(
      'save_stock_adjustment_document',
      stockAdjustmentRpcArgs(null, input),
    )
    if (error) throwStockAdjustmentRpcError(error)
    return Response.json({ data }, { status: 201 })
  } catch (error) {
    return apiError(error)
  }
}
