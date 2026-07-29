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

function transferDate(body: JsonObject) {
  const value = body.transferDate
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    throw new ApiRouteError('STOCK_TRANSFER_DATE_INVALID', 400)
  }
  const parsed = new Date(`${value}T00:00:00Z`)
  if (
    Number.isNaN(parsed.valueOf()) ||
    parsed.toISOString().slice(0, 10) !== value
  ) {
    throw new ApiRouteError('STOCK_TRANSFER_DATE_INVALID', 400)
  }
  return value
}

function quantityValue(value: unknown) {
  const normalized = String(value ?? '').trim()
  if (!/^\d+(?:\.\d{1,6})?$/.test(normalized)) {
    throw new ApiRouteError('STOCK_TRANSFER_QUANTITY_INVALID', 400)
  }
  const number = Number(normalized)
  if (!Number.isFinite(number) || number <= 0) {
    throw new ApiRouteError('STOCK_TRANSFER_QUANTITY_INVALID', 400)
  }
  if (number >= 1e15) {
    throw new ApiRouteError('STOCK_TRANSFER_QUANTITY_TOO_LARGE', 400)
  }
  return normalized
}

function parseLines(value: unknown) {
  if (!Array.isArray(value) || value.length === 0) {
    throw new ApiRouteError('STOCK_TRANSFER_LINES_REQUIRED', 400)
  }
  if (value.length > 1000) {
    throw new ApiRouteError('STOCK_TRANSFER_LINE_LIMIT_EXCEEDED', 400)
  }

  const productIds = new Set<string>()
  return value.map((raw, index) => {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
      throw new ApiRouteError(`STOCK_TRANSFER_LINE_${index + 1}_INVALID`, 400)
    }
    const line = raw as JsonObject
    const productId = requiredUuid(line, 'productId')
    if (productIds.has(productId)) {
      throw new ApiRouteError('STOCK_TRANSFER_DUPLICATE_PRODUCT', 400)
    }
    productIds.add(productId)
    return {
      productId,
      quantityBase: quantityValue(line.quantityBase),
      notes: optionalText(line, 'notes', { maxLength: 500 }) ?? null,
    }
  })
}

export type StockTransferInput = ReturnType<typeof parseStockTransferBody>

export function parseStockTransferBody(body: JsonObject, updating: boolean) {
  const sourceWarehouseId = requiredUuid(body, 'sourceWarehouseId')
  const destinationWarehouseId = requiredUuid(body, 'destinationWarehouseId')
  if (sourceWarehouseId === destinationWarehouseId) {
    throw new ApiRouteError('STOCK_TRANSFER_WAREHOUSES_MUST_DIFFER', 400)
  }
  return {
    masterVersion: updating ? requiredVersion(body) : null,
    sourceWarehouseId,
    destinationWarehouseId,
    transferDate: transferDate(body),
    notes: optionalText(body, 'notes', { maxLength: 1000 }) ?? null,
    lines: parseLines(body.lines),
  }
}

export function stockTransferRpcArgs(
  documentId: string | null,
  input: StockTransferInput,
) {
  return {
    p_document_id: documentId,
    p_master_version: input.masterVersion,
    p_source_warehouse_id: input.sourceWarehouseId,
    p_destination_warehouse_id: input.destinationWarehouseId,
    p_transfer_date: input.transferDate,
    p_notes: input.notes,
    p_lines: input.lines,
  }
}

export function parseStockTransferPostBody(body: JsonObject) {
  return {
    masterVersion: requiredVersion(body),
    idempotencyKey: requiredUuid(body, 'idempotencyKey'),
  }
}

export function parseStockTransferCancelBody(body: JsonObject) {
  return { masterVersion: requiredVersion(body) }
}

export function throwStockTransferRpcError(error: DatabaseError): never {
  const message = error?.message ?? ''
  const known = [
    'STOCK_TRANSFER_OPERATOR_REQUIRED',
    'STOCK_TRANSFER_WAREHOUSE_REQUIRED',
    'STOCK_TRANSFER_WAREHOUSES_MUST_DIFFER',
    'ACTIVE_TRANSFER_WAREHOUSE_NOT_FOUND',
    'STOCK_TRANSFER_DATE_REQUIRED',
    'STOCK_TRANSFER_DATE_INVALID',
    'STOCK_TRANSFER_FUTURE_DATE_NOT_ALLOWED',
    'STOCK_TRANSFER_LINES_REQUIRED',
    'STOCK_TRANSFER_LINE_LIMIT_EXCEEDED',
    'STOCK_TRANSFER_PRODUCT_REQUIRED',
    'STOCK_TRANSFER_DUPLICATE_PRODUCT',
    'STOCK_TRANSFER_QUANTITY_INVALID',
    'STOCK_TRANSFER_QUANTITY_MUST_BE_POSITIVE',
    'STOCK_TRANSFER_QUANTITY_TOO_LARGE',
    'ACTIVE_STOCK_PRODUCT_WITH_BASE_UOM_NOT_FOUND',
    'STOCK_TRANSFER_BASE_UOM_REQUIRES_INTEGER',
    'STOCK_TRANSFER_BASE_UOM_PRECISION_EXCEEDED',
    'STOCK_TRANSFER_NOT_FOUND',
    'FINAL_STOCK_TRANSFER_IMMUTABLE',
    'CANCELED_STOCK_TRANSFER_IMMUTABLE',
    'MASTER_VERSION_CONFLICT',
    'IDEMPOTENCY_KEY_REQUIRED',
    'STOCK_TRANSFER_TRANSACTION_CATEGORY_NOT_FOUND',
    'STOCK_TRANSFER_ALREADY_POSTED',
    'STOCK_TRANSFER_IDEMPOTENCY_CONFLICT',
    'INSUFFICIENT_STOCK',
    'INSUFFICIENT_FIFO_STOCK',
  ].find((code) => message.includes(code))

  if (known) {
    const forbidden = known === 'STOCK_TRANSFER_OPERATOR_REQUIRED'
    const conflict = [
      'FINAL_STOCK_TRANSFER_IMMUTABLE',
      'CANCELED_STOCK_TRANSFER_IMMUTABLE',
      'MASTER_VERSION_CONFLICT',
      'STOCK_TRANSFER_ALREADY_POSTED',
      'STOCK_TRANSFER_IDEMPOTENCY_CONFLICT',
      'INSUFFICIENT_STOCK',
      'INSUFFICIENT_FIFO_STOCK',
    ].includes(known)
    throw new ApiRouteError(known, forbidden ? 403 : conflict ? 409 : 400)
  }
  if (error?.code === '42501') throw new ApiRouteError('FORBIDDEN', 403)
  throw new ApiRouteError(message || 'STOCK_TRANSFER_OPERATION_FAILED', 500)
}
