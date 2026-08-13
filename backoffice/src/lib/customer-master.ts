import { ApiRouteError } from '@/lib/server-auth'
import {
  enumValue,
  optionalBoolean,
  requiredText,
  requiredVersion,
  uuidValue,
} from '@/lib/master-data'

type JsonObject = Record<string, unknown>
type DatabaseError = { code?: string; message?: string } | null

const CUSTOMER_TYPES = ['INDIVIDUAL', 'BUSINESS'] as const

function nullableText(body: JsonObject, field: string, maxLength: number): string | null {
  const value = body[field]
  if (value === null || value === undefined || value === '') return null
  if (typeof value !== 'string') throw new ApiRouteError(`${field.toUpperCase()}_INVALID`, 400)
  const normalized = value.trim().replace(/\s+/g, ' ')
  if (!normalized) return null
  if (normalized.length > maxLength) throw new ApiRouteError(`${field.toUpperCase()}_TOO_LONG`, 400)
  return normalized
}

function nonnegativeMoney(body: JsonObject, field: string): number {
  const value = body[field] ?? 0
  const amount = typeof value === 'number' ? value : Number(value)
  if (!Number.isFinite(amount) || amount < 0) throw new ApiRouteError(`${field.toUpperCase()}_INVALID`, 400)
  return amount
}

function nullableInteger(body: JsonObject, field: string): number | null {
  const value = body[field]
  if (value === null || value === undefined || value === '') return null
  const number = typeof value === 'number' ? value : Number(value)
  if (!Number.isSafeInteger(number) || number < 0 || number > 3650) {
    throw new ApiRouteError(`${field.toUpperCase()}_INVALID`, 400)
  }
  return number
}

export function parseCustomerCategoryBody(body: JsonObject, updating: boolean) {
  return {
    masterVersion: updating ? requiredVersion(body) : null,
    categoryName: requiredText(body, 'categoryName', { maxLength: 200 }),
    isActive: optionalBoolean(body, 'isActive') ?? true,
  }
}

export function customerCategoryRpcArgs(
  customerCategoryId: string | null,
  input: ReturnType<typeof parseCustomerCategoryBody>,
) {
  return {
    p_customer_category_id: customerCategoryId,
    p_master_version: input.masterVersion,
    p_category_name: input.categoryName,
    p_is_active: input.isActive,
  }
}

export function parseCustomerBody(body: JsonObject, updating: boolean) {
  const rawCode = nullableText(body, 'customerCode', 100)
  if (updating && !rawCode) throw new ApiRouteError('CUSTOMER_CODE_REQUIRED', 400)
  const category = body.customerCategoryId
  if (typeof category !== 'string') throw new ApiRouteError('CUSTOMER_CATEGORY_REQUIRED', 400)
  const parent = body.parentCustomerId
  if (parent !== null && parent !== undefined && parent !== '' && typeof parent !== 'string') {
    throw new ApiRouteError('PARENT_CUSTOMER_INVALID', 400)
  }
  const pricelist = body.defaultPricelistId
  if (pricelist !== null && pricelist !== undefined && pricelist !== '' && typeof pricelist !== 'string') {
    throw new ApiRouteError('DEFAULT_PRICELIST_INVALID', 400)
  }
  return {
    masterVersion: updating ? requiredVersion(body) : null,
    customerCode: rawCode?.toUpperCase() ?? null,
    customerName: requiredText(body, 'customerName', { maxLength: 200 }),
    customerCategoryId: uuidValue(category, 'CUSTOMER_CATEGORY_INVALID'),
    parentCustomerId:
      typeof parent === 'string' && parent !== ''
        ? uuidValue(parent, 'PARENT_CUSTOMER_INVALID')
        : null,
    defaultPricelistId:
      typeof pricelist === 'string' && pricelist !== ''
        ? uuidValue(pricelist, 'DEFAULT_PRICELIST_INVALID')
        : null,
    phone: nullableText(body, 'phone', 100),
    email: nullableText(body, 'email', 320)?.toLowerCase() ?? null,
    address: nullableText(body, 'address', 1000),
    customerType: enumValue(body.customerType ?? 'INDIVIDUAL', CUSTOMER_TYPES, 'CUSTOMER_TYPE_INVALID'),
    creditLimit: nonnegativeMoney(body, 'creditLimit'),
    creditTermDays: nullableInteger(body, 'creditTermDays'),
    notes: nullableText(body, 'notes', 1000),
    isActive: optionalBoolean(body, 'isActive') ?? true,
  }
}

export function customerRpcArgs(customerId: string | null, input: ReturnType<typeof parseCustomerBody>) {
  return {
    p_customer_id: customerId,
    p_master_version: input.masterVersion,
    p_customer_code: input.customerCode,
    p_customer_name: input.customerName,
    p_customer_category_id: input.customerCategoryId,
    p_phone: input.phone,
    p_email: input.email,
    p_address: input.address,
    p_customer_type: input.customerType,
    p_credit_limit: input.creditLimit,
    p_credit_term_days: input.creditTermDays,
    p_notes: input.notes,
    p_is_active: input.isActive,
    p_parent_customer_id: input.parentCustomerId,
    p_default_pricelist_id: input.defaultPricelistId,
  }
}

export function throwCustomerRpcError(error: DatabaseError): never {
  const message = error?.message ?? ''
  const known = [
    'CUSTOMER_MANAGER_REQUIRED', 'CUSTOMER_CREDIT_MANAGER_REQUIRED',
    'INVALID_CUSTOMER_CATEGORY_CODE', 'INVALID_CUSTOMER_CATEGORY_NAME',
    'CUSTOMER_CATEGORY_NOT_FOUND', 'SYSTEM_CUSTOMER_CATEGORY_IMMUTABLE',
    'INVALID_CUSTOMER_CODE', 'INVALID_CUSTOMER_NAME', 'INVALID_CUSTOMER_TYPE',
    'INVALID_CUSTOMER_CREDIT_LIMIT', 'INVALID_CUSTOMER_CREDIT_TERM',
    'ACTIVE_CUSTOMER_CATEGORY_NOT_FOUND', 'CUSTOMER_NOT_FOUND',
    'SYSTEM_CUSTOMER_IMMUTABLE', 'MASTER_VERSION_CONFLICT',
    'CUSTOMER_CANNOT_PARENT_ITSELF', 'ACTIVE_ROOT_PARENT_CUSTOMER_NOT_FOUND',
    'CUSTOMER_WITH_CHILDREN_CANNOT_BECOME_CHILD',
    'ACTIVE_CUSTOMER_PRICELIST_NOT_FOUND', 'SYSTEM_CUSTOMER_CANNOT_HAVE_PRICELIST',
    'DUPLICATE_CUSTOMER_CATEGORY', 'DUPLICATE_CUSTOMER',
    'CUSTOM_PERMISSION_DENIED',
  ].find((code) => message.includes(code))
  if (known) {
    const forbidden = (known.endsWith('_REQUIRED') && known.includes('MANAGER')) ||
      known === 'CUSTOM_PERMISSION_DENIED'
    const conflict = known === 'MASTER_VERSION_CONFLICT' || known.startsWith('DUPLICATE_')
    throw new ApiRouteError(known, forbidden ? 403 : conflict ? 409 : 400)
  }
  if (error?.code === '42501') throw new ApiRouteError('FORBIDDEN', 403)
  throw new ApiRouteError(message || 'CUSTOMER_OPERATION_FAILED', 500)
}
