import { apiError, requireActiveCompany, requireCaller, requirePermissionCapability } from '@/lib/server-auth'
import { readJsonObject, uuidValue } from '@/lib/master-data'
import {
  openingStockRpcArgs,
  parseOpeningStockBody,
  throwOpeningStockRpcError,
} from '@/lib/opening-stock'

type RouteContext = { params: Promise<{ id: string }> }

export async function PATCH(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    await requirePermissionCapability(
      caller, companyId, 'inventory.opening_stock', 'EDIT_DRAFT',
    )
    const { id } = await context.params
    const documentId = uuidValue(id)
    const input = parseOpeningStockBody(await readJsonObject(request), true)
    const { data, error } = await caller.client.rpc(
      'save_opening_stock_document',
      openingStockRpcArgs(documentId, input),
    )
    if (error) throwOpeningStockRpcError(error)
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}
