import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { parseIncludeInactive, readJsonObject, throwDatabaseError } from '@/lib/master-data'
import { customerRpcArgs, parseCustomerBody, throwCustomerRpcError } from '@/lib/customer-master'

const fields = `id,company_id,code,name,customer_category_id,phone,email,address,customer_type,
  current_balance,credit_limit,credit_term_days,is_active,is_system_customer,notes,master_version,parent_customer_id,default_pricelist_id,
  created_at,updated_at,category:customer_categories!fk_customers_company_category(id,category_code,category_name,is_system_category,is_active),
  updated_by`

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    let query = caller.client.from('customers').select(fields).eq('company_id', companyId).order('is_system_customer', { ascending: false }).order('name').limit(500)
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
    const input = parseCustomerBody(await readJsonObject(request), false)
    const { data, error } = await caller.client.rpc('save_customer_with_pricelist', customerRpcArgs(null, input))
    if (error) throwCustomerRpcError(error)
    return Response.json({ data }, { status: 201 })
  } catch (error) { return apiError(error) }
}
