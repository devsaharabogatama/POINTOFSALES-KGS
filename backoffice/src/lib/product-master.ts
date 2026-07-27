import { ApiRouteError } from '@/lib/server-auth'
import {
  optionalBoolean,
  requiredText,
  requiredVersion,
  uuidValue,
} from '@/lib/master-data'

type JsonObject = Record<string, unknown>
type ProductUomInput = {
  uomId: string
  factorToBase: number
  purchaseAllowed: boolean
  salesAllowed: boolean
  purchasePrice: number | null
  salePrice: number | null
  barcode: string | null
  isActive: boolean
}

function numberValue(
  value: unknown,
  code: string,
  options: { min?: number; max?: number; nullable?: boolean } = {},
): number | null {
  if (value === null && options.nullable) return null
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new ApiRouteError(code, 400)
  }
  if (options.min !== undefined && value < options.min) {
    throw new ApiRouteError(code, 400)
  }
  if (options.max !== undefined && value > options.max) {
    throw new ApiRouteError(code, 400)
  }
  return value
}

function parseUoms(value: unknown): ProductUomInput[] {
  if (!Array.isArray(value) || value.length < 1 || value.length > 20) {
    throw new ApiRouteError('PRODUCT_UOMS_ARRAY_REQUIRED', 400)
  }

  const seen = new Set<string>()
  return value.map((entry) => {
    if (!entry || typeof entry !== 'object' || Array.isArray(entry)) {
      throw new ApiRouteError('INVALID_PRODUCT_UOM_ROW', 400)
    }
    const row = entry as JsonObject
    if (typeof row.uomId !== 'string') {
      throw new ApiRouteError('INVALID_PRODUCT_UOM_ROW', 400)
    }
    const uomId = uuidValue(row.uomId, 'INVALID_PRODUCT_UOM_ID')
    if (seen.has(uomId)) throw new ApiRouteError('DUPLICATE_PRODUCT_UOM', 400)
    seen.add(uomId)

    const factorToBase = numberValue(row.factorToBase, 'PRODUCT_UOM_FACTOR_INVALID', {
      min: 1,
      max: 1_000_000_000,
    }) as number
    const purchaseAllowed = row.purchaseAllowed === true
    const salesAllowed = row.salesAllowed === true
    const purchasePrice = numberValue(row.purchasePrice ?? null, 'PURCHASE_PRICE_INVALID', {
      min: 0,
      nullable: true,
    })
    const salePrice = numberValue(row.salePrice ?? null, 'SALE_PRICE_INVALID', {
      min: 0,
      nullable: true,
    })
    const barcode =
      row.barcode === undefined || row.barcode === null || row.barcode === ''
        ? null
        : requiredText(row, 'barcode', { maxLength: 100 })
    const isActive = row.isActive !== false

    if (purchaseAllowed && purchasePrice === null) {
      throw new ApiRouteError('PURCHASE_PRICE_REQUIRED', 400)
    }
    if (salesAllowed && salePrice === null) {
      throw new ApiRouteError('SALE_PRICE_REQUIRED', 400)
    }
    if (!isActive && (purchaseAllowed || salesAllowed)) {
      throw new ApiRouteError('INACTIVE_PRODUCT_UOM_CANNOT_BE_USED', 400)
    }

    return {
      uomId,
      factorToBase,
      purchaseAllowed,
      salesAllowed,
      purchasePrice,
      salePrice,
      barcode,
      isActive,
    }
  })
}

