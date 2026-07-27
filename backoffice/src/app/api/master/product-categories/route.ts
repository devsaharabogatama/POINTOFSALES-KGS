import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import {
  optionalBoolean,
  parseIncludeInactive,
  readJsonObject,
  requiredText,
  throwDatabaseError,
} from '@/lib/master-data'

const selectFields =
  'id, company_id, category_code, category_name, is_active, master_version, default_sales_tax_rule_id, default_purchase_tax_rule_id, created_at, updated_at'

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    let query = caller.client
      .from('product_categories')
      .select(selectFields)
      .eq('company_id', companyId)
      .order('category_name')
      .limit(200)

    if (!parseIncludeInactive(request)) query = query.eq('is_active', true)

    const { data, error } = await query
    if (error) throwDatabaseError(error)
    return Response.json({ companyId, data: data ?? [] })
  } catch (error) {
    return apiError(error)
  }
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const body = await readJsonObject(request)
    const categoryName = requiredText(body, 'categoryName', { maxLength: 150 })
    const isActive = optionalBoolean(body, 'isActive') ?? true

    const { data, error } = await caller.client
      .from('product_categories')
      .insert({
        company_id: companyId,
        category_code: null,
        category_name: categoryName,
        is_active: isActive,
      })
      .select(selectFields)
      .single()

    if (error) throwDatabaseError(error)
    return Response.json({ data }, { status: 201 })
  } catch (error) {
    return apiError(error)
  }
}
