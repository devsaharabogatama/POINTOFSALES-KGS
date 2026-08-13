import { apiError, ApiRouteError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import {
  ensurePatchFields,
  enumValue,
  integerValue,
  optionalBoolean,
  readJsonObject,
  requiredText,
  requiredVersion,
  throwDatabaseError,
  UOM_TYPES,
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
    ensurePatchFields(body, [
      'name',
      'uomType',
      'allowDecimal',
      'decimalPrecision',
      'isActive',
    ])

    const currentResult = await caller.client
      .from('uoms')
      .select('name, uom_type, allow_decimal, decimal_precision, is_active, master_version')
      .eq('company_id', companyId)
      .eq('id', id)
      .maybeSingle()
    if (currentResult.error) throwDatabaseError(currentResult.error)
    if (!currentResult.data) throw new ApiRouteError('MASTER_NOT_FOUND', 404)

    const allowDecimal = optionalBoolean(body, 'allowDecimal') ?? currentResult.data.allow_decimal
    const precisionInput =
      'decimalPrecision' in body ? body.decimalPrecision : currentResult.data.decimal_precision
    if (!allowDecimal && 'decimalPrecision' in body && body.decimalPrecision !== 0) {
      throw new ApiRouteError('INTEGER_UOM_PRECISION_MUST_BE_ZERO', 400)
    }
    const decimalPrecision = allowDecimal
      ? integerValue(precisionInput, 'DECIMAL_PRECISION_INVALID', 1, 6)
      : 0

    const name = 'name' in body
      ? requiredText(body, 'name', { maxLength: 100 })
      : currentResult.data.name
    const uomType = 'uomType' in body
      ? enumValue(body.uomType, UOM_TYPES, 'UOM_TYPE_INVALID')
      : currentResult.data.uom_type
    const isActive = optionalBoolean(body, 'isActive')

    const { data, error } = await caller.client.rpc('save_inventory_uom', {
      p_uom_id: id,
      p_expected_version: masterVersion,
      p_name: name,
      p_uom_type: uomType,
      p_allow_decimal: allowDecimal,
      p_decimal_precision: decimalPrecision,
      p_is_active: isActive ?? currentResult.data.is_active,
    })
    if (error) throwDatabaseError(error)
    return Response.json({ data: data?.data })
  } catch (error) {
    return apiError(error)
  }
}
