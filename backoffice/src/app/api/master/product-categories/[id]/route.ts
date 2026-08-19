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

    const currentResult = await caller.client.from('product_categories')
      .select('category_name,is_active')
      .eq('company_id', companyId).eq('id', id).maybeSingle()
    if (currentResult.error) throwDatabaseError(currentResult.error)
    if (!currentResult.data) throw new ApiRouteError('MASTER_NOT_FOUND', 404)
    let categoryName = currentResult.data.category_name
    if ('categoryName' in body) categoryName = requiredText(body, 'categoryName', { maxLength: 150 })
    const isActive = optionalBoolean(body, 'isActive')

    const { data: result, error } = await caller.client.rpc(
      'save_inventory_product_category',
      {
        p_category_id: id,
        p_expected_version: masterVersion,
        p_category_name: categoryName,
        p_is_active: isActive ?? currentResult.data.is_active,
      },
    )

    if (error) throwDatabaseError(error)
    const data = (result as { data?: unknown } | null)?.data ?? result
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}

export async function DELETE(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const params = await context.params
    const id = uuidValue(params.id || '', 'MASTER_ID_INVALID')
    const body = await readJsonObject(request)
    const masterVersion = requiredVersion(body)

    const { data, error } = await caller.client.rpc(
      'delete_inventory_product_category',
      {
        p_category_id: id,
        p_expected_version: masterVersion,
      },
    )
    if (error) throwDatabaseError(error)
    const result = (data as { data?: unknown } | null)?.data ?? data
    return Response.json({ data: result })
  } catch (error) {
    return apiError(error)
  }
}
