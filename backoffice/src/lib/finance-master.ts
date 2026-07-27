import { ApiRouteError } from '@/lib/server-auth'
import {
  enumValue,
  optionalBoolean,
  optionalText,
  requiredText,
  requiredVersion,
  uuidValue,
} from '@/lib/master-data'

type JsonObject = Record<string, unknown>
type DatabaseError = { code?: string; message?: string } | null

const RULE_STATUSES = ['DRAFT', 'ACTIVE'] as const
const ACCOUNT_TYPES = [
  'ASSET', 'LIABILITY', 'EQUITY', 'REVENUE', 'COGS', 'EXPENSE',
  'OTHER_INCOME', 'OTHER_EXPENSE',
] as const
const NORMAL_BALANCES = ['DEBIT', 'CREDIT'] as const
const FALLBACK_STATUSES = ['DRAFT', 'ACTIVE'] as const

function nullableText(value: unknown, maxLength: number, code: string) {
  if (value === null || value === undefined || value === '') return null
  if (typeof value !== 'string') throw new ApiRouteError(code, 400)
  const normalized = value.trim().replace(/\s+/g, ' ')
  if (!normalized) return null
  if (normalized.length > maxLength) throw new ApiRouteError(code, 400)
  return normalized
}

function requiredDate(value: unknown, code: string): string {
  if (typeof value !== 'string' || Number.isNaN(Date.parse(value))) {
    throw new ApiRouteError(code, 400)
  }
  return new Date(value).toISOString()
}

function nullableDate(value: unknown, code: string): string | null {
  if (value === null || value === undefined || value === '') return null
  return requiredDate(value, code)
}

export function parseTransactionCategory(body: JsonObject, updating: boolean) {
  return {
    masterVersion: updating ? requiredVersion(body) : null,
    name: requiredText(body, 'name', { maxLength: 200 }),
    systemKey: requiredText(body, 'systemKey', {
      uppercase: true,
      maxLength: 100,
    }),
    description: nullableText(body.description, 1000, 'DESCRIPTION_INVALID'),
    isActive: optionalBoolean(body, 'isActive') ?? true,
  }
}

export function categoryRpcArgs(
  categoryId: string | null,
  input: ReturnType<typeof parseTransactionCategory>,
) {
  return {
    p_category_id: categoryId,
    p_master_version: input.masterVersion,
    p_category_name: input.name,
    p_system_key: input.systemKey,
    p_description: input.description,
    p_is_active: input.isActive,
  }
}

export function parseTransactionRule(body: JsonObject) {
  const effectiveFrom = requiredDate(body.effectiveFrom, 'EFFECTIVE_FROM_REQUIRED')
  const effectiveTo = nullableDate(body.effectiveTo, 'EFFECTIVE_TO_INVALID')
  if (effectiveTo && effectiveTo <= effectiveFrom) {
    throw new ApiRouteError('INVALID_EFFECTIVE_PERIOD', 400)
  }
  return {
    categoryId: uuidValue(String(body.categoryId ?? ''), 'CATEGORY_ID_INVALID'),
    accountFunctionKey: requiredText(body, 'accountFunctionKey', {
      uppercase: true,
      maxLength: 100,
    }),
    accountId: uuidValue(String(body.accountId ?? ''), 'ACCOUNT_ID_INVALID'),
    effectiveFrom,
    effectiveTo,
    status: enumValue(body.status, RULE_STATUSES, 'RULE_STATUS_INVALID'),
  }
}

export function ruleRpcArgs(input: ReturnType<typeof parseTransactionRule>) {
  return {
    p_rule_id: null,
    p_transaction_category_id: input.categoryId,
    p_account_function_key: input.accountFunctionKey,
    p_account_id: input.accountId,
    p_effective_from: input.effectiveFrom,
    p_effective_to: input.effectiveTo,
    p_status: input.status,
  }
}

