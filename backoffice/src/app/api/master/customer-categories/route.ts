import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { parseIncludeInactive, readJsonObject, throwDatabaseError } from '@/lib/master-data'
import { customerCategoryRpcArgs, parseCustomerCategoryBody, throwCustomerRpcError } from '@/lib/customer-master'

const fields = 'id,company_id,category_code,category_name,is_system_category,is_active,master_version,created_at,updated_at'

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    let query = caller.client.from('customer_categories').select(fields).eq('company_id', companyId).order('is_system_category', { ascending: false }).order('category_name').limit(200)
    if (!parseIncludeInactive(request)) query = query.eq('is_active', true)
    const { data, error } = await query
    if (error) throwDatabaseError(error)
    return Response.json({ companyId, data: data ?? [] })
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
