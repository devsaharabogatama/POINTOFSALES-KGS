import { ApiRouteError } from '@/lib/server-auth'
import { enumValue, optionalBoolean, requiredText, requiredVersion, uuidValue } from '@/lib/master-data'

type JsonObject = Record<string, unknown>
type DatabaseError = { code?: string; message?: string } | null

const SCOPES = ['GLOBAL', 'CUSTOMER'] as const
const QTY_BASES = ['SALES_UOM', 'BASE_UOM_EQUIVALENT'] as const
const METHODS = ['FIXED_PRICE', 'DISCOUNT_AMOUNT', 'DISCOUNT_PERCENT'] as const

function nullableUuid(value: unknown, code: string): string | null {
  if (value === null || value === undefined || value === '') return null
  if (typeof value !== 'string') throw new ApiRouteError(code, 400)
  return uuidValue(value, code)
}

function nullableText(value: unknown, maxLength: number, code: string): string | null {
  if (value === null || value === undefined || value === '') return null
  if (typeof value !== 'string') throw new ApiRouteError(code, 400)
  const normalized = value.trim().replace(/\s+/g, ' ')
  if (!normalized) return null
  if (normalized.length > maxLength) throw new ApiRouteError(code, 400)
  return normalized
}

function finiteNumber(value: unknown, code: string, min: number, max = Number.MAX_SAFE_INTEGER) {
  const parsed = typeof value === 'number' ? value : Number(value)
  if (!Number.isFinite(parsed) || parsed < min || parsed > max) {
    throw new ApiRouteError(code, 400)
  }
  return parsed
}

function integer(value: unknown, code: string) {
  const parsed = finiteNumber(value, code, -1_000_000, 1_000_000)
  if (!Number.isSafeInteger(parsed)) throw new ApiRouteError(code, 400)
  return parsed
}

function nullableDate(value: unknown, code: string): string | null {
  if (value === null || value === undefined || value === '') return null
  if (typeof value !== 'string' || Number.isNaN(Date.parse(value))) {
    throw new ApiRouteError(code, 400)
  }
  return new Date(value).toISOString()
}

function uuidArray(value: unknown): string[] {
  if (value === undefined || value === null) return []
  if (!Array.isArray(value)) throw new ApiRouteError('STORE_IDS_INVALID', 400)
  const result = value.map((item) => {
    if (typeof item !== 'string') throw new ApiRouteError('STORE_IDS_INVALID', 400)
    return uuidValue(item, 'STORE_IDS_INVALID')
  })
  if (new Set(result).size !== result.length) throw new ApiRouteError('STORE_IDS_DUPLICATE', 400)
  return result
}

function parseRules(value: unknown, scope: (typeof SCOPES)[number]) {
  if (!Array.isArray(value)) throw new ApiRouteError('PRICELIST_RULES_ARRAY_REQUIRED', 400)
  const keys = new Set<string>()
  return value.map((item, index) => {
    if (!item || typeof item !== 'object' || Array.isArray(item)) {
      throw new ApiRouteError(`RULE_${index + 1}_INVALID`, 400)
    }
    const rule = item as JsonObject
    const productId = nullableUuid(rule.productId, `RULE_${index + 1}_PRODUCT_REQUIRED`)
    const productUomId = nullableUuid(rule.productUomId, `RULE_${index + 1}_UOM_REQUIRED`)
    if (!productId || !productUomId) throw new ApiRouteError(`RULE_${index + 1}_REFERENCE_REQUIRED`, 400)
    const minQty = scope === 'CUSTOMER' ? 1 : finiteNumber(rule.minQty ?? 1, `RULE_${index + 1}_MIN_QTY_INVALID`, 0.000001)
    const tierQtyBasis = enumValue(rule.tierQtyBasis ?? 'SALES_UOM', QTY_BASES, `RULE_${index + 1}_QTY_BASIS_INVALID`)
    const pricingMethod = enumValue(rule.pricingMethod, METHODS, `RULE_${index + 1}_METHOD_INVALID`)
    const valueField = pricingMethod === 'FIXED_PRICE' ? 'fixedUnitPrice' : pricingMethod === 'DISCOUNT_AMOUNT' ? 'discountAmountPerUnit' : 'discountPercent'
    const priceValue = finiteNumber(rule[valueField], `RULE_${index + 1}_VALUE_INVALID`, 0, pricingMethod === 'DISCOUNT_PERCENT' ? 100 : Number.MAX_SAFE_INTEGER)
    const key = `${productUomId}:${minQty}`
    if (keys.has(key)) throw new ApiRouteError('DUPLICATE_RULE_TIER', 400)
    keys.add(key)
    return {
      productId,
      productUomId,
      minQty,
      tierQtyBasis,
      pricingMethod,
      ...(pricingMethod === 'FIXED_PRICE' ? { fixedUnitPrice: priceValue } : {}),
      ...(pricingMethod === 'DISCOUNT_AMOUNT' ? { discountAmountPerUnit: priceValue } : {}),
      ...(pricingMethod === 'DISCOUNT_PERCENT' ? { discountPercent: priceValue } : {}),
      validFrom: nullableDate(rule.validFrom, `RULE_${index + 1}_VALID_FROM_INVALID`),
      validUntil: nullableDate(rule.validUntil, `RULE_${index + 1}_VALID_UNTIL_INVALID`),
      isActive: optionalBoolean(rule, 'isActive') ?? true,
    }
  })
}

