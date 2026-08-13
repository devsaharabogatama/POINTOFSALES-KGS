import { apiError, requireActiveCompany, requireCaller, requirePermissionCapability } from '@/lib/server-auth'
import { readJsonObject, uuidValue } from '@/lib/master-data'
import {
  parseStockAdjustmentCancelBody,
  throwStockAdjustmentRpcError,
} from '@/lib/stock-adjustment'

type RouteContext = { params: Promise<{ id: string }> }

export async function POST(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    await requirePermissionCapability(
      caller, companyId, 'inventory.stock_adjustments', 'CANCEL_FINAL',
    )
    const { id } = await context.params
    const input = parseStockAdjustmentCancelBody(await readJsonObject(request))
    const { data, error } = await caller.client.rpc('cancel_stock_adjustment', {
      p_document_id: uuidValue(id),
      p_master_version: input.masterVersion,
    })
    if (error) throwStockAdjustmentRpcError(error)
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}
