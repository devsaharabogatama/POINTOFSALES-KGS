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

const METHOD_TYPES = [
  'CASH',
  'TRANSFER',
  'QRIS',
  'CARD',
  'E_WALLET',
  'TEMPO',
  'CUSTOM',
] as const
const SETTLEMENT_ROUTES = [
  'CASH_DRAWER',
  'DIRECT_BANK',
  'CLEARING',
  'RECEIVABLE',
] as const
const PROOF_MODES = ['OPTIONAL', 'REQUIRED'] as const
const FEE_BEARERS = ['COMPANY', 'CUSTOMER'] as const
const FEE_TYPES = ['PERCENT', 'FIXED', 'PERCENT_PLUS_FIXED'] as const

function uuidArray(value: unknown): string[] {
  if (value === undefined || value === null) return []
  if (!Array.isArray(value)) throw new ApiRouteError('STORE_IDS_INVALID', 400)
  const result = value.map((item) => {
    if (typeof item !== 'string') throw new ApiRouteError('STORE_IDS_INVALID', 400)
    return uuidValue(item, 'STORE_IDS_INVALID')
  })
  if (new Set(result).size !== result.length) {
    throw new ApiRouteError('STORE_IDS_DUPLICATE', 400)
  }
  return result
}

function nullableText(value: unknown, maxLength: number, code: string) {
  if (value === null || value === undefined || value === '') return null
  if (typeof value !== 'string') throw new ApiRouteError(code, 400)
  const normalized = value.trim().replace(/\s+/g, ' ')
  if (!normalized) return null
  if (normalized.length > maxLength) throw new ApiRouteError(code, 400)
  return normalized
}

function nullableDate(value: unknown, code: string): string | null {
  if (value === null || value === undefined || value === '') return null
  if (typeof value !== 'string' || Number.isNaN(Date.parse(value))) {
    throw new ApiRouteError(code, 400)
  }
  return new Date(value).toISOString()
}

function nullableNumber(value: unknown, code: string, min: number, max: number) {
  if (value === null || value === undefined || value === '') return null
  const parsed = typeof value === 'number' ? value : Number(value)
  if (!Number.isFinite(parsed) || parsed < min || parsed > max) {
    throw new ApiRouteError(code, 400)
  }
  return parsed
}

export type PaymentMethodInput = ReturnType<typeof parsePaymentMethodBody>

export function parsePaymentMethodBody(body: JsonObject, updating: boolean) {
  const methodType = enumValue(body.methodType, METHOD_TYPES, 'INVALID_PAYMENT_METHOD_TYPE')
  const settlementRoute = enumValue(
    body.settlementRoute,
    SETTLEMENT_ROUTES,
    'INVALID_SETTLEMENT_ROUTE',
  )
  const routeValid =
    (methodType === 'CASH' && settlementRoute === 'CASH_DRAWER') ||
    (methodType === 'TEMPO' && settlementRoute === 'RECEIVABLE') ||
    (['TRANSFER', 'QRIS', 'CARD', 'E_WALLET'].includes(methodType) &&
      ['DIRECT_BANK', 'CLEARING'].includes(settlementRoute)) ||
    methodType === 'CUSTOM'
  if (!routeValid) throw new ApiRouteError('PAYMENT_METHOD_ROUTE_MISMATCH', 400)

  const availableAllStores = optionalBoolean(body, 'availableAllStores') ?? true
  const storeIds = uuidArray(body.storeIds)
  if (!availableAllStores && storeIds.length === 0) {
    throw new ApiRouteError('PAYMENT_METHOD_STORE_REQUIRED', 400)
  }

  const isActive = optionalBoolean(body, 'isActive') ?? true
  const isDefault = optionalBoolean(body, 'isDefault') ?? false
  if (isDefault && !isActive) {
    throw new ApiRouteError('DEFAULT_PAYMENT_METHOD_MUST_BE_ACTIVE', 400)
  }

  const feeEnabled = optionalBoolean(body, 'feeEnabled') ?? false
  const feeBearer = feeEnabled
    ? enumValue(body.feeBearer, FEE_BEARERS, 'INVALID_FEE_BEARER')
    : null
  const feeType = feeEnabled
    ? enumValue(body.feeType, FEE_TYPES, 'INVALID_FEE_TYPE')
    : null
  if (feeEnabled && !['DIRECT_BANK', 'CLEARING'].includes(settlementRoute)) {
    throw new ApiRouteError('FEE_REQUIRES_ELECTRONIC_SETTLEMENT', 400)
  }
  const feePercent = feeEnabled && feeType !== 'FIXED'
    ? nullableNumber(body.feePercent, 'INVALID_FEE_PERCENT', 0, 100)
    : null
  const feeFixedAmount = feeEnabled && feeType !== 'PERCENT'
    ? nullableNumber(body.feeFixedAmount, 'INVALID_FEE_FIXED_AMOUNT', 0, Number.MAX_SAFE_INTEGER)
    : null
  if (feeEnabled && feeType !== 'FIXED' && feePercent === null) {
    throw new ApiRouteError('FEE_PERCENT_REQUIRED', 400)
  }
  if (feeEnabled && feeType !== 'PERCENT' && feeFixedAmount === null) {
    throw new ApiRouteError('FEE_FIXED_AMOUNT_REQUIRED', 400)
  }

  const effectiveFrom = nullableDate(body.effectiveFrom, 'EFFECTIVE_FROM_INVALID')
  const effectiveUntil = nullableDate(body.effectiveUntil, 'EFFECTIVE_UNTIL_INVALID')
  if (!effectiveFrom) throw new ApiRouteError('PAYMENT_METHOD_EFFECTIVE_FROM_REQUIRED', 400)
  if (effectiveUntil && effectiveUntil < effectiveFrom) {
    throw new ApiRouteError('INVALID_PAYMENT_METHOD_PERIOD', 400)
  }

  return {
    masterVersion: updating ? requiredVersion(body) : null,
    name: requiredText(body, 'name', { maxLength: 200 }),
    methodType,
    settlementRoute,
    isDefault,
    availableAllStores,
    storeIds,
    proofMode: enumValue(body.proofMode, PROOF_MODES, 'INVALID_PROOF_MODE'),
    feeEnabled,
    feeBearer,
    feeType,
    feePercent,
    feeFixedAmount,
    clearingAccountFunction:
      settlementRoute === 'CLEARING'
        ? nullableText(body.clearingAccountFunction, 100, 'CLEARING_FUNCTION_INVALID') ??
          'PAYMENT_CLEARING'
        : null,
    bankAccountFunction:
      settlementRoute === 'DIRECT_BANK'
        ? nullableText(body.bankAccountFunction, 100, 'BANK_FUNCTION_INVALID') ??
          'BANK_RECEIPT'
        : null,
    effectiveFrom,
    effectiveUntil,
    isActive,
  }
}

