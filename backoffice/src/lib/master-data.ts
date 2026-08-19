import { ApiRouteError } from '@/lib/server-auth'

type JsonObject = Record<string, unknown>
type DatabaseError = { code?: string; message?: string } | null

export const UOM_TYPES = [
  'UNIT',
  'PACKAGING',
  'WEIGHT',
  'VOLUME',
  'LENGTH',
  'OTHER',
] as const

export const WAREHOUSE_TYPES = ['CENTRAL', 'STORE', 'DAMAGED', 'TRANSIT'] as const

export type UomType = (typeof UOM_TYPES)[number]
export type WarehouseType = (typeof WAREHOUSE_TYPES)[number]

export async function readJsonObject(request: Request): Promise<JsonObject> {
  let value: unknown
  try {
    value = await request.json()
  } catch {
    throw new ApiRouteError('INVALID_JSON_BODY', 400)
  }

  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new ApiRouteError('INVALID_JSON_BODY', 400)
  }
  return value as JsonObject
}

export function requiredText(
  body: JsonObject,
  field: string,
  options: { uppercase?: boolean; maxLength?: number } = {},
): string {
  const value = body[field]
  if (typeof value !== 'string') throw new ApiRouteError(`${field.toUpperCase()}_REQUIRED`, 400)

  let normalized = value.trim().replace(/\s+/g, ' ')
  if (options.uppercase) normalized = normalized.toUpperCase()
  if (!normalized) throw new ApiRouteError(`${field.toUpperCase()}_REQUIRED`, 400)
  if (options.maxLength && normalized.length > options.maxLength) {
    throw new ApiRouteError(`${field.toUpperCase()}_TOO_LONG`, 400)
  }
  return normalized
}

export function optionalText(
  body: JsonObject,
  field: string,
  options: { uppercase?: boolean; maxLength?: number } = {},
): string | null | undefined {
  if (!(field in body)) return undefined
  if (body[field] === null) return null
  return requiredText(body, field, options)
}

export function optionalBoolean(body: JsonObject, field: string): boolean | undefined {
  if (!(field in body)) return undefined
  if (typeof body[field] !== 'boolean') {
    throw new ApiRouteError(`${field.toUpperCase()}_MUST_BE_BOOLEAN`, 400)
  }
  return body[field]
}

export function requiredVersion(body: JsonObject): number {
  const value = body.masterVersion
  if (!Number.isSafeInteger(value) || Number(value) < 1) {
    throw new ApiRouteError('MASTER_VERSION_REQUIRED', 400)
  }
  return Number(value)
}

export function enumValue<T extends string>(
  value: unknown,
  allowed: readonly T[],
  code: string,
): T {
  if (typeof value !== 'string') throw new ApiRouteError(code, 400)
  const normalized = value.trim().toUpperCase()
  if (!allowed.includes(normalized as T)) throw new ApiRouteError(code, 400)
  return normalized as T
}

export function integerValue(value: unknown, code: string, min: number, max: number): number {
  if (!Number.isSafeInteger(value)) throw new ApiRouteError(code, 400)
  const number = Number(value)
  if (number < min || number > max) throw new ApiRouteError(code, 400)
  return number
}

export function ensurePatchFields(body: JsonObject, fields: string[]) {
  if (!fields.some((field) => field in body)) {
    throw new ApiRouteError('NO_CHANGES_SUBMITTED', 400)
  }
}

export function throwDatabaseError(error: DatabaseError): never {
  const message = error?.message || ''
  const knownCode = [
    'MASTER_NAME_ALREADY_EXISTS',
    'MASTER_VERSION_CONFLICT',
    'MASTER_VERSION_REQUIRED',
    'MASTER_NOT_FOUND',
    'UOM_IN_USE',
    'PRODUCT_CATEGORY_IN_USE',
    'UOM_SEMANTICS_LOCKED_BY_USAGE',
    'INVENTORY_MASTER_ACCESS_DENIED',
    'CUSTOM_PERMISSION_DENIED',
    'ACTIVE_COMPANY_CONTEXT_MISMATCH',
    'AUTHENTICATION_REQUIRED',
    'ACTIVE_STORE_NOT_FOUND',
    'STORE_WAREHOUSE_REQUIRES_STORE',
    'UOM_TYPE_INVALID',
    'WAREHOUSE_TYPE_INVALID',
    'DECIMAL_PRECISION_INVALID',
    'MASTER_NAME_INVALID',
    'LOCATION_INVALID',
  ].find((code) => message.includes(code))
  if (knownCode) {
    const status = knownCode === 'MASTER_NOT_FOUND' ? 404
      : ['INVENTORY_MASTER_ACCESS_DENIED', 'CUSTOM_PERMISSION_DENIED'].includes(knownCode) ? 403
        : [
            'MASTER_NAME_ALREADY_EXISTS',
            'MASTER_VERSION_CONFLICT',
            'UOM_IN_USE',
            'PRODUCT_CATEGORY_IN_USE',
            'UOM_SEMANTICS_LOCKED_BY_USAGE',
          ].includes(knownCode) ? 409
          : 400
    throw new ApiRouteError(knownCode, status)
  }
  if (error?.code === '23505') throw new ApiRouteError('DUPLICATE_MASTER', 409)
  if (error?.code === '23503') throw new ApiRouteError('INVALID_MASTER_REFERENCE', 400)
  if (error?.code === '23514') throw new ApiRouteError('MASTER_VALIDATION_FAILED', 400)
  if (error?.code === '22P02') throw new ApiRouteError('INVALID_IDENTIFIER', 400)
  if (error?.code === '42501') throw new ApiRouteError('FORBIDDEN', 403)
  throw new ApiRouteError(message || 'MASTER_DATA_OPERATION_FAILED', 500)
}

export function uuidValue(value: string, code = 'INVALID_IDENTIFIER'): string {
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)) {
    throw new ApiRouteError(code, 400)
  }
  return value
}

export function parseIncludeInactive(request: Request): boolean {
  return new URL(request.url).searchParams.get('includeInactive') === 'true'
}

export function validateWarehouseCode(code: string): string {
  if (!/^[A-Z]{1,5}$/.test(code)) {
    throw new ApiRouteError('WAREHOUSE_CODE_INVALID', 400)
  }
  return code
}
