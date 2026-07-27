import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject, uuidValue } from '@/lib/master-data'
import { customerRpcArgs, parseCustomerBody, throwCustomerRpcError } from '@/lib/customer-master'

type RouteContext = { params: Promise<{ id: string }> }

export async function PATCH(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const id = uuidValue((await context.params).id)
    const body = await readJsonObject(request)
    if (!('parentCustomerId' in body) || !('defaultPricelistId' in body)) {
      const { data: current, error: currentError } = await caller.client
        .from('customers')
        .select('parent_customer_id,default_pricelist_id')
        .eq('id', id)
        .single()
      if (currentError) throwCustomerRpcError(currentError)
      if (!('parentCustomerId' in body)) body.parentCustomerId = current.parent_customer_id
      if (!('defaultPricelistId' in body)) body.defaultPricelistId = current.default_pricelist_id
    }
    const input = parseCustomerBody(body, true)
    const { data, error } = await caller.client.rpc('save_customer_with_pricelist', customerRpcArgs(id, input))
    if (error) throwCustomerRpcError(error)
    return Response.json({ data })
  } catch (error) { return apiError(error) }
}
