import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject, uuidValue } from '@/lib/master-data'
import {
  parseStockOpnameRecountBody,
  throwStockOpnameRpcError,
} from '@/lib/stock-opname'

type RouteContext = { params: Promise<{ id: string }> }

export async function POST(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const { id } = await context.params
    const input = parseStockOpnameRecountBody(await readJsonObject(request))
    const { data, error } = await caller.client.rpc(
      'request_stock_opname_recount',
      {
        p_opname_id: uuidValue(id),
        p_master_version: input.masterVersion,
        p_opname_detail_id: input.detailId,
      },
    )
    if (error) throwStockOpnameRpcError(error)
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}
