import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject, uuidValue } from '@/lib/master-data'
import { customerCategoryRpcArgs, parseCustomerCategoryBody, throwCustomerRpcError } from '@/lib/customer-master'

type RouteContext = { params: Promise<{ id: string }> }

export async function PATCH(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const id = uuidValue((await context.params).id)
    const input = parseCustomerCategoryBody(await readJsonObject(request), true)
    const { data, error } = await caller.client.rpc('save_customer_category', customerCategoryRpcArgs(id, input))
    if (error) throwCustomerRpcError(error)
    return Response.json({ data })
  } catch (error) { return apiError(error) }
}
