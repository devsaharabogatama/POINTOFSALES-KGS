import { ApiRouteError } from '@/lib/server-auth'

type JsonObject = Record<string, unknown>

function finiteNonNegative(value: unknown, code: string) {
  const number = Number(value)
  if (!Number.isFinite(number) || number < 0) throw new ApiRouteError(code, 400)
  return number
}

function finitePositive(value: unknown, code: string) {
  const number = finiteNonNegative(value, code)
  if (number <= 0) throw new ApiRouteError(code, 400)
  return number
}

function uuid(value: unknown, code: string) {
  const text = String(value ?? '').trim()
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(text)) {
    throw new ApiRouteError(code, 400)
  }
  return text
}

function optionalUuid(value: unknown, code: string) {
  return value == null || String(value).trim() === '' ? null : uuid(value, code)
}

export function parseReceiptDispositionLines(value: unknown) {
  if (!Array.isArray(value) || value.length === 0 || value.length > 500) {
    throw new ApiRouteError('BACKOFFICE_RECEIPT_DISPOSITION_LINES_INVALID', 400)
  }
  return value.map((raw) => {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
      throw new ApiRouteError('BACKOFFICE_RECEIPT_DISPOSITION_LINES_INVALID', 400)
    }
    const line = raw as JsonObject
    const discrepancies = line.discrepancies
    if (!Array.isArray(discrepancies) || discrepancies.length > 20) {
      throw new ApiRouteError('BACKOFFICE_RECEIPT_DISCREPANCY_LINES_INVALID', 400)
    }
    return {
      deliveryLineId: uuid(line.deliveryLineId, 'BACKOFFICE_RECEIPT_DISPOSITION_LINE_ID_INVALID'),
      acceptedBaseQty: finiteNonNegative(line.acceptedBaseQty, 'BACKOFFICE_RECEIPT_ACCEPTED_QUANTITY_INVALID'),
      discrepancies: discrepancies.map((rawItem) => {
        if (!rawItem || typeof rawItem !== 'object' || Array.isArray(rawItem)) {
          throw new ApiRouteError('BACKOFFICE_RECEIPT_DISCREPANCY_LINES_INVALID', 400)
        }
        const item = rawItem as JsonObject
        const discrepancyType = String(item.discrepancyType ?? '').trim().toUpperCase()
        const requestedResolution = String(item.requestedResolution ?? '').trim().toUpperCase()
        const physicalState = item.physicalState == null ? null
          : String(item.physicalState).trim().toUpperCase() || null
        const result: JsonObject = {
          discrepancyType,
          requestedResolution,
          quantityBase: finitePositive(item.quantityBase, 'BACKOFFICE_DISCREPANCY_QUANTITY_INVALID'),
          ...(physicalState ? { physicalState } : {}),
        }
        if (discrepancyType === 'WRONG_ITEM') {
          result.actualProductId = uuid(item.actualProductId, 'BACKOFFICE_DISCREPANCY_ACTUAL_PRODUCT_INVALID')
          result.actualUomId = uuid(item.actualUomId, 'BACKOFFICE_DISCREPANCY_ACTUAL_UOM_INVALID')
          result.actualQuantityUom = finitePositive(item.actualQuantityUom, 'BACKOFFICE_DISCREPANCY_ACTUAL_QUANTITY_INVALID')
          result.actualQuantityBase = finitePositive(item.actualQuantityBase, 'BACKOFFICE_DISCREPANCY_ACTUAL_QUANTITY_INVALID')
        }
        return result
      }),
    }
  })
}

export function parseOverageApprovalLines(value: unknown) {
  if (!Array.isArray(value) || value.length === 0 || value.length > 500) {
    throw new ApiRouteError('OVERAGE_APPROVAL_PAYLOAD_INVALID', 400)
  }
  return value.map((raw) => {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
      throw new ApiRouteError('OVERAGE_APPROVAL_PAYLOAD_INVALID', 400)
    }
    const line = raw as JsonObject
    return {
      discrepancyLineId: uuid(line.discrepancyLineId, 'OVERAGE_APPROVAL_LINE_ID_INVALID'),
      unitPrice: finiteNonNegative(line.unitPrice, 'OVERAGE_COMMERCIAL_INPUT_INVALID'),
      discountAmount: finiteNonNegative(line.discountAmount, 'OVERAGE_COMMERCIAL_INPUT_INVALID'),
      taxApplied: Boolean(line.taxApplied),
      taxRuleId: Boolean(line.taxApplied)
        ? optionalUuid(line.taxRuleId, 'OVERAGE_TAX_RULE_INVALID') : null,
    }
  })
}

const knownCodes = [
  'AUTHENTICATION_REQUIRED', 'ACTIVE_COMPANY_REQUIRED', 'CUSTOM_PERMISSION_DENIED',
  'SALES_ROLE_REQUIRED', 'BACKOFFICE_DISCREPANCY_NOT_FOUND',
  'BACKOFFICE_DISCREPANCY_SALES_APPROVAL_NOT_PENDING', 'MASTER_VERSION_CONFLICT',
  'IDEMPOTENCY_PAYLOAD_CONFLICT', 'OVERAGE_APPROVAL_PAYLOAD_INVALID',
  'OVERAGE_APPROVAL_LINE_SET_INVALID', 'OVERAGE_COMMERCIAL_INPUT_INVALID',
  'OVERAGE_TAX_RULE_REQUIRED', 'OVERAGE_TAX_INPUT_CONFLICT',
  'BACKOFFICE_DISCREPANCY_FILTER_INVALID', 'BACKOFFICE_DELIVERY_NOT_FOUND',
  'BACKOFFICE_SHORTAGE_RESOLUTION_NOT_PENDING', 'BACKOFFICE_SHORTAGE_LINE_CONTRACT_INVALID',
  'BACKOFFICE_OVERAGE_WRONG_ITEM_RESOLUTION_NOT_PENDING',
  'BACKOFFICE_OVERAGE_WRONG_ITEM_LINE_CONTRACT_INVALID',
  'BACKOFFICE_DISCREPANCY_TRANSIT_FIFO_INSUFFICIENT',
  'BACKOFFICE_DISCREPANCY_RECONSTRUCTION_STOCK_INSUFFICIENT',
  'BACKOFFICE_DISCREPANCY_OPERATION_CHANGED',
]

export function throwDiscrepancyDatabaseError(error: { message?: string | null }): never {
  const message = error.message ?? 'BACKOFFICE_DISCREPANCY_OPERATION_FAILED'
  const code = knownCodes.find((candidate) => message.includes(candidate))
    ?? 'BACKOFFICE_DISCREPANCY_OPERATION_FAILED'
  const status = code.endsWith('_NOT_FOUND') ? 404
    : code === 'CUSTOM_PERMISSION_DENIED' || code === 'SALES_ROLE_REQUIRED' ? 403
      : code === 'MASTER_VERSION_CONFLICT' || code === 'IDEMPOTENCY_PAYLOAD_CONFLICT' ? 409 : 400
  throw new ApiRouteError(code, status)
}
