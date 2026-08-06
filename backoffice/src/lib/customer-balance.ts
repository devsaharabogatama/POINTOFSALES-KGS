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

const DIRECTIONS = ['CREDIT', 'DEBIT'] as const
const SOURCE_FUNCTIONS = ['CASH_DRAWER', 'BANK', 'CUSTOMER_RECEIVABLE'] as const

export function parseCustomerBalanceRequestBody(body: JsonObject) {
  const amount = typeof body.amount === 'number' ? body.amount : Number(body.amount)
  if (!Number.isFinite(amount) || amount <= 0) {
    throw new ApiRouteError('CUSTOMER_BALANCE_AMOUNT_MUST_BE_POSITIVE', 400)
  }
  const direction = enumValue(
    body.direction,
    DIRECTIONS,
    'CUSTOMER_BALANCE_DIRECTION_INVALID',
  )
  const sourceAccountFunction = enumValue(
    body.sourceAccountFunction,
    SOURCE_FUNCTIONS,
    'CUSTOMER_BALANCE_SOURCE_INVALID',
  )
  if (direction === 'DEBIT' && sourceAccountFunction === 'CUSTOMER_RECEIVABLE') {
    // Explicitly allowed for liability/source corrections.
  } else if (!['CASH_DRAWER', 'BANK'].includes(sourceAccountFunction)) {
    throw new ApiRouteError('CUSTOMER_BALANCE_SOURCE_INVALID', 400)
  }
  const evidenceUrl = optionalText(body, 'evidenceUrl', { maxLength: 2048 }) ?? null
  if (evidenceUrl && !/^https:\/\//i.test(evidenceUrl)) {
    throw new ApiRouteError('CUSTOMER_BALANCE_EVIDENCE_HTTPS_REQUIRED', 400)
  }
  return {
    customerId: uuidValue(requiredText(body, 'customerId')),
    storeId: uuidValue(requiredText(body, 'storeId')),
    direction,
    amount,
    sourceAccountFunction,
    reason: requiredText(body, 'reason', { maxLength: 1000 }),
    evidenceUrl,
    idempotencyKey: uuidValue(
      requiredText(body, 'idempotencyKey'),
      'IDEMPOTENCY_KEY_REQUIRED',
    ),
  }
}

export function parseCustomerBalanceReviewBody(body: JsonObject) {
  const action = enumValue(
    body.action,
    ['APPROVE', 'REJECT'] as const,
    'CUSTOMER_BALANCE_REVIEW_ACTION_INVALID',
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

export function throwCustomerBalanceRpcError(error: DatabaseError): never {
  const message = error?.message ?? ''
  const known = [
    'ACTIVE_COMPANY_REQUIRED',
    'ACTIVE_STORE_NOT_FOUND',
    'CUSTOMER_BALANCE_REQUEST_ACCESS_DENIED',
    'CUSTOMER_BALANCE_REVIEW_ACCESS_DENIED',
    'CUSTOMER_BALANCE_STATEMENT_ACCESS_DENIED',
    'CUSTOMER_BALANCE_CUSTOMER_NOT_FOUND',
    'CUSTOMER_BALANCE_CREDIT_DISABLED',
    'CUSTOMER_BALANCE_DEBIT_DISABLED',
    'CUSTOMER_BALANCE_SOURCE_FUNCTION_NOT_FOUND',
    'CUSTOMER_BALANCE_CORRECTION_NOT_FOUND',
    'CUSTOMER_BALANCE_CORRECTION_NOT_REVIEWABLE',
    'CUSTOMER_BALANCE_REVIEW_ACTION_INVALID',
    'CUSTOMER_BALANCE_REJECTION_REASON_REQUIRED',
    'MAKER_CANNOT_REVIEW_OWN_CUSTOMER_BALANCE_CORRECTION',
    'INSUFFICIENT_CUSTOMER_BALANCE',
    'CUSTOMER_BALANCE_TRANSACTION_CATEGORY_NOT_FOUND',
    'CUSTOMER_BALANCE_ACCOUNT_FUNCTION_NOT_CONFIGURED',
    'CUSTOMER_BALANCE_EVIDENCE_HTTPS_REQUIRED',
    'IDEMPOTENCY_PAYLOAD_CONFLICT',
    'MASTER_VERSION_CONFLICT',
  ]
  const match = known.find((code) => message.includes(code))
  if (match) {
    const forbidden = match.endsWith('_ACCESS_DENIED')
    throw new ApiRouteError(match, forbidden ? 403 : 409)
  }
  throw new ApiRouteError(message || 'CUSTOMER_BALANCE_OPERATION_FAILED', 400)
}
