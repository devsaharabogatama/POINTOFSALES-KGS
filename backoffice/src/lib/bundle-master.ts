import { ApiRouteError } from '@/lib/server-auth'
import {
  optionalBoolean,
  requiredText,
  requiredVersion,
  uuidValue,
} from '@/lib/master-data'

type JsonObject = Record<string, unknown>

function finiteNumber(value: unknown, code: string, min: number, max: number) {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < min || value > max) {
    throw new ApiRouteError(code, 400)
  }
  return value
}

function optionalTextValue(value: unknown, code: string, maxLength: number) {
  if (value === undefined || value === null || value === '') return null
  if (typeof value !== 'string') throw new ApiRouteError(code, 400)
  const normalized = value.trim()
  if (!normalized) return null
  if (normalized.length > maxLength) throw new ApiRouteError(code, 400)
  return normalized
}

function parseComponents(value: unknown) {
  if (!Array.isArray(value) || value.length < 1 || value.length > 100) {
    throw new ApiRouteError('BUNDLE_COMPONENTS_REQUIRED', 400)
  }

  const seen = new Set<string>()
  return value.map((entry) => {
    if (!entry || typeof entry !== 'object' || Array.isArray(entry)) {
      throw new ApiRouteError('INVALID_BUNDLE_COMPONENT', 400)
    }
    const row = entry as JsonObject
    if (typeof row.productId !== 'string' || typeof row.uomId !== 'string') {
      throw new ApiRouteError('INVALID_BUNDLE_COMPONENT', 400)
    }
    const productId = uuidValue(row.productId, 'INVALID_COMPONENT_PRODUCT_ID')
    const uomId = uuidValue(row.uomId, 'INVALID_COMPONENT_UOM_ID')
    const key = `${productId}:${uomId}`
    if (seen.has(key)) throw new ApiRouteError('DUPLICATE_BUNDLE_COMPONENT', 400)
    seen.add(key)

    return {
      productId,
      uomId,
      quantity: finiteNumber(
        row.quantity,
        'INVALID_BUNDLE_COMPONENT_QUANTITY',
        Number.MIN_VALUE,
        1_000_000_000,
      ),
    }
  })
}

export function parseBundleBody(body: JsonObject, updating: boolean) {
  if (typeof body.categoryId !== 'string') {
    throw new ApiRouteError('CATEGORY_ID_REQUIRED', 400)
  }
  if (typeof body.salesUomId !== 'string') {
    throw new ApiRouteError('SALES_UOM_ID_REQUIRED', 400)
  }

  const imageUrl = optionalTextValue(body.imageUrl, 'PRODUCT_IMAGE_URL_INVALID', 2_000)
  if (imageUrl && !/^https:\/\//i.test(imageUrl)) {
    throw new ApiRouteError('PRODUCT_IMAGE_HTTPS_REQUIRED', 400)
  }

  return {
    masterVersion: updating ? requiredVersion(body) : null,
    sku: requiredText(body, 'sku', { uppercase: true, maxLength: 100 }),
    name: requiredText(body, 'name', { maxLength: 200 }),
    categoryId: uuidValue(body.categoryId, 'INVALID_CATEGORY_ID'),
    salesUomId: uuidValue(body.salesUomId, 'INVALID_SALES_UOM_ID'),
    salePrice: finiteNumber(body.salePrice, 'SALE_PRICE_INVALID', 0, 1_000_000_000_000),
    barcode: optionalTextValue(body.barcode, 'BARCODE_INVALID', 100),
    imageUrl,
    isActive: optionalBoolean(body, 'isActive') ?? true,
    components: parseComponents(body.components),
  }
}

export function bundleRpcArgs(
  bundleId: string | null,
  input: ReturnType<typeof parseBundleBody>,
) {
  return {
    p_bundle_id: bundleId,
    p_master_version: input.masterVersion,
    p_sku: input.sku,
    p_name: input.name,
    p_category_id: input.categoryId,
    p_sales_uom_id: input.salesUomId,
    p_sale_price: input.salePrice,
    p_barcode: input.barcode,
    p_image_url: input.imageUrl,
    p_is_active: input.isActive,
    p_components: input.components,
  }
}

export function throwBundleRpcError(error: { message?: string } | null): never {
  const message = error?.message ?? 'BUNDLE_OPERATION_FAILED'
  const conflicts = ['MASTER_VERSION_CONFLICT', 'DUPLICATE_BUNDLE_OR_BARCODE']
  const forbidden = ['CATALOG_MANAGER_REQUIRED', 'COMPANY_ACCESS_DENIED']
  const validation = [
    'ACTIVE_PRODUCT_CATEGORY_NOT_FOUND',
    'ACTIVE_BUNDLE_SALES_UOM_NOT_FOUND',
    'ACTIVE_STOCK_COMPONENT_UOM_NOT_FOUND',
    'BUNDLE_COMPONENTS_REQUIRED',
    'BUNDLE_COMPONENTS_ARRAY_REQUIRED',
    'BUNDLE_COMPONENT_',
    'DUPLICATE_BUNDLE_COMPONENT',
    'NESTED_BUNDLE_NOT_ALLOWED',
    'BUNDLE_SELF_COMPONENT_NOT_ALLOWED',
    'BUNDLE_PURCHASE_UOM_NOT_ALLOWED',
    'BUNDLE_PHYSICAL_STOCK_NOT_ALLOWED',
    'BUNDLE_SALE_PRICE_INVALID',
    'BUNDLE_BARCODE_INVALID',
    'COMPONENT_WEIGHT_CONTRACT_INVALID',
    'BUNDLE_PRODUCT_NOT_FOUND',
    'PRODUCT_TYPE_IMMUTABLE',
    'PRODUCT_IMAGE_HTTPS_REQUIRED',
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
