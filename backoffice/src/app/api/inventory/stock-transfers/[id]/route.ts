import { apiError, requireActiveCompany, requireCaller, requirePermissionCapability } from '@/lib/server-auth'
import { readJsonObject, uuidValue } from '@/lib/master-data'
import {
  parseStockTransferBody,
  stockTransferRpcArgs,
  throwStockTransferRpcError,
} from '@/lib/stock-transfer'

type RouteContext = { params: Promise<{ id: string }> }

export async function PATCH(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    await requirePermissionCapability(
      caller, companyId, 'inventory.stock_transfers', 'EDIT_DRAFT',
    )
    const { id } = await context.params
    const documentId = uuidValue(id)
    const input = parseStockTransferBody(await readJsonObject(request), true)
    const { data, error } = await caller.client.rpc(
      'save_stock_transfer_document',
      stockTransferRpcArgs(documentId, input),
    )
    if (error) throwStockTransferRpcError(error)
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}