export function parseChartOfAccount(body: JsonObject, updating: boolean) {
  const parentAccountId = optionalText(body, 'parentAccountId', { maxLength: 36 })
  const systemFunctionKey = optionalText(body, 'systemFunctionKey', {
    uppercase: true,
    maxLength: 100,
  })
  return {
    masterVersion: updating ? requiredVersion(body) : null,
    code: requiredText(body, 'code', { maxLength: 100 }),
    name: requiredText(body, 'name', { maxLength: 200 }),
    accountType: enumValue(body.accountType, ACCOUNT_TYPES, 'ACCOUNT_TYPE_INVALID'),
    normalBalance: enumValue(
      body.normalBalance,
      NORMAL_BALANCES,
      'NORMAL_BALANCE_INVALID',
    ),
    parentAccountId: parentAccountId
      ? uuidValue(parentAccountId, 'PARENT_ACCOUNT_ID_INVALID')
      : null,
    systemFunctionKey: systemFunctionKey || null,
    isPostable: optionalBoolean(body, 'isPostable') ?? true,
    allowManualPosting: optionalBoolean(body, 'allowManualPosting') ?? false,
    allowReconciliation: optionalBoolean(body, 'allowReconciliation') ?? false,
    isActive: optionalBoolean(body, 'isActive') ?? true,
  }
}

export function accountRpcArgs(
  accountId: string | null,
  input: ReturnType<typeof parseChartOfAccount>,
) {
  return {
    p_account_id: accountId,
    p_master_version: input.masterVersion,
    p_account_code: input.code,
    p_account_name: input.name,
    p_account_type: input.accountType,
    p_normal_balance: input.normalBalance,
    p_parent_account_id: input.parentAccountId,
    p_system_function_key: input.systemFunctionKey,
    p_is_postable: input.isPostable,
    p_allow_manual_posting: input.allowManualPosting,
    p_allow_reconciliation: input.allowReconciliation,
    p_is_active: input.isActive,
  }
}

export function parseCompanyFallback(body: JsonObject) {
  const effectiveFrom = requiredDate(body.effectiveFrom, 'EFFECTIVE_FROM_REQUIRED')
  const effectiveTo = nullableDate(body.effectiveTo, 'EFFECTIVE_TO_INVALID')
  if (effectiveTo && effectiveTo <= effectiveFrom) {
    throw new ApiRouteError('INVALID_EFFECTIVE_PERIOD', 400)
  }
  return {
    accountFunctionKey: requiredText(body, 'accountFunctionKey', {
      uppercase: true,
      maxLength: 100,
    }),
    accountId: uuidValue(String(body.accountId ?? ''), 'ACCOUNT_ID_INVALID'),
    effectiveFrom,
    effectiveTo,
    status: enumValue(body.status, FALLBACK_STATUSES, 'FALLBACK_STATUS_INVALID'),
  }
}

export function fallbackRpcArgs(input: ReturnType<typeof parseCompanyFallback>) {
  return {
    p_fallback_id: null,
    p_account_function_key: input.accountFunctionKey,
    p_account_id: input.accountId,
    p_effective_from: input.effectiveFrom,
    p_effective_to: input.effectiveTo,
    p_status: input.status,
  }
}