export function parseProductBody(body: JsonObject, update: boolean) {
  const sku = requiredText(body, 'sku', { uppercase: true, maxLength: 100 })
  const name = requiredText(body, 'name', { maxLength: 200 })
  if (typeof body.categoryId !== 'string') {
    throw new ApiRouteError('CATEGORY_ID_REQUIRED', 400)
  }
  if (typeof body.baseUomId !== 'string') {
    throw new ApiRouteError('BASE_UOM_ID_REQUIRED', 400)
  }
  if (typeof body.weightReferenceUomId !== 'string') {
    throw new ApiRouteError('WEIGHT_REFERENCE_UOM_ID_REQUIRED', 400)
  }

  const categoryId = uuidValue(body.categoryId, 'INVALID_CATEGORY_ID')
  const baseUomId = uuidValue(body.baseUomId, 'INVALID_BASE_UOM_ID')
  const weightReferenceUomId = uuidValue(
    body.weightReferenceUomId,
    'INVALID_WEIGHT_REFERENCE_UOM_ID',
  )
  const weight = numberValue(
    body.weightPerReferenceUomKg,
    'POSITIVE_REFERENCE_WEIGHT_REQUIRED',
    { min: Number.MIN_VALUE, max: 1_000_000 },
  ) as number
  const isBundle = optionalBoolean(body, 'isBundle') ?? false
  if (isBundle) throw new ApiRouteError('BUNDLE_COMPONENTS_REQUIRED_G3', 400)

  let imageUrl: string | null = null
  if (body.imageUrl !== undefined && body.imageUrl !== null) {
    if (typeof body.imageUrl !== 'string') {
      throw new ApiRouteError('PRODUCT_IMAGE_URL_INVALID', 400)
    }
    const normalizedImageUrl = body.imageUrl.trim()
    if (normalizedImageUrl.length > 2_000) {
      throw new ApiRouteError('PRODUCT_IMAGE_URL_INVALID', 400)
    }
    imageUrl = normalizedImageUrl || null
  }

  const hasSalesTax = Object.prototype.hasOwnProperty.call(body, 'salesTaxRuleId')
  const hasPurchaseTax = Object.prototype.hasOwnProperty.call(body, 'purchaseTaxRuleId')
  if (hasSalesTax !== hasPurchaseTax) {
    throw new ApiRouteError('TAX_ASSIGNMENT_FIELDS_REQUIRED_TOGETHER', 400)
  }
  const nullableTaxRule = (value: unknown, code: string) => {
    if (value === null || value === '') return null
    if (typeof value !== 'string') throw new ApiRouteError(code, 400)
    return uuidValue(value, code)
  }

  return {
    masterVersion: update ? requiredVersion(body) : null,
    sku,
    name,
    categoryId,
    baseUomId,
    weightReferenceUomId,
    weightPerReferenceUomKg: weight,
    isBundle: false,
    imageUrl,
    isActive: optionalBoolean(body, 'isActive') ?? true,
    uoms: parseUoms(body.uoms),
    taxAssignmentProvided: hasSalesTax && hasPurchaseTax,
    salesTaxRuleId: hasSalesTax
      ? nullableTaxRule(body.salesTaxRuleId, 'INVALID_SALES_TAX_RULE_ID')
      : null,
    purchaseTaxRuleId: hasPurchaseTax
      ? nullableTaxRule(body.purchaseTaxRuleId, 'INVALID_PURCHASE_TAX_RULE_ID')
      : null,
  }
}

export function productRpcArgs(productId: string | null, value: ReturnType<typeof parseProductBody>) {
  const base = {
    p_product_id: productId,
    p_master_version: value.masterVersion,
    p_sku: value.sku,
    p_name: value.name,
    p_category_id: value.categoryId,
    p_base_uom_id: value.baseUomId,
    p_weight_reference_uom_id: value.weightReferenceUomId,
    p_weight_per_reference_uom_kg: value.weightPerReferenceUomKg,
    p_is_bundle: value.isBundle,
    p_image_url: value.imageUrl,
    p_is_active: value.isActive,
    p_uoms: value.uoms,
  }
  if (!value.taxAssignmentProvided) return base
  return {
    ...base,
    p_sales_tax_rule_id: value.salesTaxRuleId,
    p_purchase_tax_rule_id: value.purchaseTaxRuleId,
  }
}

export function throwProductRpcError(error: { message?: string } | null): never {
  const message = error?.message ?? 'PRODUCT_OPERATION_FAILED'
  const conflicts = ['MASTER_VERSION_CONFLICT', 'DUPLICATE_PRODUCT_OR_BARCODE']
  const forbidden = ['CATALOG_MANAGER_REQUIRED', 'COMPANY_ACCESS_DENIED']
  const validation = [
    'ACTIVE_PRODUCT_CATEGORY_NOT_FOUND',
    'ACTIVE_BASE_UOM_NOT_FOUND',
    'ACTIVE_WEIGHT_REFERENCE_UOM_NOT_FOUND',
    'ACTIVE_PRODUCT_UOM_NOT_FOUND',
    'PRODUCT_UOM_',
    'BASE_UOM_',
    'NON_BASE_UOM_',
    'EXACTLY_ONE_BASE_UOM_REQUIRED',
    'WEIGHT_REFERENCE_MUST_BE_LARGEST_UOM',
    'ACTIVE_SALES_UOM_REQUIRED',
    'ACTIVE_PURCHASE_UOM_REQUIRED',
    'PURCHASE_PRICE_REQUIRED',
    'SALE_PRICE_REQUIRED',
    'POSITIVE_REFERENCE_WEIGHT_REQUIRED',
    'PRODUCT_IMAGE_HTTPS_REQUIRED',
    'BUNDLE_COMPONENTS_REQUIRED_G3',
    'TAX_ASSIGNMENT_FIELDS_REQUIRED_TOGETHER',
    'INVALID_SALES_TAX_RULE_ID',
    'INVALID_PURCHASE_TAX_RULE_ID',
    'TAX_SALES_FEATURE_DISABLED',
    'TAX_PURCHASE_FEATURE_DISABLED',
    'CURRENT_SALES_TAX_RULE_REQUIRED',
    'CURRENT_PURCHASE_TAX_RULE_REQUIRED',
  ]

  const conflict = conflicts.find((code) => message.includes(code))
  if (conflict) throw new ApiRouteError(conflict, 409)
  const denied = forbidden.find((code) => message.includes(code))
  if (denied) throw new ApiRouteError(denied, 403)
  const invalid = validation.find((code) => message.includes(code))
  if (invalid) {
    const exact = message.match(/[A-Z][A-Z0-9_]{3,}/)?.[0] ?? invalid
    throw new ApiRouteError(exact, 400)
  }
  throw new ApiRouteError(message, 500)
}
