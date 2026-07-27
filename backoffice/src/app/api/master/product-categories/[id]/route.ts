import { apiError, ApiRouteError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import {
  ensurePatchFields,
  optionalBoolean,
  readJsonObject,
  requiredText,
  requiredVersion,
  throwDatabaseError,
  uuidValue,
} from '@/lib/master-data'

const selectFields =
  'id, company_id, category_code, category_name, is_active, master_version, default_sales_tax_rule_id, default_purchase_tax_rule_id, created_at, updated_at'

type RouteContext = { params: Promise<{ id: string }> }

export async function PATCH(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const params = await context.params
    const id = uuidValue(params.id || '', 'MASTER_ID_INVALID')

    const body = await readJsonObject(request)
    const masterVersion = requiredVersion(body)
    ensurePatchFields(body, ['categoryName', 'isActive'])

    const changes: Record<string, string | boolean> = {}
    if ('categoryName' in body) {
      changes.category_name = requiredText(body, 'categoryName', { maxLength: 150 })
    }
    const isActive = optionalBoolean(body, 'isActive')
    if (isActive !== undefined) changes.is_active = isActive

    const { data, error } = await caller.client
      .from('product_categories')
      .update(changes)
      .eq('company_id', companyId)
      .eq('id', id)
      .eq('master_version', masterVersion)
      .select(selectFields)
      .maybeSingle()

    if (error) throwDatabaseError(error)
    if (!data) throw new ApiRouteError('MASTER_VERSION_CONFLICT_OR_NOT_FOUND', 409)
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}
