import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject, uuidValue } from '@/lib/master-data'
import {
  parseStockTransferCancelBody,
  throwStockTransferRpcError,
} from '@/lib/stock-transfer'

type RouteContext = { params: Promise<{ id: string }> }

export async function POST(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const { id } = await context.params
    const input = parseStockTransferCancelBody(await readJsonObject(request))
    const { data, error } = await caller.client.rpc('cancel_stock_transfer', {
      p_document_id: uuidValue(id),
      p_master_version: input.masterVersion,
    })
    if (error) throwStockTransferRpcError(error)
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}
