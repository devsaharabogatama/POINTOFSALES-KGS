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

const PRICE_MODES = ['INCLUSIVE', 'EXCLUSIVE'] as const

export function parseSaveSupplierInvoiceTolerancePolicy(body: JsonObject) {
  const quantityTolerancePercent =
    typeof body.quantityTolerancePercent === 'number'
      ? body.quantityTolerancePercent
      : Number(body.quantityTolerancePercent ?? 0)
  if (
    !Number.isFinite(quantityTolerancePercent) ||
    quantityTolerancePercent < 0 ||
    quantityTolerancePercent > 100
  ) {
    throw new ApiRouteError('QUANTITY_TOLERANCE_PERCENT_INVALID', 400)
  }

  const valueTolerancePercent =
    typeof body.valueTolerancePercent === 'number'
      ? body.valueTolerancePercent
      : Number(body.valueTolerancePercent ?? 0)
  if (
    !Number.isFinite(valueTolerancePercent) ||
    valueTolerancePercent < 0 ||
    valueTolerancePercent > 100
  ) {
    throw new ApiRouteError('VALUE_TOLERANCE_PERCENT_INVALID', 400)
  }

  let quantityToleranceBaseQty: number | null = null
  if (body.quantityToleranceBaseQty !== undefined && body.quantityToleranceBaseQty !== null) {
    const val = Number(body.quantityToleranceBaseQty)
    if (!Number.isFinite(val) || val < 0) {
      throw new ApiRouteError('QUANTITY_TOLERANCE_BASE_QTY_INVALID', 400)
    }
    quantityToleranceBaseQty = val
  }

  let valueToleranceAmount: number | null = null
  if (body.valueToleranceAmount !== undefined && body.valueToleranceAmount !== null) {
    const val = Number(body.valueToleranceAmount)
    if (!Number.isFinite(val) || val < 0) {
      throw new ApiRouteError('VALUE_TOLERANCE_AMOUNT_INVALID', 400)
    }
    valueToleranceAmount = val
  }

  const effectiveFrom = optionalText(body, 'effectiveFrom', { maxLength: 10 }) ?? null
  const isActive = typeof body.isActive === 'boolean' ? body.isActive : true

  return {
    policyId: body.policyId ? uuidValue(String(body.policyId), 'POLICY_ID_INVALID') : null,
    masterVersion: body.policyId ? requiredVersion(body) : null,
    supplierId: body.supplierId ? uuidValue(String(body.supplierId), 'SUPPLIER_ID_INVALID') : null,
    quantityTolerancePercent,
    quantityToleranceBaseQty,
    valueTolerancePercent,
    valueToleranceAmount,
    effectiveFrom,
    isActive,
  }
}

export function parseSaveSupplierInvoiceDraft(body: JsonObject) {
  const supplierId = uuidValue(requiredText(body, 'supplierId'), 'SUPPLIER_ID_INVALID')
  const supplierInvoiceNo = requiredText(body, 'supplierInvoiceNo', { maxLength: 100 })
  const invoiceDate = requiredText(body, 'invoiceDate', { maxLength: 10 })
  const dueDate = optionalText(body, 'dueDate', { maxLength: 10 }) ?? null

  const priceMode = enumValue(
    body.priceMode,
    PRICE_MODES,
    'SUPPLIER_INVOICE_PRICE_MODE_INVALID',
  )

  const notes = optionalText(body, 'notes', { maxLength: 1000 }) ?? null
  const evidenceUrl = optionalText(body, 'evidenceUrl', { maxLength: 2048 }) ?? null

  if (evidenceUrl && !/^https:\/\//i.test(evidenceUrl)) {
    throw new ApiRouteError('SUPPLIER_INVOICE_EVIDENCE_MUST_USE_HTTPS', 400)
  }

  if (!Array.isArray(body.lines) || body.lines.length === 0) {
    throw new ApiRouteError('SUPPLIER_INVOICE_LINES_REQUIRED', 400)
  }

  const lines = body.lines.map((lineObj) => {
    if (typeof lineObj !== 'object' || !lineObj) {
      throw new ApiRouteError('SUPPLIER_INVOICE_LINE_INVALID', 400)
    }
    const line = lineObj as JsonObject

    const clientLineKey = uuidValue(
      String(line.clientLineKey || ''),
      'SUPPLIER_INVOICE_CLIENT_LINE_KEY_REQUIRED',
    )
    const productId = uuidValue(String(line.productId || ''), 'PRODUCT_ID_INVALID')
    const invoiceUomId = uuidValue(String(line.invoiceUomId || ''), 'INVOICE_UOM_ID_INVALID')

    const invoiceQty = Number(line.invoiceQty)
    if (!Number.isFinite(invoiceQty) || invoiceQty <= 0) {
      throw new ApiRouteError('SUPPLIER_INVOICE_LINE_QTY_INVALID', 400)
    }

    const unitPrice = Number(line.unitPrice)
    if (!Number.isFinite(unitPrice) || unitPrice < 0) {
      throw new ApiRouteError('SUPPLIER_INVOICE_LINE_PRICE_INVALID', 400)
    }

    const taxRuleId = line.taxRuleId ? uuidValue(String(line.taxRuleId), 'TAX_RULE_ID_INVALID') : null

    let allocations: Array<{ clientAllocationKey: string; sourceApProvisionalId: string; quantityBase: number }> | null = null
    if (Array.isArray(line.allocations) && line.allocations.length > 0) {
      allocations = line.allocations.map((allocObj) => {
        const alloc = allocObj as JsonObject
        const clientAllocationKey = uuidValue(
          String(alloc.clientAllocationKey || ''),
          'SUPPLIER_INVOICE_CLIENT_ALLOCATION_KEY_REQUIRED',
        )
        const sourceApProvisionalId = uuidValue(
          String(alloc.sourceApProvisionalId || ''),
          'SOURCE_AP_PROVISIONAL_ID_INVALID',
        )
        const quantityBase = Number(alloc.quantityBase)
        if (!Number.isFinite(quantityBase) || quantityBase <= 0) {
          throw new ApiRouteError('SUPPLIER_INVOICE_ALLOCATION_QUANTITY_INVALID', 400)
        }
        return { clientAllocationKey, sourceApProvisionalId, quantityBase }
      })
    }

    return {
      clientLineKey,
      productId,
      invoiceUomId,
      invoiceQty,
      unitPrice,
      taxRuleId,
      allocations,
    }
  })

  const documentId = body.documentId ? uuidValue(String(body.documentId), 'DOCUMENT_ID_INVALID') : null
  const masterVersion = documentId ? requiredVersion(body) : null

  return {
    documentId,
    masterVersion,
    supplierId,
    supplierInvoiceNo,
    invoiceDate,
    dueDate,
    priceMode,
    notes,
    evidenceUrl,
    lines,
  }
}

