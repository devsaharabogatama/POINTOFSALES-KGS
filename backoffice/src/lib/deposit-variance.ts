import { ApiRouteError } from '@/lib/server-auth'
import {
  enumValue,
  optionalText,
  requiredText,
  requiredVersion,
  uuidValue,
} from '@/lib/master-data'

type JsonObject = Record<string, unknown>
type DatabaseError = { message?: string } | null

const RESOLUTION_TYPES = [
  'CASHIER_RECEIVABLE',
  'COMPANY_EXPENSE',
  'CASH_OVERAGE_INCOME',
  'REFUND_TO_SOURCE',
  'WRITE_OFF',
  'RECOVERED_FUNDS',
  'SOURCE_CORRECTION',
] as const

const SETTLEMENT_FUNCTIONS = [
  'BANK',
  'MAIN_CASH',
  'CASH_IN_TRANSIT',
] as const

export function parseResponsiblePartyBody(body: JsonObject) {
  return {
    masterVersion: requiredVersion(body),
    responsibleUserId: uuidValue(
      requiredText(body, 'responsibleUserId'),
      'RESPONSIBLE_USER_REQUIRED',
    ),
    reason: requiredText(body, 'reason', { maxLength: 1000 }),
  }
}

export function parseVarianceResolutionBody(body: JsonObject) {
  const amount = typeof body.amount === 'number' ? body.amount : Number(body.amount)
  if (!Number.isFinite(amount) || amount <= 0) {
    throw new ApiRouteError('RESOLUTION_AMOUNT_MUST_BE_POSITIVE', 400)
  }
  const evidenceUrl = optionalText(body, 'evidenceUrl', { maxLength: 2048 }) ?? null
  if (evidenceUrl && !/^https:\/\//i.test(evidenceUrl)) {
    throw new ApiRouteError('RESOLUTION_EVIDENCE_MUST_USE_HTTPS', 400)
  }
  const resolutionType = enumValue(
    body.resolutionType,
    RESOLUTION_TYPES,
    'DEPOSIT_VARIANCE_RESOLUTION_TYPE_INVALID',
  )
  const requiresSettlement = ['RECOVERED_FUNDS', 'REFUND_TO_SOURCE']
    .includes(resolutionType)
  const settlementAccountFunction = requiresSettlement
    ? enumValue(
        body.settlementAccountFunction,
        SETTLEMENT_FUNCTIONS,
        'DEPOSIT_VARIANCE_SETTLEMENT_ACCOUNT_INVALID',
      )
    : null
  const resolutionReference = optionalText(
    body,
    'resolutionReference',
    { maxLength: 500 },
  ) ?? null
  if (
    ['SOURCE_CORRECTION', 'REFUND_TO_SOURCE'].includes(resolutionType) &&
    !resolutionReference
  ) {
    throw new ApiRouteError('RESOLUTION_REFERENCE_REQUIRED', 400)
  }
  return {
    masterVersion: requiredVersion(body),
    amount,
    resolutionType,
    settlementAccountFunction,
    reason: requiredText(body, 'reason', { maxLength: 1000 }),
    evidenceUrl,
    resolutionReference,
    idempotencyKey: uuidValue(
      requiredText(body, 'idempotencyKey'),
      'IDEMPOTENCY_KEY_REQUIRED',
    ),
  }
}

export function parseVarianceReviewBody(body: JsonObject) {
  const action = enumValue(
    body.action,
    ['APPROVE', 'REJECT'] as const,
    'RESOLUTION_REVIEW_ACTION_INVALID',
  )
  return {
    masterVersion: requiredVersion(body),
    action,
    reason: action === 'REJECT'
      ? requiredText(body, 'reason', { maxLength: 1000 })
      : null,
    idempotencyKey: uuidValue(
      requiredText(body, 'idempotencyKey'),
      'IDEMPOTENCY_KEY_REQUIRED',
    ),
  }
}

export function throwDepositVarianceRpcError(error: DatabaseError): never {
  const message = error?.message ?? ''
  const known = [
    'DEPOSIT_VARIANCE_EXCEPTION_NOT_FOUND',
    'DEPOSIT_VARIANCE_REQUEST_NOT_FOUND',
    'DEPOSIT_VARIANCE_EXCEPTION_NOT_RESOLVABLE',
    'DEPOSIT_VARIANCE_EXCEPTION_NOT_INVESTIGABLE',
    'DEPOSIT_VARIANCE_FINANCE_ACCESS_DENIED',
    'DEPOSIT_VARIANCE_REVIEW_ACCESS_DENIED',
    'RESPONSIBLE_PARTY_REASON_REQUIRED',
    'RESPONSIBLE_PARTY_ONLY_FOR_UNDER_DEPOSIT',
    'ACTIVE_RESPONSIBLE_USER_NOT_FOUND',
    'RESPONSIBLE_PARTY_REQUIRED',
    'RESOLUTION_AMOUNT_MUST_BE_POSITIVE',
    'DEPOSIT_VARIANCE_ALLOCATION_EXCEEDS_REMAINING',
    'DEPOSIT_VARIANCE_RESOLUTION_TYPE_INVALID',
    'UNDER_DEPOSIT_RESOLUTION_TYPE_INVALID',
    'OVER_DEPOSIT_RESOLUTION_TYPE_INVALID',
    'DEPOSIT_VARIANCE_SETTLEMENT_ACCOUNT_INVALID',
    'RESOLUTION_REFERENCE_REQUIRED',
    'RESOLUTION_EVIDENCE_MUST_USE_HTTPS',
    'DEPOSIT_VARIANCE_IDEMPOTENCY_CONFLICT',
    'DEPOSIT_VARIANCE_REQUEST_NOT_REVIEWABLE',
    'RESOLUTION_REVIEW_ACTION_INVALID',
    'RESOLUTION_REJECTION_REASON_REQUIRED',
    'MAKER_CANNOT_APPROVE_OWN_RESOLUTION',
    'DEPOSIT_VARIANCE_REVIEW_IDEMPOTENCY_CONFLICT',
    'MASTER_VERSION_CONFLICT',
  ]
  const match = known.find((code) => message.includes(code))
  if (match) {
    const forbidden = match.endsWith('_ACCESS_DENIED')
    throw new ApiRouteError(match, forbidden ? 403 : 409)
  }
  throw new ApiRouteError(message || 'DEPOSIT_VARIANCE_OPERATION_FAILED', 400)
}
