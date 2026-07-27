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

const selectFields =
  'id, company_id, code, name, uom_type, allow_decimal, decimal_precision, is_active, master_version, created_at, updated_at'
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
      .select('allow_decimal, decimal_precision, master_version')
      .eq('company_id', companyId)
      .eq('id', id)
      .maybeSingle()
    if (currentResult.error) throwDatabaseError(currentResult.error)
    if (!currentResult.data) throw new ApiRouteError('MASTER_NOT_FOUND', 404)
    if (currentResult.data.master_version !== masterVersion) {
      throw new ApiRouteError('MASTER_VERSION_CONFLICT', 409)
    }

    const allowDecimal = optionalBoolean(body, 'allowDecimal') ?? currentResult.data.allow_decimal
    const precisionInput =
      'decimalPrecision' in body ? body.decimalPrecision : currentResult.data.decimal_precision
    if (!allowDecimal && 'decimalPrecision' in body && body.decimalPrecision !== 0) {
      throw new ApiRouteError('INTEGER_UOM_PRECISION_MUST_BE_ZERO', 400)
    }
    const decimalPrecision = allowDecimal
      ? integerValue(precisionInput, 'DECIMAL_PRECISION_INVALID', 1, 6)
      : 0

    const changes: Record<string, string | boolean | number> = {
      allow_decimal: allowDecimal,
      decimal_precision: decimalPrecision,
    }
    if ('name' in body) changes.name = requiredText(body, 'name', { maxLength: 100 })
    if ('uomType' in body) {
      changes.uom_type = enumValue(body.uomType, UOM_TYPES, 'UOM_TYPE_INVALID')
    }
    const isActive = optionalBoolean(body, 'isActive')
    if (isActive !== undefined) changes.is_active = isActive

    const { data, error } = await caller.client
      .from('uoms')
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
