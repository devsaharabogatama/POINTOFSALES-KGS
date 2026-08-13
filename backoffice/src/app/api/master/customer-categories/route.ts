import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { parseIncludeInactive, readJsonObject } from '@/lib/master-data'
import { customerCategoryRpcArgs, parseCustomerCategoryBody, throwCustomerRpcError } from '@/lib/customer-master'

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const { data, error } = await caller.client.rpc('get_contacts_customers', {
      p_include_inactive: parseIncludeInactive(request),
    })
    if (error) throwCustomerRpcError(error)
    const payload = data as { companyId?: string; categories?: unknown[] } | null
    return Response.json({ companyId: payload?.companyId, data: payload?.categories ?? [] })
  } catch (error) { return apiError(error) }
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const input = parseCustomerCategoryBody(await readJsonObject(request), false)
    const { data, error } = await caller.client.rpc('save_customer_category', customerCategoryRpcArgs(null, input))
    if (error) throwCustomerRpcError(error)
    return Response.json({ data }, { status: 201 })
  } catch (error) { return apiError(error) }
}
