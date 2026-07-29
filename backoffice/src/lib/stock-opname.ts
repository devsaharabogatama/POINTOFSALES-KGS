import { ApiRouteError } from '@/lib/server-auth'
import { requiredVersion, uuidValue } from '@/lib/master-data'

type JsonObject = Record<string, unknown>
type DatabaseError = { message?: string } | null

function requiredUuid(body: JsonObject, field: string) {
  const value = body[field]
  if (typeof value !== 'string') {
    throw new ApiRouteError(`${field.toUpperCase()}_REQUIRED`, 400)
  }
  return uuidValue(value, `${field.toUpperCase()}_INVALID`)
}

export function parseStockOpnameVersionBody(body: JsonObject) {
  return { masterVersion: requiredVersion(body) }
}

export function parseStockOpnameRecountBody(body: JsonObject) {
  return {
    masterVersion: requiredVersion(body),
    detailId: requiredUuid(body, 'detailId'),
  }
}

export function parseStockOpnamePostBody(body: JsonObject) {
  return {
    masterVersion: requiredVersion(body),
    idempotencyKey: requiredUuid(body, 'idempotencyKey'),
  }
}

export function throwStockOpnameRpcError(error: DatabaseError): never {
  const message = error?.message ?? ''
  const known = [
    'STOCK_OPNAME_NOT_FOUND',
    'STOCK_OPNAME_LINE_NOT_FOUND',
    'STOCK_OPNAME_REVIEWER_REQUIRED',
    'STOCK_OPNAME_OWNER_OR_REVIEWER_REQUIRED',
    'STOCK_OPNAME_RECOUNT_NOT_ALLOWED',
    'STOCK_OPNAME_COMPLETED_REQUIRED',
    'STOCK_OPNAME_COUNTED_LINE_REQUIRED',
    'STOCK_OPNAME_UNRESOLVED_LINE',
    'STOCK_OPNAME_FINAL_STOCK_NEGATIVE',
    'STOCK_OPNAME_ADJUSTMENT_REASON_NOT_FOUND',
    'STOCK_OPNAME_IDEMPOTENCY_KEY_REQUIRED',
    'STOCK_OPNAME_IDEMPOTENCY_CONFLICT',
    'FINAL_STOCK_OPNAME_IMMUTABLE',
    'MASTER_VERSION_CONFLICT',
    'STOCK_ADJUSTMENT_STOCK_CHANGED',
    'INSUFFICIENT_STOCK',
    'INSUFFICIENT_FIFO_STOCK',
  ]
  const match = known.find((code) => message.includes(code))
  if (match) throw new ApiRouteError(match, 409)
  throw new ApiRouteError(message || 'STOCK_OPNAME_RPC_FAILED', 400)
}
