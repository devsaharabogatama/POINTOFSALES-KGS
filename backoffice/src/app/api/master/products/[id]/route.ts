import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject, uuidValue } from '@/lib/master-data'
import { parseProductBody, productRpcArgs, throwProductRpcError } from '@/lib/product-master'

type RouteContext = { params: Promise<{ id: string }> }

export async function PATCH(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const { id } = await context.params
    const productId = uuidValue(id)
    const body = await readJsonObject(request)
    const input = parseProductBody(body, true)
    const { data, error } = await caller.client.rpc(
      'save_product_with_uoms',
      productRpcArgs(productId, input),
    )
    if (error) throwProductRpcError(error)
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}
