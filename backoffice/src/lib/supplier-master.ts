import { ApiRouteError } from '@/lib/server-auth'
import { optionalBoolean, requiredText, requiredVersion, uuidValue } from '@/lib/master-data'

type JsonObject = Record<string, unknown>
type DatabaseError = { code?: string; message?: string } | null

function nullableText(body: JsonObject, field: string, maxLength: number): string | null {
  const value = body[field]
  if (value === null || value === undefined || value === '') return null
  if (typeof value !== 'string') throw new ApiRouteError(`${field.toUpperCase()}_INVALID`, 400)
  const normalized = value.trim().replace(/\s+/g, ' ')
  if (!normalized) return null
  if (normalized.length > maxLength) {
    throw new ApiRouteError(`${field.toUpperCase()}_TOO_LONG`, 400)
  }
  return normalized
}

function requiredUuid(body: JsonObject, field: string): string {
  const value = body[field]
  if (typeof value !== 'string') throw new ApiRouteError(`${field.toUpperCase()}_REQUIRED`, 400)
  return uuidValue(value, `${field.toUpperCase()}_INVALID`)
}

function nullableMoney(body: JsonObject, field: string): number | null {
  const value = body[field]
  if (value === null || value === undefined || value === '') return null
  const amount = typeof value === 'number' ? value : Number(value)
  if (!Number.isFinite(amount) || amount < 0) {
    throw new ApiRouteError(`${field.toUpperCase()}_INVALID`, 400)
  }
  return amount
}

export type SupplierInput = ReturnType<typeof parseSupplierBody>

export function parseSupplierBody(body: JsonObject, updating: boolean) {
  return {
    masterVersion: updating ? requiredVersion(body) : null,
    supplierName: requiredText(body, 'supplierName', { maxLength: 200 }),
    contactName: nullableText(body, 'contactName', 200),
    phone: nullableText(body, 'phone', 100),
    address: nullableText(body, 'address', 1000),
    npwp: nullableText(body, 'npwp', 100),
    paymentTerm: nullableText(body, 'paymentTerm', 200),
    bankName: nullableText(body, 'bankName', 200),
    bankAccountNumber: nullableText(body, 'bankAccountNumber', 100),
    bankAccountHolder: nullableText(body, 'bankAccountHolder', 200),
    isActive: optionalBoolean(body, 'isActive') ?? true,
  }
}

export function supplierRpcArgs(supplierId: string | null, input: SupplierInput) {
  return {
    p_supplier_id: supplierId,
    p_master_version: input.masterVersion,
    p_supplier_name: input.supplierName,
    p_contact_name: input.contactName,
    p_phone: input.phone,
    p_address: input.address,
    p_npwp: input.npwp,
    p_payment_term: input.paymentTerm,
    p_bank_name: input.bankName,
    p_bank_account_number: input.bankAccountNumber,
    p_bank_account_holder: input.bankAccountHolder,
    p_is_active: input.isActive,
  }
}

export type ProductSupplierInput = ReturnType<typeof parseProductSupplierBody>

export function parseProductSupplierBody(body: JsonObject, updating: boolean) {
  const isActive = optionalBoolean(body, 'isActive') ?? true
  const isPreferredSupplier = optionalBoolean(body, 'isPreferredSupplier') ?? false
  if (isPreferredSupplier && !isActive) {
    throw new ApiRouteError('PREFERRED_SUPPLIER_MUST_BE_ACTIVE', 400)
  }
  return {
    masterVersion: updating ? requiredVersion(body) : null,
    productId: requiredUuid(body, 'productId'),
    supplierId: requiredUuid(body, 'supplierId'),
    purchaseUomId: requiredUuid(body, 'purchaseUomId'),
    supplierProductCode: nullableText(body, 'supplierProductCode', 200),
    referencePurchasePrice: nullableMoney(body, 'referencePurchasePrice'),
    isPreferredSupplier,
    isActive,
  }
}

export function productSupplierRpcArgs(
  productSupplierId: string | null,
  input: ProductSupplierInput,
) {
  return {
    p_product_supplier_id: productSupplierId,
    p_master_version: input.masterVersion,
    p_product_id: input.productId,
    p_supplier_id: input.supplierId,
    p_purchase_uom_id: input.purchaseUomId,
    p_supplier_product_code: input.supplierProductCode,
    p_reference_purchase_price: input.referencePurchasePrice,
    p_is_preferred_supplier: input.isPreferredSupplier,
    p_is_active: input.isActive,
  }
}

export function throwSupplierRpcError(error: DatabaseError): never {
  const message = error?.message ?? ''
  const known = [
    'SUPPLIER_MANAGER_REQUIRED',
    'CUSTOM_PERMISSION_DENIED',
    'INVALID_SUPPLIER_CODE',
    'INVALID_SUPPLIER_NAME',
    'SUPPLIER_NOT_FOUND',
    'PRODUCT_SUPPLIER_NOT_FOUND',
    'MASTER_VERSION_CONFLICT',
    'DUPLICATE_SUPPLIER',
    'ACTIVE_PRODUCT_NOT_FOUND',
    'ACTIVE_SUPPLIER_NOT_FOUND',
    'ACTIVE_PURCHASE_PRODUCT_UOM_NOT_FOUND',
    'REFERENCE_PURCHASE_PRICE_NEGATIVE',
    'PREFERRED_SUPPLIER_MUST_BE_ACTIVE',
    'PREFERRED_SUPPLIER_ALREADY_EXISTS',
    'PRODUCT_SUPPLIER_ALREADY_EXISTS',
  ].find((code) => message.includes(code))
  if (known) {
    const conflictCodes = [
      'MASTER_VERSION_CONFLICT',
      'DUPLICATE_SUPPLIER',
      'PREFERRED_SUPPLIER_ALREADY_EXISTS',
      'PRODUCT_SUPPLIER_ALREADY_EXISTS',
    ]
    const status = ['SUPPLIER_MANAGER_REQUIRED', 'CUSTOM_PERMISSION_DENIED'].includes(known)
      ? 403
      : conflictCodes.includes(known) ? 409 : 400
    throw new ApiRouteError(known, status)
  }
  if (error?.code === '42501') throw new ApiRouteError('FORBIDDEN', 403)
  throw new ApiRouteError(message || 'SUPPLIER_OPERATION_FAILED', 500)
}
