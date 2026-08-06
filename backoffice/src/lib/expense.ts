import { ApiRouteError } from '@/lib/server-auth'
import { optionalText, requiredText, requiredVersion, uuidValue } from '@/lib/master-data'

type JsonObject = Record<string, unknown>
type DatabaseError = { message?: string } | null

export function parseExpenseReviewBody(body: JsonObject) {
  if (typeof body.approve !== 'boolean') {
    throw new ApiRouteError('EXPENSE_REVIEW_DECISION_REQUIRED', 400)
  }
  const reason = body.approve
    ? null
    : requiredText(body, 'reason', { maxLength: 500 })
  return {
    masterVersion: requiredVersion(body),
    approve: body.approve,
    reason,
  }
}

export function parseExpenseCancelBody(body: JsonObject) {
  return {
    masterVersion: requiredVersion(body),
    reason: requiredText(body, 'reason', { maxLength: 500 }),
  }
}

export function parseExpenseDisbursementBody(body: JsonObject) {
  const evidenceUrl = optionalText(body, 'evidenceUrl', { maxLength: 2048 }) ?? null
  if (evidenceUrl && !/^https:\/\//i.test(evidenceUrl)) {
    throw new ApiRouteError('EXPENSE_DISBURSEMENT_EVIDENCE_HTTPS_REQUIRED', 400)
  }
  return {
    masterVersion: requiredVersion(body),
    evidenceUrl,
    idempotencyKey: uuidValue(
      requiredText(body, 'idempotencyKey'),
      'EXPENSE_DISBURSEMENT_IDEMPOTENCY_KEY_REQUIRED',
    ),
  }
}

export function parseExpenseSettlementReviewBody(body: JsonObject) {
  const action = requiredText(body, 'action', { maxLength: 16 }).toUpperCase()
  if (!['APPROVE', 'REJECT'].includes(action)) {
    throw new ApiRouteError('EXPENSE_SETTLEMENT_REVIEW_ACTION_INVALID', 400)
  }
  return {
    masterVersion: requiredVersion(body),
    action,
    reason: action === 'REJECT'
      ? requiredText(body, 'reason', { maxLength: 500 })
      : null,
  }
}

export function parseAdditionalExpenseReviewBody(body: JsonObject) {
  const action = requiredText(body, 'action', { maxLength: 16 }).toUpperCase()
  if (!['APPROVE', 'REJECT'].includes(action)) {
    throw new ApiRouteError('EXPENSE_ADDITIONAL_REVIEW_ACTION_INVALID', 400)
  }
  return {
    masterVersion: requiredVersion(body),
    action,
    reason: action === 'REJECT'
      ? requiredText(body, 'reason', { maxLength: 500 })
      : null,
  }
}

export function parseAdditionalExpenseDisbursementBody(body: JsonObject) {
  const evidenceUrl = optionalText(body, 'evidenceUrl', { maxLength: 2048 }) ?? null
  if (evidenceUrl && !/^https:\/\//i.test(evidenceUrl)) {
    throw new ApiRouteError('EXPENSE_ADDITIONAL_EVIDENCE_HTTPS_REQUIRED', 400)
  }
  return {
    requestMasterVersion: requiredVersion({ masterVersion: body.requestMasterVersion }),
    documentMasterVersion: requiredVersion({ masterVersion: body.documentMasterVersion }),
    evidenceUrl,
    idempotencyKey: uuidValue(
      requiredText(body, 'idempotencyKey'),
      'EXPENSE_ADDITIONAL_DISBURSEMENT_IDEMPOTENCY_REQUIRED',
    ),
  }
}

export function parseExpenseReturnBody(body: JsonObject) {
  const amount = typeof body.amount === 'number' ? body.amount : Number(body.amount)
  if (!Number.isFinite(amount) || amount <= 0) {
    throw new ApiRouteError('EXPENSE_RETURN_AMOUNT_INVALID', 400)
  }
  const evidenceUrl = optionalText(body, 'evidenceUrl', { maxLength: 2048 }) ?? null
  if (evidenceUrl && !/^https:\/\//i.test(evidenceUrl)) {
    throw new ApiRouteError('EXPENSE_RETURN_EVIDENCE_HTTPS_REQUIRED', 400)
  }
  return {
    masterVersion: requiredVersion(body),
    amount,
    paymentMethodId: uuidValue(
      requiredText(body, 'paymentMethodId'),
      'EXPENSE_RETURN_PAYMENT_METHOD_REQUIRED',
    ),
    evidenceUrl,
    idempotencyKey: uuidValue(
      requiredText(body, 'idempotencyKey'),
      'EXPENSE_RETURN_IDEMPOTENCY_KEY_REQUIRED',
    ),
  }
}

