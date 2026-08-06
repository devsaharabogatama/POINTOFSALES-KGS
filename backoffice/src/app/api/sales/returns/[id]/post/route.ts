import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject, uuidValue } from '@/lib/master-data'
import { parseSalesReturnPostBody, throwSalesReturnRpcError } from '@/lib/sales-return'

type RouteContext = { params: Promise<{ id: string }> }

export async function POST(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const { id } = await context.params
    const input = parseSalesReturnPostBody(await readJsonObject(request))
    const { data, error } = await caller.client.rpc('post_sales_return', {
      p_document_id: uuidValue(id),
      p_master_version: input.masterVersion,
      p_idempotency_key: input.idempotencyKey,
    })
    if (error) throwSalesReturnRpcError(error)
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}
