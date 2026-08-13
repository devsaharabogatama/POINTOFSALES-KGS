import { apiError, requireActiveCompany, requireCaller, requirePermissionCapability } from '@/lib/server-auth'
import { readJsonObject, uuidValue } from '@/lib/master-data'
import {
  parseOpeningStockPostBody,
  throwOpeningStockRpcError,
} from '@/lib/opening-stock'

type RouteContext = { params: Promise<{ id: string }> }

export async function POST(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    await requirePermissionCapability(
      caller, companyId, 'inventory.opening_stock', 'POST',
    )
    const { id } = await context.params
    const documentId = uuidValue(id)
    const input = parseOpeningStockPostBody(await readJsonObject(request))
    const { data, error } = await caller.client.rpc('post_opening_stock', {
      p_document_id: documentId,
      p_master_version: input.masterVersion,
      p_idempotency_key: input.idempotencyKey,
    })
    if (error) throwOpeningStockRpcError(error)
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}