export function throwExpenseRpcError(error: DatabaseError): never {
  const message = error?.message ?? ''
  const known = [
    'EXPENSE_DOCUMENT_NOT_FOUND',
    'ONLY_SUBMITTED_EXPENSE_REVIEWABLE',
    'EXPENSE_APPROVER_REQUIRED',
    'EXPENSE_REJECTION_REASON_REQUIRED',
    'EXPENSE_CANCEL_NOT_ALLOWED',
    'EXPENSE_CANCELER_REQUIRED',
    'CANCEL_REASON_REQUIRED',
    'MASTER_VERSION_CONFLICT',
    'ONLY_APPROVED_EXPENSE_DISBURSABLE',
    'EXPENSE_INITIAL_DISBURSEMENT_STATE_INVALID',
    'EXPENSE_APPROVAL_SNAPSHOT_INCOMPLETE',
    'ACTIVE_EXPENSE_PAYMENT_METHOD_NOT_FOUND',
    'EXPENSE_PAYMENT_METHOD_SNAPSHOT_CONFLICT',
    'EXPENSE_DISBURSEMENT_EVIDENCE_HTTPS_REQUIRED',
    'EXPENSE_DISBURSEMENT_EVIDENCE_REQUIRED',
    'NONCASH_EXPENSE_SESSION_NOT_ALLOWED',
    'EXPENSE_NONCASH_ROUTE_INVALID',
    'EXPENSE_NONCASH_DISBURSER_REQUIRED',
    'EXPENSE_DISBURSEMENT_CATEGORY_NOT_FOUND',
    'EXPENSE_DISBURSEMENT_ACCOUNT_NOT_RESOLVED',
    'EXPENSE_DISBURSEMENT_IDEMPOTENCY_CONFLICT',
    'EXPENSE_NOT_SETTLEABLE',
    'EXPENSE_SETTLEMENT_REQUEST_NOT_FOUND',
    'ONLY_SUBMITTED_SETTLEMENT_REVIEWABLE',
    'EXPENSE_SETTLEMENT_REVIEW_ACTION_INVALID',
    'EXPENSE_SETTLEMENT_REJECTION_REASON_REQUIRED',
    'EXPENSE_SETTLEMENT_REVIEWER_REQUIRED',
    'EXPENSE_ACTUAL_EXCEEDS_OUTSTANDING',
    'EXPENSE_RETURN_NOT_ALLOWED',
    'EXPENSE_RETURN_AMOUNT_INVALID',
    'EXPENSE_RETURN_EXCEEDS_OUTSTANDING',
    'EXPENSE_RETURN_EVIDENCE_HTTPS_REQUIRED',
    'EXPENSE_RETURN_EVIDENCE_REQUIRED',
    'NONCASH_EXPENSE_RETURN_SESSION_NOT_ALLOWED',
    'EXPENSE_NONCASH_RETURN_ROUTE_INVALID',
    'EXPENSE_NONCASH_RETURN_RECEIVER_REQUIRED',
    'EXPENSE_RETURN_IDEMPOTENCY_CONFLICT',
    'EXPENSE_ADDITIONAL_REQUEST_NOT_FOUND',
    'ONLY_SUBMITTED_ADDITIONAL_REQUEST_REVIEWABLE',
    'EXPENSE_ADDITIONAL_REVIEW_ACTION_INVALID',
    'EXPENSE_ADDITIONAL_REJECTION_REASON_REQUIRED',
    'EXPENSE_ADDITIONAL_REVIEWER_REQUIRED',
    'ONLY_APPROVED_ADDITIONAL_REQUEST_DISBURSABLE',
    'EXPENSE_ADDITIONAL_DOCUMENT_NOT_OPEN',
    'EXPENSE_ADDITIONAL_EVIDENCE_HTTPS_REQUIRED',
    'EXPENSE_ADDITIONAL_EVIDENCE_REQUIRED',
    'EXPENSE_ADDITIONAL_DISBURSEMENT_EVIDENCE_REQUIRED',
    'EXPENSE_ADDITIONAL_CASH_DISBURSEMENT_POS_REQUIRED',
    'EXPENSE_ADDITIONAL_DISBURSEMENT_IDEMPOTENCY_CONFLICT',
    'EXPENSE_ADDITIONAL_CASH_DRAWER_EFFECT_NOT_FOUND',
  ]
  const match = known.find((code) => message.includes(code))
  if (match) {
    const forbidden = match.endsWith('_REQUIRED') &&
      !['EXPENSE_REJECTION_REASON_REQUIRED', 'CANCEL_REASON_REQUIRED'].includes(match)
    throw new ApiRouteError(match, forbidden ? 403 : 409)
  }
  throw new ApiRouteError(message || 'EXPENSE_RPC_FAILED', 400)
}