export function throwFinanceMasterRpcError(error: DatabaseError): never {
  const message = error?.message ?? ''
  const known = [
    'FINANCE_MASTER_MANAGER_REQUIRED',
    'INVALID_TRANSACTION_CATEGORY_IDENTITY',
    'ACTIVE_SYSTEM_EVENT_NOT_FOUND',
    'TRANSACTION_CATEGORY_NOT_FOUND',
    'ACTIVE_TRANSACTION_CATEGORY_NOT_FOUND',
    'MASTER_VERSION_CONFLICT',
    'DUPLICATE_TRANSACTION_CATEGORY',
    'ACTIVE_POSTABLE_ACCOUNT_REQUIRED',
    'INCOMPATIBLE_ACCOUNT_TYPE',
    'CATEGORY_SYSTEM_EVENT_MISMATCH',
    'CATEGORY_SYSTEM_EVENT_LOCKED_BY_HISTORY',
    'TRANSACTION_RULE_PERIOD_OVERLAP',
    'RULE_VERSION_CONFLICT',
    'INVALID_EFFECTIVE_PERIOD',
    'REQUIRED_TRANSACTION_CATEGORY_CANNOT_BE_DISABLED',
    'REQUIRED_TRANSACTION_CATEGORY_SYSTEM_EVENT_LOCKED',
    'REQUIRED_TRANSACTION_CATEGORY_CANNOT_BE_DELETED',
    'INVALID_ACCOUNT_IDENTITY',
    'INVALID_ACCOUNT_TYPE',
    'INVALID_NORMAL_BALANCE',
    'MANUAL_POSTING_REQUIRES_POSTABLE_ACCOUNT',
    'SYSTEM_ACCOUNT_FLAG_LOCKED',
    'ACCOUNT_IN_USE_BY_ACTIVE_RULE',
    'ACCOUNT_IN_USE_BY_ACTIVE_FALLBACK',
    'ACTIVE_CHILD_ACCOUNT_EXISTS',
    'COA_HIERARCHY_CYCLE',
    'COA_HIERARCHY_MAX_DEPTH_EXCEEDED',
    'PARENT_ACCOUNT_NOT_FOUND',
    'PARENT_ACCOUNT_MUST_BE_NONPOSTABLE',
    'ACTIVE_PARENT_ACCOUNT_REQUIRED',
    'PARENT_ACCOUNT_TYPE_MISMATCH',
    'PARENT_ACCOUNT_CANNOT_BE_POSTABLE',
    'CHILD_ACCOUNT_TYPE_MISMATCH',
    'ACTIVE_ACCOUNT_FUNCTION_NOT_FOUND',
    'ACCOUNT_TYPE_LOCKED_BY_HISTORY',
    'ACCOUNT_FUNCTION_LOCKED_BY_HISTORY',
    'CHART_OF_ACCOUNT_NOT_FOUND',
    'DUPLICATE_CHART_OF_ACCOUNT',
    'INVALID_FALLBACK_STATUS',
    'FALLBACK_VERSION_CONFLICT',
    'COMPANY_FALLBACK_NOT_FOUND',
    'ACTIVE_COMPANY_FALLBACK_IMMUTABLE',
    'FALLBACK_FUNCTION_LOCKED',
    'COMPANY_FALLBACK_PERIOD_OVERLAP',
  ].find((code) => message.includes(code))
  if (known) {
    const conflict = [
      'MASTER_VERSION_CONFLICT',
      'DUPLICATE_TRANSACTION_CATEGORY',
      'TRANSACTION_RULE_PERIOD_OVERLAP',
      'RULE_VERSION_CONFLICT',
      'CATEGORY_SYSTEM_EVENT_LOCKED_BY_HISTORY',
      'REQUIRED_TRANSACTION_CATEGORY_CANNOT_BE_DISABLED',
      'REQUIRED_TRANSACTION_CATEGORY_SYSTEM_EVENT_LOCKED',
      'REQUIRED_TRANSACTION_CATEGORY_CANNOT_BE_DELETED',
      'SYSTEM_ACCOUNT_FLAG_LOCKED',
      'ACCOUNT_IN_USE_BY_ACTIVE_RULE',
      'ACCOUNT_IN_USE_BY_ACTIVE_FALLBACK',
      'ACTIVE_CHILD_ACCOUNT_EXISTS',
      'ACCOUNT_TYPE_LOCKED_BY_HISTORY',
      'ACCOUNT_FUNCTION_LOCKED_BY_HISTORY',
      'DUPLICATE_CHART_OF_ACCOUNT',
      'FALLBACK_VERSION_CONFLICT',
      'ACTIVE_COMPANY_FALLBACK_IMMUTABLE',
      'FALLBACK_FUNCTION_LOCKED',
      'COMPANY_FALLBACK_PERIOD_OVERLAP',
    ].includes(known)
    throw new ApiRouteError(
      known,
      known === 'FINANCE_MASTER_MANAGER_REQUIRED' ? 403 : conflict ? 409 : 400,
    )
  }
  if (error?.code === '23505') throw new ApiRouteError('DUPLICATE_FINANCE_MASTER', 409)
  if (error?.code === '23503') throw new ApiRouteError('INVALID_FINANCE_REFERENCE', 400)
  if (error?.code === '23514') throw new ApiRouteError('FINANCE_MASTER_VALIDATION_FAILED', 400)
  if (error?.code === '42501') throw new ApiRouteError('FORBIDDEN', 403)
  throw new ApiRouteError(message || 'FINANCE_MASTER_OPERATION_FAILED', 500)
}