export function parseValidateSupplierInvoice(body: JsonObject) {
  const documentId = uuidValue(requiredText(body, 'documentId'), 'DOCUMENT_ID_INVALID')
  const masterVersion = requiredVersion(body)
  const idempotencyKey = uuidValue(
    requiredText(body, 'idempotencyKey'),
    'IDEMPOTENCY_KEY_REQUIRED',
  )
  return { documentId, masterVersion, idempotencyKey }
}

export function parseCancelSupplierInvoice(body: JsonObject) {
  const documentId = uuidValue(requiredText(body, 'documentId'), 'DOCUMENT_ID_INVALID')
  const masterVersion = requiredVersion(body)
  const cancelReason = requiredText(body, 'cancelReason', { maxLength: 500 })
  return { documentId, masterVersion, cancelReason }
}

export function throwSupplierInvoiceRpcError(error: DatabaseError): never {
  const message = error?.message ?? ''
  const known = [
    'AUTHENTICATION_REQUIRED',
    'SUPPLIER_INVOICE_FINANCE_ACCESS_DENIED',
    'ACTIVE_SUPPLIER_NOT_FOUND',
    'SUPPLIER_INVOICE_TOLERANCE_INVALID',
    'MASTER_VERSION_NOT_ALLOWED_ON_CREATE',
    'MASTER_VERSION_CONFLICT',
    'SUPPLIER_INVOICE_NUMBER_REQUIRED',
    'INVOICE_DATE_REQUIRED',
    'SUPPLIER_INVOICE_DUE_DATE_INVALID',
    'SUPPLIER_INVOICE_PRICE_MODE_INVALID',
    'SUPPLIER_INVOICE_EVIDENCE_MUST_USE_HTTPS',
    'SUPPLIER_INVOICE_LINES_REQUIRED',
    'SUPPLIER_INVOICE_NOT_FOUND',
    'FINAL_SUPPLIER_INVOICE_IMMUTABLE',
    'SUPPLIER_INVOICE_CLIENT_LINE_KEY_REQUIRED',
    'ACTIVE_SUPPLIER_INVOICE_PRODUCT_UOM_NOT_FOUND',
    'SUPPLIER_INVOICE_LINE_VALUE_INVALID',
    'SUPPLIER_INVOICE_UOM_REQUIRES_INTEGER',
    'SUPPLIER_INVOICE_UOM_PRECISION_EXCEEDED',
    'ACTIVE_PURCHASE_TAX_RULE_NOT_FOUND',
    'SUPPLIER_INVOICE_ALLOCATIONS_ARRAY_REQUIRED',
    'SUPPLIER_INVOICE_CLIENT_ALLOCATION_KEY_REQUIRED',
    'SUPPLIER_INVOICE_ALLOCATION_QUANTITY_INVALID',
    'OPEN_AP_PROVISIONAL_NOT_FOUND',
    'SUPPLIER_INVOICE_ALLOCATION_SUPPLIER_MISMATCH',
    'SUPPLIER_INVOICE_ALLOCATION_PRODUCT_MISMATCH',
    'SUPPLIER_INVOICE_ALLOCATION_EXCEEDS_NET_AVAILABLE',
    'SUPPLIER_INVOICE_LINE_ALLOCATED_QTY_EXCEEDS_INVOICE',
    'SUPPLIER_INVOICE_TOLERANCE_POLICY_NOT_FOUND',
    'IDEMPOTENCY_KEY_REQUIRED',
    'SUPPLIER_INVOICE_VALIDATION_IDEMPOTENCY_CONFLICT',
    'SUPPLIER_INVOICE_NOT_VALIDATABLE',
    'SUPPLIER_INVOICE_VALIDATION_FINANCIAL_EVENT_TYPE_MISSING',
    'CANCEL_REASON_REQUIRED',
    'SUPPLIER_INVOICE_NOT_CANCELABLE',
    'SUPPLIER_INVOICE_CANCELED_ALLOCATION_RELEASE_FAILED',
  ]
  const match = known.find((code) => message.includes(code))
  if (match) {
    const forbidden = match.endsWith('_ACCESS_DENIED')
    throw new ApiRouteError(match, forbidden ? 403 : 409)
  }
  throw new ApiRouteError(message || 'SUPPLIER_INVOICE_OPERATION_FAILED', 400)
}
