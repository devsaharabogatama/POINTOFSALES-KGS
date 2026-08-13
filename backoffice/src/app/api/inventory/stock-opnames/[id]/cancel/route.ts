import { apiError, requireActiveCompany, requireCaller, requirePermissionCapability } from '@/lib/server-auth'
import { readJsonObject, uuidValue } from '@/lib/master-data'
import {
  parseStockOpnameVersionBody,
  throwStockOpnameRpcError,
} from '@/lib/stock-opname'

type RouteContext = { params: Promise<{ id: string }> }

export async function POST(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    await requirePermissionCapability(
      caller, companyId, 'inventory.stock_opnames', 'CANCEL_FINAL',
    )
    const { id } = await context.params
    const input = parseStockOpnameVersionBody(await readJsonObject(request))
    const { data, error } = await caller.client.rpc('cancel_stock_opname', {
      p_opname_id: uuidValue(id),
      p_master_version: input.masterVersion,
    })
    if (error) throwStockOpnameRpcError(error)
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}
