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

const TAX_SCOPES = ['SALES', 'PURCHASE'] as const
const CALCULATION_SCOPES = ['PER_LINE', 'PER_DOCUMENT'] as const
const PRICE_MODES = ['INCLUSIVE', 'EXCLUSIVE'] as const
const STATUSES = ['DRAFT', 'ACTIVE'] as const

function dateValue(value: unknown, code: string, required = false) {
  if (value === null || value === undefined || value === '') {
    if (required) throw new ApiRouteError(code, 400)
    return null
  }
  if (typeof value !== 'string' || Number.isNaN(Date.parse(value))) {
    throw new ApiRouteError(code, 400)
  }
  return new Date(value).toISOString()
}

function rateValue(value: unknown) {
  const rate = typeof value === 'number' ? value : Number(value)
  if (!Number.isFinite(rate) || rate < 0 || rate > 100) {
    throw new ApiRouteError('INVALID_TAX_RATE', 400)
  }
  return rate
}

export type TaxRuleInput = ReturnType<typeof parseTaxRuleBody>

export function parseTaxRuleBody(body: JsonObject, updating: boolean) {
  const scope = enumValue(body.scope, TAX_SCOPES, 'INVALID_TAX_SCOPE')
  const priceMode = enumValue(body.priceMode, PRICE_MODES, 'INVALID_TAX_PRICE_MODE')
  const status = enumValue(body.status, STATUSES, 'INVALID_TAX_RULE_STATUS')
  const isActive = optionalBoolean(body, 'isActive') ?? true
  const effectiveFrom = dateValue(body.effectiveFrom, 'EFFECTIVE_FROM_REQUIRED', true)!
  const effectiveTo = dateValue(body.effectiveTo, 'EFFECTIVE_TO_INVALID')
  if (effectiveTo && effectiveTo <= effectiveFrom) {
    throw new ApiRouteError('INVALID_EFFECTIVE_PERIOD', 400)
  }
  if (scope === 'SALES' && priceMode !== 'INCLUSIVE') {
    throw new ApiRouteError('SALES_TAX_MUST_BE_INCLUSIVE', 400)
  }
  if (status === 'ACTIVE' && !isActive) {
    throw new ApiRouteError('TAX_ACTIVE_VERSION_REQUIRES_ACTIVE_RULE', 400)
  }
  let isRecoverable: boolean | null = null
  if (scope === 'PURCHASE') {
    const recoverable = optionalBoolean(body, 'isRecoverable')
    if (recoverable === undefined) {
      throw new ApiRouteError('PURCHASE_TAX_RECOVERABLE_REQUIRED', 400)
    }
    isRecoverable = recoverable
  }

  return {
    masterVersion: updating ? requiredVersion(body) : null,
    code: requiredText(body, 'code', { uppercase: true, maxLength: 100 }),
    name: requiredText(body, 'name', { maxLength: 200 }),
    scope,
    ratePercent: rateValue(body.ratePercent),
    calculationScope: enumValue(
      body.calculationScope,
      CALCULATION_SCOPES,
      'INVALID_TAX_CALCULATION_SCOPE',
    ),
    priceMode,
    accountId: uuidValue(String(body.accountId ?? ''), 'ACTIVE_POSTABLE_TAX_ACCOUNT_REQUIRED'),
    isRecoverable,
    effectiveFrom,
    effectiveTo,
    status,
    isActive,
  }
}

export function taxRuleRpcArgs(taxRuleId: string | null, input: TaxRuleInput) {
  return {
    p_tax_rule_id: taxRuleId,
    p_master_version: input.masterVersion,
    p_tax_code: input.code,
    p_tax_name: input.name,
    p_tax_scope: input.scope,
    p_rate_percent: input.ratePercent,
    p_calculation_scope: input.calculationScope,
    p_default_price_mode: input.priceMode,
    p_account_id: input.accountId,
    p_is_recoverable: input.isRecoverable,
    p_effective_from: input.effectiveFrom,
    p_effective_to: input.effectiveTo,
    p_status: input.status,
    p_is_active: input.isActive,
  }
}

export function throwTaxRuleRpcError(error: DatabaseError): never {
  const message = error?.message ?? ''
  const known = [
    'TAX_MASTER_MANAGER_REQUIRED', 'TAX_FEATURE_DISABLED', 'INVALID_TAX_SCOPE',
    'INVALID_TAX_IDENTITY', 'INVALID_TAX_RATE', 'INVALID_TAX_CALCULATION_SCOPE',
    'INVALID_TAX_PRICE_MODE', 'INVALID_TAX_RULE_STATUS',
    'TAX_ACTIVE_VERSION_REQUIRES_ACTIVE_RULE', 'EFFECTIVE_FROM_REQUIRED',
    'INVALID_EFFECTIVE_PERIOD', 'ACTIVE_POSTABLE_TAX_ACCOUNT_REQUIRED',
    'INCOMPATIBLE_TAX_ACCOUNT_TYPE', 'SALES_TAX_MUST_BE_INCLUSIVE',
    'SALES_TAX_RECOVERABLE_NOT_APPLICABLE', 'PURCHASE_TAX_RECOVERABLE_REQUIRED',
    'TAX_RULE_NOT_FOUND', 'MASTER_VERSION_CONFLICT',
    'TAX_SCOPE_LOCKED_BY_VERSION_HISTORY', 'TAX_RULE_VERSION_CONFLICT',
    'TAX_RULE_VERSION_PERIOD_OVERLAP', 'DUPLICATE_TAX_RULE',
  ].find((code) => message.includes(code))
  if (known) {
    const conflict = ['MASTER_VERSION_CONFLICT', 'TAX_RULE_VERSION_CONFLICT',
      'TAX_RULE_VERSION_PERIOD_OVERLAP', 'DUPLICATE_TAX_RULE'].includes(known)
    throw new ApiRouteError(
      known,
      known === 'TAX_MASTER_MANAGER_REQUIRED' ? 403
        : known === 'TAX_FEATURE_DISABLED' || conflict ? 409 : 400,
    )
  }
  if (error?.code === '23514' || error?.code === '23503') {
    throw new ApiRouteError('TAX_RULE_VALIDATION_FAILED', 400)
  }
  if (error?.code === '42501') throw new ApiRouteError('FORBIDDEN', 403)
  throw new ApiRouteError(message || 'TAX_RULE_OPERATION_FAILED', 500)
}