export function paymentMethodRpcArgs(
  paymentMethodId: string | null,
  input: PaymentMethodInput,
) {
  return {
    p_payment_method_id: paymentMethodId,
    p_master_version: input.masterVersion,
    p_payment_method_name: input.name,
    p_method_type: input.methodType,
    p_settlement_route: input.settlementRoute,
    p_is_default: input.isDefault,
    p_available_all_stores: input.availableAllStores,
    p_store_ids: input.storeIds,
    p_proof_mode: input.proofMode,
    p_fee_enabled: input.feeEnabled,
    p_fee_bearer: input.feeBearer,
    p_fee_type: input.feeType,
    p_fee_percent: input.feePercent,
    p_fee_fixed_amount: input.feeFixedAmount,
    p_clearing_account_function: input.clearingAccountFunction,
    p_bank_account_function: input.bankAccountFunction,
    p_effective_from: input.effectiveFrom,
    p_effective_to: input.effectiveUntil,
    p_is_active: input.isActive,
  }
}

export function throwPaymentMethodRpcError(error: DatabaseError): never {
  const message = error?.message ?? ''
  const known = [
    'PAYMENT_METHOD_MANAGER_REQUIRED',
    'INVALID_PAYMENT_METHOD_IDENTITY',
    'INTERNAL_PAYMENT_METHOD_REQUIRES_MODULE_WORKFLOW',
    'PAYMENT_METHOD_EFFECTIVE_FROM_REQUIRED',
    'INVALID_PAYMENT_METHOD_PERIOD',
    'DEFAULT_PAYMENT_METHOD_MUST_BE_ACTIVE',
    'PAYMENT_METHOD_STORE_REQUIRED',
    'ACTIVE_STORE_NOT_FOUND',
    'PAYMENT_METHOD_NOT_FOUND',
    'MASTER_VERSION_CONFLICT',
    'PAYMENT_METHOD_CODE_LOCKED_BY_HISTORY',
    'SYSTEM_PAYMENT_METHOD_CONTRACT_LOCKED',
    'ACTIVE_COMPANY_REQUIRES_ONE_DEFAULT_PAYMENT_METHOD',
    'DUPLICATE_OR_DEFAULT_PAYMENT_METHOD_CONFLICT',
  ].find((code) => message.includes(code))
  if (known) {
    const conflicts = [
      'MASTER_VERSION_CONFLICT',
      'DUPLICATE_OR_DEFAULT_PAYMENT_METHOD_CONFLICT',
      'PAYMENT_METHOD_CODE_LOCKED_BY_HISTORY',
    ]
    throw new ApiRouteError(
      known,
      known === 'PAYMENT_METHOD_MANAGER_REQUIRED' ? 403 : conflicts.includes(known) ? 409 : 400,
    )
  }
  if (error?.code === '23514') throw new ApiRouteError('PAYMENT_METHOD_VALIDATION_FAILED', 400)
  if (error?.code === '42501') throw new ApiRouteError('FORBIDDEN', 403)
  throw new ApiRouteError(message || 'PAYMENT_METHOD_OPERATION_FAILED', 500)
}
