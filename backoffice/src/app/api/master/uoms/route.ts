import { apiError, ApiRouteError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import {
  enumValue,
  integerValue,
  optionalBoolean,
  parseIncludeInactive,
  readJsonObject,
  requiredText,
  throwDatabaseError,
  UOM_TYPES,
} from '@/lib/master-data'

const selectFields =
  'id, company_id, code, name, uom_type, allow_decimal, decimal_precision, is_active, master_version, created_at, updated_at'

function precisionFor(allowDecimal: boolean, value: unknown): number {
  if (!allowDecimal) {
    if (value !== undefined && value !== 0) {
      throw new ApiRouteError('INTEGER_UOM_PRECISION_MUST_BE_ZERO', 400)
    }
    return 0
  }
  return integerValue(value ?? 3, 'DECIMAL_PRECISION_INVALID', 1, 6)
}

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    let query = caller.client
      .from('uoms')
      .select(selectFields)
      .eq('company_id', companyId)
      .order('name')
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
    const name = requiredText(body, 'name', { maxLength: 100 })
    const uomType = enumValue(body.uomType, UOM_TYPES, 'UOM_TYPE_INVALID')
    const allowDecimal = optionalBoolean(body, 'allowDecimal') ?? false
    const decimalPrecision = precisionFor(allowDecimal, body.decimalPrecision)
    const isActive = optionalBoolean(body, 'isActive') ?? true

    const { data, error } = await caller.client
      .from('uoms')
      .insert({
        company_id: companyId,
        code: null,
        name,
        uom_type: uomType,
        allow_decimal: allowDecimal,
        decimal_precision: decimalPrecision,
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
