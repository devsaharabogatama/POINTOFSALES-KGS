import { ApiRouteError } from '@/lib/server-auth'
import {
  optionalText,
  requiredVersion,
  uuidValue,
} from '@/lib/master-data'

type JsonObject = Record<string, unknown>
type DatabaseError = { code?: string; message?: string } | null

function requiredUuid(body: JsonObject, field: string) {
  const value = body[field]
  if (typeof value !== 'string') {
    throw new ApiRouteError(`${field.toUpperCase()}_REQUIRED`, 400)
  }
  return uuidValue(value, `${field.toUpperCase()}_INVALID`)
}

function decimalValue(
  value: unknown,
  code: string,
  options: { allowZero: boolean; maximum: number },
): string {
  const normalized = String(value ?? '').trim()
  if (!/^\d+(?:\.\d{1,6})?$/.test(normalized)) {
    throw new ApiRouteError(code, 400)
  }
  const number = Number(normalized)
  if (!Number.isFinite(number)) throw new ApiRouteError(code, 400)
  if (options.allowZero ? number < 0 : number <= 0) {
    throw new ApiRouteError(code, 400)
  }
  if (number >= options.maximum) {
    throw new ApiRouteError(`${code}_TOO_LARGE`, 400)
  }
  return normalized
}

function openingDate(body: JsonObject) {
  const value = body.effectiveDate
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    throw new ApiRouteError('EFFECTIVE_DATE_INVALID', 400)
  }
  const parsed = new Date(`${value}T00:00:00Z`)
  if (Number.isNaN(parsed.valueOf()) || parsed.toISOString().slice(0, 10) !== value) {
    throw new ApiRouteError('EFFECTIVE_DATE_INVALID', 400)
  }
  return value
}

function parseLines(value: unknown) {
  if (!Array.isArray(value) || value.length === 0) {
    throw new ApiRouteError('OPENING_STOCK_LINES_REQUIRED', 400)
  }
  if (value.length > 1000) {
    throw new ApiRouteError('OPENING_STOCK_LINE_LIMIT_EXCEEDED', 400)
  }

  const productIds = new Set<string>()
  return value.map((raw, index) => {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
      throw new ApiRouteError(`OPENING_STOCK_LINE_${index + 1}_INVALID`, 400)
    }
    const line = raw as JsonObject
    const productId = requiredUuid(line, 'productId')
    if (productIds.has(productId)) {
      throw new ApiRouteError('OPENING_STOCK_DUPLICATE_PRODUCT', 400)
    }
    productIds.add(productId)

    const quantityBase = decimalValue(
      line.quantityBase,
      'OPENING_STOCK_QUANTITY_INVALID',
      { allowZero: false, maximum: 1e15 },
    )
    const unitCostBase = decimalValue(
      line.unitCostBase,
      'OPENING_STOCK_UNIT_COST_INVALID',
      { allowZero: true, maximum: 1e18 },
    )
    const zeroCostReason =
      optionalText(line, 'zeroCostReason', { maxLength: 500 }) ?? null
    if (Number(unitCostBase) === 0 && !zeroCostReason) {
      throw new ApiRouteError('OPENING_STOCK_ZERO_COST_REASON_REQUIRED', 400)
    }

    return {
      productId,
      quantityBase,
      unitCostBase,
      zeroCostReason,
      notes: optionalText(line, 'notes', { maxLength: 500 }) ?? null,
    }
  })
}

export type OpeningStockInput = ReturnType<typeof parseOpeningStockBody>

export function parseOpeningStockBody(body: JsonObject, updating: boolean) {
  return {
    masterVersion: updating ? requiredVersion(body) : null,
    warehouseId: requiredUuid(body, 'warehouseId'),
    effectiveDate: openingDate(body),
    notes: optionalText(body, 'notes', { maxLength: 1000 }) ?? null,
    lines: parseLines(body.lines),
  }
}

export function openingStockRpcArgs(
  documentId: string | null,
  input: OpeningStockInput,
) {
  return {
    p_document_id: documentId,
    p_master_version: input.masterVersion,
    p_warehouse_id: input.warehouseId,
    p_effective_date: input.effectiveDate,
    p_notes: input.notes,
    p_lines: input.lines,
  }
}

export function parseOpeningStockPostBody(body: JsonObject) {
  return {
    masterVersion: requiredVersion(body),
    idempotencyKey: requiredUuid(body, 'idempotencyKey'),
  }
}

export function throwOpeningStockRpcError(error: DatabaseError): never {
  const message = error?.message ?? ''
  const known = [
    'OPENING_STOCK_PREPARER_REQUIRED',
    'OPENING_STOCK_POSTER_REQUIRED',
    'ACTIVE_WAREHOUSE_NOT_FOUND',
    'EFFECTIVE_DATE_REQUIRED',
    'OPENING_STOCK_FUTURE_DATE_NOT_ALLOWED',
    'OPENING_STOCK_LINES_REQUIRED',
    'OPENING_STOCK_LINE_LIMIT_EXCEEDED',
    'OPENING_STOCK_PRODUCT_REQUIRED',
    'OPENING_STOCK_QUANTITY_MUST_BE_POSITIVE',
    'OPENING_STOCK_QUANTITY_TOO_LARGE',
    'OPENING_STOCK_UNIT_COST_INVALID',
    'OPENING_STOCK_UNIT_COST_TOO_LARGE',
    'OPENING_STOCK_LINE_TOTAL_TOO_LARGE',
    'OPENING_STOCK_ZERO_COST_REASON_REQUIRED',
    'ACTIVE_STOCK_PRODUCT_WITH_BASE_UOM_NOT_FOUND',
    'OPENING_STOCK_BASE_UOM_REQUIRES_INTEGER',
    'OPENING_STOCK_BASE_UOM_PRECISION_EXCEEDED',
    'OPENING_STOCK_MOVEMENT_ALREADY_EXISTS',
    'OPENING_STOCK_NOT_FOUND',
    'POSTED_OPENING_STOCK_IMMUTABLE',
    'MASTER_VERSION_CONFLICT',
    'IDEMPOTENCY_KEY_REQUIRED',
    'OPENING_STOCK_TRANSACTION_CATEGORY_NOT_FOUND',
    'OPENING_STOCK_ALREADY_POSTED',
    'OPENING_STOCK_IDEMPOTENCY_CONFLICT',
  ].find((code) => message.includes(code))

  if (known) {
    const forbidden = [
      'OPENING_STOCK_PREPARER_REQUIRED',
      'OPENING_STOCK_POSTER_REQUIRED',
    ].includes(known)
    const conflict = [
      'MASTER_VERSION_CONFLICT',
      'OPENING_STOCK_MOVEMENT_ALREADY_EXISTS',
      'OPENING_STOCK_ALREADY_POSTED',
      'OPENING_STOCK_IDEMPOTENCY_CONFLICT',
      'POSTED_OPENING_STOCK_IMMUTABLE',
    ].includes(known)
    throw new ApiRouteError(known, forbidden ? 403 : conflict ? 409 : 400)
  }
  if (message.includes('OPENING_STOCK_ACCOUNT_NOT_RESOLVED')) {
    throw new ApiRouteError('OPENING_STOCK_ACCOUNT_NOT_RESOLVED', 409)
  }
  if (error?.code === '42501') throw new ApiRouteError('FORBIDDEN', 403)
  throw new ApiRouteError(message || 'OPENING_STOCK_OPERATION_FAILED', 500)
}
