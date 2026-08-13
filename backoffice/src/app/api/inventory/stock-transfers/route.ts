import { apiError, requireActiveCompany, requireCaller, requirePermissionCapability } from '@/lib/server-auth'
import { readJsonObject, throwDatabaseError } from '@/lib/master-data'
import {
  parseStockTransferBody,
  stockTransferRpcArgs,
  throwStockTransferRpcError,
} from '@/lib/stock-transfer'

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    await requirePermissionCapability(
      caller, companyId, 'inventory.stock_transfers', 'VIEW',
    )
    const { data, error } = await caller.client.rpc('get_inventory_stock_transfers')
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
      caller, companyId, 'inventory.stock_transfers', 'CREATE_DRAFT',
    )
    const input = parseStockTransferBody(await readJsonObject(request), false)
    const { data, error } = await caller.client.rpc(
      'save_stock_transfer_document',
      stockTransferRpcArgs(null, input),
    )
    if (error) throwStockTransferRpcError(error)
    return Response.json({ data }, { status: 201 })
  } catch (error) {
    return apiError(error)
  }
}
