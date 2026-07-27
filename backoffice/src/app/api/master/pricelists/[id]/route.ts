import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject, uuidValue } from '@/lib/master-data'
import { parsePricelistBody, pricelistRpcArgs, throwPricelistRpcError } from '@/lib/pricelist-master'

type RouteContext = { params: Promise<{ id: string }> }

export async function PATCH(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const { id } = await context.params
    const pricelistId = uuidValue(id)
    const input = parsePricelistBody(await readJsonObject(request), true)
    const { data, error } = await caller.client.rpc(
      'save_reusable_pricelist_with_rules', pricelistRpcArgs(pricelistId, input),
    )
    if (error) throwPricelistRpcError(error)
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}
