import { ApiRouteError } from '@/lib/server-auth'
import { optionalText, requiredVersion, uuidValue } from '@/lib/master-data'

type JsonObject = Record<string, unknown>
type DatabaseError = { code?: string; message?: string } | null

function requiredUuid(body: JsonObject, field: string) {
  const value = body[field]
  if (typeof value !== 'string') {
    throw new ApiRouteError(`${field.toUpperCase()}_REQUIRED`, 400)
  }
  return uuidValue(value, `${field.toUpperCase()}_INVALID`)
}

function adjustmentDate(body: JsonObject) {
  const value = body.adjustmentDate
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    throw new ApiRouteError('STOCK_ADJUSTMENT_DATE_INVALID', 400)
  }
  const parsed = new Date(`${value}T00:00:00Z`)
  if (
    Number.isNaN(parsed.valueOf()) ||
    parsed.toISOString().slice(0, 10) !== value
  ) {
    throw new ApiRouteError('STOCK_ADJUSTMENT_DATE_INVALID', 400)
  }
  return value
}

function decimalValue(
  value: unknown,
  code: string,
  options: { required: boolean; positive?: boolean },
) {
  const normalized = String(value ?? '').trim()
  if (!normalized && !options.required) return null
  if (!/^\d+(?:\.\d{1,6})?$/.test(normalized)) {
    throw new ApiRouteError(code, 400)
  }
  const number = Number(normalized)
  if (
    !Number.isFinite(number) ||
    number >= 1e15 ||
    (options.positive ? number <= 0 : number < 0)
  ) {
    throw new ApiRouteError(code, 400)
  }
  return normalized
}

function parseLines(value: unknown) {
  if (!Array.isArray(value) || value.length === 0) {
    throw new ApiRouteError('STOCK_ADJUSTMENT_LINES_REQUIRED', 400)
  }
  if (value.length > 1000) {
    throw new ApiRouteError('STOCK_ADJUSTMENT_LINE_LIMIT_EXCEEDED', 400)
  }

  const productIds = new Set<string>()
  return value.map((raw, index) => {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
      throw new ApiRouteError(`STOCK_ADJUSTMENT_LINE_${index + 1}_INVALID`, 400)
    }
    const line = raw as JsonObject
    const productId = requiredUuid(line, 'productId')
    if (productIds.has(productId)) {
      throw new ApiRouteError('STOCK_ADJUSTMENT_DUPLICATE_PRODUCT', 400)
    }
    productIds.add(productId)
    const unitCostBase = decimalValue(
      line.unitCostBase,
      'STOCK_ADJUSTMENT_UNIT_COST_INVALID',
      { required: false },
    )
    const costOverrideReason =
      optionalText(line, 'costOverrideReason', { maxLength: 500 }) ?? null
    if (unitCostBase !== null && !costOverrideReason) {
      throw new ApiRouteError(
        'STOCK_ADJUSTMENT_COST_OVERRIDE_REASON_REQUIRED',
        400,
      )
    }
    return {
      productId,
      reasonId: requiredUuid(line, 'reasonId'),
      finalPhysicalQuantity: decimalValue(
        line.finalPhysicalQuantity,
        'STOCK_ADJUSTMENT_FINAL_QUANTITY_INVALID',
        { required: true },
      ),
      unitCostBase,
      costOverrideReason,
      notes: optionalText(line, 'notes', { maxLength: 500 }) ?? null,
    }
  })
}

export type StockAdjustmentInput = ReturnType<typeof parseStockAdjustmentBody>

export function parseStockAdjustmentBody(body: JsonObject, updating: boolean) {
  return {
    masterVersion: updating ? requiredVersion(body) : null,
    warehouseId: requiredUuid(body, 'warehouseId'),
    adjustmentDate: adjustmentDate(body),
    notes: optionalText(body, 'notes', { maxLength: 1000 }) ?? null,
    lines: parseLines(body.lines),
  }
}

export function stockAdjustmentRpcArgs(
  documentId: string | null,
  input: StockAdjustmentInput,
) {
  return {
    p_document_id: documentId,
    p_master_version: input.masterVersion,
    p_warehouse_id: input.warehouseId,
    p_adjustment_date: input.adjustmentDate,
    p_notes: input.notes,
    p_lines: input.lines,
  }
}

export function parseStockAdjustmentPostBody(body: JsonObject) {
  return {
    masterVersion: requiredVersion(body),
    idempotencyKey: requiredUuid(body, 'idempotencyKey'),
  }
}

export function parseStockAdjustmentCancelBody(body: JsonObject) {
  return { masterVersion: requiredVersion(body) }
}

export function throwStockAdjustmentRpcError(error: DatabaseError): never {
  const message = error?.message ?? ''
  const known = [
    'STOCK_ADJUSTMENT_OPERATOR_REQUIRED',
    'STOCK_ADJUSTMENT_WAREHOUSE_REQUIRED',
    'STOCK_ADJUSTMENT_DATE_REQUIRED',
    'STOCK_ADJUSTMENT_FUTURE_DATE_NOT_ALLOWED',
    'STOCK_ADJUSTMENT_LINES_REQUIRED',
    'STOCK_ADJUSTMENT_LINE_LIMIT_EXCEEDED',
    'STOCK_ADJUSTMENT_PRODUCT_REQUIRED',
    'STOCK_ADJUSTMENT_REASON_REQUIRED',
    'STOCK_ADJUSTMENT_FINAL_QUANTITY_MUST_BE_NONNEGATIVE',
    'STOCK_ADJUSTMENT_QUANTITY_TOO_LARGE',
    'STOCK_ADJUSTMENT_BASE_UOM_REQUIRES_INTEGER',
    'STOCK_ADJUSTMENT_BASE_UOM_PRECISION_EXCEEDED',
    'ACTIVE_STOCK_PRODUCT_WITH_BASE_UOM_NOT_FOUND',
    'ACTIVE_STOCK_ADJUSTMENT_REASON_NOT_FOUND',
    'STOCK_ADJUSTMENT_NO_DIFFERENCE',
    'STOCK_ADJUSTMENT_REASON_DIRECTION_MISMATCH',
    'STOCK_ADJUSTMENT_UNIT_COST_INVALID',
    'STOCK_ADJUSTMENT_COST_OVERRIDE_REASON_REQUIRED',
    'STOCK_ADJUSTMENT_NOT_FOUND',
    'FINAL_STOCK_ADJUSTMENT_IMMUTABLE',
    'CANCELED_STOCK_ADJUSTMENT_IMMUTABLE',
    'STOCK_ADJUSTMENT_ALREADY_POSTED',
    'STOCK_ADJUSTMENT_STOCK_CHANGED',
    'ACTIVE_WAREHOUSE_NOT_FOUND',
    'INSUFFICIENT_STOCK',
    'INSUFFICIENT_FIFO_STOCK',
    'STOCK_GAIN_TRANSACTION_CATEGORY_NOT_FOUND',
    'STOCK_LOSS_TRANSACTION_CATEGORY_NOT_FOUND',
    'MASTER_VERSION_CONFLICT',
    'STOCK_ADJUSTMENT_IDEMPOTENCY_CONFLICT',
  ]
  const match = known.find((code) => message.includes(code))
  if (match) throw new ApiRouteError(match, 409)
  throw new ApiRouteError(message || 'STOCK_ADJUSTMENT_RPC_FAILED', 400)
}
