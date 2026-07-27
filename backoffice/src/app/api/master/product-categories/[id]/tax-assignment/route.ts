import { ApiRouteError, apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject, requiredVersion, uuidValue } from '@/lib/master-data'

type RouteContext = { params: Promise<{ id: string }> }

function nullableUuid(value: unknown, code: string) {
  if (value === null || value === undefined || value === '') return null
  if (typeof value !== 'string') throw new ApiRouteError(code, 400)
  return uuidValue(value, code)
}

export async function PATCH(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const { id } = await context.params
    const body = await readJsonObject(request)
    const { data, error } = await caller.client.rpc(
      'save_product_category_tax_assignment',
      {
        p_category_id: uuidValue(id),
        p_master_version: requiredVersion(body),
        p_sales_tax_rule_id: nullableUuid(
          body.salesTaxRuleId,
          'INVALID_SALES_TAX_RULE_ID',
        ),
        p_purchase_tax_rule_id: nullableUuid(
          body.purchaseTaxRuleId,
          'INVALID_PURCHASE_TAX_RULE_ID',
        ),
      },
    )
    if (error) {
      const known = [
        'MASTER_VERSION_CONFLICT',
        'PRODUCT_CATEGORY_NOT_FOUND',
        'CATALOG_MANAGER_REQUIRED',
        'TAX_SALES_FEATURE_DISABLED',
        'TAX_PURCHASE_FEATURE_DISABLED',
        'CURRENT_SALES_TAX_RULE_REQUIRED',
        'CURRENT_PURCHASE_TAX_RULE_REQUIRED',
      ].find((code) => error.message.includes(code))
      if (known) {
        const status = known === 'CATALOG_MANAGER_REQUIRED' ? 403
          : known === 'MASTER_VERSION_CONFLICT' ? 409 : 400
        throw new ApiRouteError(known, status)
      }
      throw new ApiRouteError(error.message || 'TAX_ASSIGNMENT_FAILED', 500)
    }
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}
