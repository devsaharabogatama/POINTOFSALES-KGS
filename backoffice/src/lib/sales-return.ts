import { ApiRouteError } from '@/lib/server-auth'
import { requiredText, requiredVersion, uuidValue } from '@/lib/master-data'

type JsonObject = Record<string, unknown>
type DatabaseError = { message?: string } | null

export function parseSalesReturnPostBody(body: JsonObject) {
  const value = body.idempotencyKey
  if (typeof value !== 'string') {
    throw new ApiRouteError('IDEMPOTENCY_KEY_REQUIRED', 400)
  }
  return {
    masterVersion: requiredVersion(body),
    idempotencyKey: uuidValue(value, 'IDEMPOTENCY_KEY_INVALID'),
  }
}

export function parseSalesReturnCancelBody(body: JsonObject) {
  return {
    masterVersion: requiredVersion(body),
    reason: requiredText(body, 'reason', { maxLength: 500 }),
  }
}

export function throwSalesReturnRpcError(error: DatabaseError): never {
  const message = error?.message ?? ''
  const known = [
    'SALES_RETURN_NOT_FOUND',
    'SALES_RETURN_ALREADY_POSTED',
    'SALES_RETURN_NOT_POSTABLE',
    'SALES_RETURN_APPROVER_REQUIRED',
    'SALES_RETURN_DRAFT_INCOMPLETE',
    'POSTED_SOURCE_SALE_NOT_FOUND',
    'OPEN_RETURN_SESSION_REQUIRED',
    'RETURN_WAREHOUSE_CHANGED_DURING_POST',
    'REFUND_METHOD_CHANGED_DURING_POST',
    'RETURN_QUANTITY_CHANGED_DURING_POST',
    'SOURCE_SALE_FIFO_RESTORATION_EXHAUSTED',
    'SALES_RETURN_TRANSACTION_CATEGORY_NOT_FOUND',
    'ONLY_DRAFT_RETURN_CANCELABLE',
    'SALES_RETURN_CANCEL_NOT_ALLOWED',
    'CANCEL_REASON_REQUIRED',
    'MASTER_VERSION_CONFLICT',
  ]
  const match = known.find((code) => message.includes(code))
  if (match) {
    const forbidden = match.endsWith('_REQUIRED') || match.endsWith('_NOT_ALLOWED')
    throw new ApiRouteError(match, forbidden ? 403 : 409)
  }
  throw new ApiRouteError(message || 'SALES_RETURN_RPC_FAILED', 400)
}