export type PricelistInput = ReturnType<typeof parsePricelistBody>

export function parsePricelistBody(body: JsonObject, updating: boolean) {
  const scope = enumValue(body.scope, SCOPES, 'INVALID_PRICELIST_SCOPE')
  const legacyCustomerId = nullableUuid(body.customerId, 'CUSTOMER_ID_INVALID')
  const appliesAllStores = optionalBoolean(body, 'appliesAllStores') ?? true
  const storeIds = uuidArray(body.storeIds)
  if (legacyCustomerId) throw new ApiRouteError('PRICELIST_CUSTOMER_ASSIGNMENT_MOVED_TO_CUSTOMER', 400)
  if (!appliesAllStores && storeIds.length === 0) throw new ApiRouteError('PRICELIST_STORE_REQUIRED', 400)
  const validFrom = nullableDate(body.validFrom, 'VALID_FROM_INVALID')
  const validUntil = nullableDate(body.validUntil, 'VALID_UNTIL_INVALID')
  if (validFrom && validUntil && validUntil < validFrom) throw new ApiRouteError('INVALID_PRICELIST_PERIOD', 400)
  return {
    masterVersion: updating ? requiredVersion(body) : null,
    name: requiredText(body, 'name', { maxLength: 200 }),
    scope,
    priority: integer(body.priority ?? 0, 'PRIORITY_INVALID'),
    isDefault: scope === 'GLOBAL' ? optionalBoolean(body, 'isDefault') ?? false : false,
    appliesAllStores,
    storeIds,
    validFrom,
    validUntil,
    isActive: optionalBoolean(body, 'isActive') ?? true,
    notes: nullableText(body.notes, 1000, 'NOTES_INVALID'),
    rules: parseRules(body.rules, scope),
  }
}

export function pricelistRpcArgs(pricelistId: string | null, input: PricelistInput) {
  return {
    p_pricelist_id: pricelistId,
    p_master_version: input.masterVersion,
    p_name: input.name,
    p_scope: input.scope,
    p_priority: input.priority,
    p_is_default: input.isDefault,
    p_applies_all_stores: input.appliesAllStores,
    p_store_ids: input.storeIds,
    p_valid_from: input.validFrom,
    p_valid_until: input.validUntil,
    p_is_active: input.isActive,
    p_notes: input.notes,
    p_rules: input.rules,
  }
}

export function throwPricelistRpcError(error: DatabaseError): never {
  const message = error?.message ?? ''
  const known = [
    'PRICELIST_MANAGER_REQUIRED', 'INVALID_PRICELIST_IDENTITY',
    'INVALID_PRICELIST_SCOPE', 'INVALID_PRICELIST_PERIOD',
    'PRICELIST_CUSTOMER_ASSIGNMENT_MOVED_TO_CUSTOMER',
    'CUSTOMER_PRICELIST_CANNOT_BE_GLOBAL_DEFAULT',
    'PRICELIST_STORE_REQUIRED', 'ACTIVE_STORE_NOT_FOUND',
    'PRICELIST_RULES_ARRAY_REQUIRED', 'PRICELIST_NOT_FOUND',
    'MASTER_VERSION_CONFLICT', 'INVALID_PRICELIST_RULE',
    'INVALID_PRICELIST_RULE_VALUE', 'CUSTOMER_PRICELIST_TIER_NOT_ALLOWED',
    'ACTIVE_SALES_PRODUCT_UOM_NOT_FOUND', 'DUPLICATE_OR_DEFAULT_PRICELIST_CONFLICT',
    'ACTIVE_COMPANY_REQUIRES_ONE_DEFAULT_GLOBAL_PRICELIST',
  ].find((code) => message.includes(code))
  if (known) {
    const conflicts = ['MASTER_VERSION_CONFLICT', 'DUPLICATE_OR_DEFAULT_PRICELIST_CONFLICT']
    throw new ApiRouteError(known, known === 'PRICELIST_MANAGER_REQUIRED' ? 403 : conflicts.includes(known) ? 409 : 400)
  }
  if (error?.code === '42501') throw new ApiRouteError('FORBIDDEN', 403)
  throw new ApiRouteError(message || 'PRICELIST_OPERATION_FAILED', 500)
}
