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

const PAYMENT_METHODS = ['CASH', 'BANK_TRANSFER', 'CHEQUE'] as const

export function parseSaveSupplierPaymentDraft(body: JsonObject) {
  const supplierId = uuidValue(requiredText(body, 'supplierId'), 'SUPPLIER_ID_INVALID')
  const paymentDate = requiredText(body, 'paymentDate', { maxLength: 10 })
  const paymentMethod = enumValue(
    body.paymentMethod,
    PAYMENT_METHODS,
    'PAYMENT_METHOD_INVALID',
  )

  const sourceAccountId = body.sourceAccountId
    ? uuidValue(String(body.sourceAccountId), 'SOURCE_ACCOUNT_ID_INVALID')
    : null

  const supplierBankName = optionalText(body, 'supplierBankName', { maxLength: 100 }) ?? null
  const supplierBankAccountNo = optionalText(body, 'supplierBankAccountNo', { maxLength: 100 }) ?? null
  const supplierBankAccountHolder = optionalText(body, 'supplierBankAccountHolder', { maxLength: 100 }) ?? null
  const referenceNo = optionalText(body, 'referenceNo', { maxLength: 100 }) ?? null
  const notes = optionalText(body, 'notes', { maxLength: 1000 }) ?? null
  const evidenceUrl = optionalText(body, 'evidenceUrl', { maxLength: 2048 }) ?? null

  if (evidenceUrl && !/^https:\/\//i.test(evidenceUrl)) {
    throw new ApiRouteError('SUPPLIER_PAYMENT_EVIDENCE_MUST_USE_HTTPS', 400)
  }

  if (!Array.isArray(body.allocations) || body.allocations.length === 0) {
    throw new ApiRouteError('SUPPLIER_PAYMENT_ALLOCATIONS_REQUIRED', 400)
  }

  const allocations = body.allocations.map((allocObj) => {
    if (typeof allocObj !== 'object' || !allocObj) {
      throw new ApiRouteError('SUPPLIER_PAYMENT_ALLOCATION_INVALID', 400)
    }
    const alloc = allocObj as JsonObject

    const clientAllocationKey = uuidValue(
      String(alloc.clientAllocationKey || ''),
      'CLIENT_ALLOCATION_KEY_REQUIRED',
    )
    const invoiceId = uuidValue(String(alloc.invoiceId || ''), 'INVOICE_ID_REQUIRED')

    const allocatedAmount = Number(alloc.allocatedAmount)
    if (!Number.isFinite(allocatedAmount) || allocatedAmount <= 0) {
      throw new ApiRouteError('SUPPLIER_PAYMENT_ALLOCATION_AMOUNT_INVALID', 400)
    }

    return {
      clientAllocationKey,
      invoiceId,
      allocatedAmount,
    }
  })

  const documentId = body.documentId ? uuidValue(String(body.documentId), 'DOCUMENT_ID_INVALID') : null
  const masterVersion = documentId ? requiredVersion(body) : null

  return {
    documentId,
    masterVersion,
    supplierId,
    paymentDate,
    paymentMethod,
    sourceAccountId,
    supplierBankName,
    supplierBankAccountNo,
    supplierBankAccountHolder,
    referenceNo,
    notes,
    evidenceUrl,
    allocations,
  }
}

export function parseValidateSupplierPayment(body: JsonObject) {
  const documentId = uuidValue(requiredText(body, 'documentId'), 'DOCUMENT_ID_INVALID')
  const masterVersion = requiredVersion(body)
  const idempotencyKey = uuidValue(
    requiredText(body, 'idempotencyKey'),
    'IDEMPOTENCY_KEY_REQUIRED',
  )
  return { documentId, masterVersion, idempotencyKey }
}

export function parseCancelSupplierPayment(body: JsonObject) {
  const documentId = uuidValue(requiredText(body, 'documentId'), 'DOCUMENT_ID_INVALID')
  const masterVersion = requiredVersion(body)
  const reason = requiredText(body, 'reason', { maxLength: 500 })
  return { documentId, masterVersion, reason }
}

export function throwSupplierPaymentRpcError(error: DatabaseError): never {
  const message = error?.message ?? ''
  const known = [
    'AUTHENTICATION_REQUIRED',
    'SUPPLIER_PAYMENT_FINANCE_ACCESS_DENIED',
    'ACTIVE_SUPPLIER_NOT_FOUND',
    'MASTER_VERSION_NOT_ALLOWED_ON_CREATE',
    'MASTER_VERSION_CONFLICT',
    'SUPPLIER_ID_REQUIRED',
    'PAYMENT_DATE_REQUIRED',
    'PAYMENT_METHOD_INVALID',
    'SUPPLIER_PAYMENT_EVIDENCE_MUST_USE_HTTPS',
    'SUPPLIER_PAYMENT_ALLOCATIONS_REQUIRED',
    'SUPPLIER_PAYMENT_NOT_FOUND',
    'FINAL_SUPPLIER_PAYMENT_IMMUTABLE',
    'INVOICE_ID_REQUIRED',
    'CLIENT_ALLOCATION_KEY_REQUIRED',
    'SUPPLIER_PAYMENT_ALLOCATION_AMOUNT_INVALID',
    'SUPPLIER_INVOICE_NOT_FOUND',
    'SUPPLIER_PAYMENT_INVOICE_SUPPLIER_MISMATCH',
    'SUPPLIER_PAYMENT_INVOICE_NOT_VALIDATED',
    'SUPPLIER_PAYMENT_EXCEEDS_INVOICE_BALANCE',
    'SUPPLIER_PAYMENT_TRANSACTION_CATEGORY_NOT_FOUND',
    'SUPPLIER_PAYMENT_ACCOUNT_NOT_FOUND',
    'SUPPLIER_PAYMENT_SOURCE_ACCOUNT_INVALID',
    'SUPPLIER_PAYMENT_ALREADY_VALIDATED',
    'SUPPLIER_PAYMENT_NOT_VALIDATABLE',
    'SUPPLIER_PAYMENT_AMOUNT_MUST_BE_POSITIVE',
    'SUPPLIER_PAYMENT_ALREADY_CANCELED',
    'CANCEL_REASON_REQUIRED',
  ]
  const match = known.find((code) => message.includes(code))
  if (match) {
    const forbidden = match.endsWith('_ACCESS_DENIED')
    throw new ApiRouteError(match, forbidden ? 403 : 409)
  }
  throw new ApiRouteError(message || 'SUPPLIER_PAYMENT_OPERATION_FAILED', 400)
}
