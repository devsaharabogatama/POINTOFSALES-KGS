import { ApiRouteError } from '@/lib/server-auth'
import { optionalBoolean, requiredVersion, uuidValue } from '@/lib/master-data'

type JsonObject = Record<string, unknown>
type DatabaseError = { code?: string; message?: string } | null

function requiredUuid(body: JsonObject, field: string) {
  const value = body[field]
  if (typeof value !== 'string') {
    throw new ApiRouteError(`${field.toUpperCase()}_REQUIRED`, 400)
  }
  return uuidValue(value, `${field.toUpperCase()}_INVALID`)
}

function nullableQuantity(body: JsonObject, field: string): string | null {
  const value = body[field]
  if (value === null || value === undefined || value === '') return null
  const normalized = String(value).trim()
  if (!/^\d+(?:\.\d{1,6})?$/.test(normalized)) {
    throw new ApiRouteError('MINIMUM_STOCK_VALUE_INVALID', 400)
  }
  if (Number(normalized) >= 1e18) {
    throw new ApiRouteError('MINIMUM_STOCK_TOO_LARGE', 400)
  }
  return normalized
}

export type MinimumStockInput = ReturnType<typeof parseMinimumStockBody>

export function parseMinimumStockBody(body: JsonObject, updating: boolean) {
  const minimumStockBaseQty = nullableQuantity(body, 'minimumStockBaseQty')
  const lowStockAlertEnabled =
    optionalBoolean(body, 'lowStockAlertEnabled') ?? false
  if (lowStockAlertEnabled && minimumStockBaseQty === null) {
    throw new ApiRouteError('MINIMUM_STOCK_REQUIRED_WHEN_ALERT_ENABLED', 400)
  }
  return {
    masterVersion: updating ? requiredVersion(body) : null,
    productId: requiredUuid(body, 'productId'),
    warehouseId: requiredUuid(body, 'warehouseId'),
    minimumStockBaseQty,
    lowStockAlertEnabled,
  }
}

export function minimumStockRpcArgs(
  settingId: string | null,
  input: MinimumStockInput,
) {
  return {
    p_setting_id: settingId,
    p_master_version: input.masterVersion,
    p_product_id: input.productId,
    p_warehouse_id: input.warehouseId,
    p_minimum_stock_base_qty: input.minimumStockBaseQty,
    p_low_stock_alert_enabled: input.lowStockAlertEnabled,
  }
}

export function throwMinimumStockRpcError(error: DatabaseError): never {
  const message = error?.message ?? ''
  const known = [
    'INVENTORY_CONFIGURATION_MANAGER_REQUIRED',
    'CUSTOM_PERMISSION_DENIED',
    'MINIMUM_STOCK_WAREHOUSE_ACCESS_DENIED',
    'MINIMUM_STOCK_NEGATIVE',
    'MINIMUM_STOCK_TOO_LARGE',
    'MINIMUM_STOCK_REQUIRED_WHEN_ALERT_ENABLED',
    'MINIMUM_STOCK_BASE_UOM_REQUIRES_INTEGER',
    'MINIMUM_STOCK_BASE_UOM_PRECISION_EXCEEDED',
    'ACTIVE_STOCK_PRODUCT_WITH_BASE_UOM_NOT_FOUND',
    'ACTIVE_WAREHOUSE_NOT_FOUND',
    'PRODUCT_WAREHOUSE_STOCK_SETTING_NOT_FOUND',
    'MASTER_VERSION_CONFLICT',
    'PRODUCT_WAREHOUSE_SETTING_IDENTITY_IMMUTABLE',
    'PRODUCT_WAREHOUSE_STOCK_SETTING_ALREADY_EXISTS',
  ].find((code) => message.includes(code))
  if (known) {
    const conflict = [
      'MASTER_VERSION_CONFLICT',
      'PRODUCT_WAREHOUSE_STOCK_SETTING_ALREADY_EXISTS',
    ].includes(known)
    throw new ApiRouteError(
      known,
      [
        'INVENTORY_CONFIGURATION_MANAGER_REQUIRED',
        'CUSTOM_PERMISSION_DENIED',
        'MINIMUM_STOCK_WAREHOUSE_ACCESS_DENIED',
      ].includes(known)
        ? 403
        : conflict
          ? 409
          : 400,
    )
  }
  if (error?.code === '42501') throw new ApiRouteError('FORBIDDEN', 403)
  throw new ApiRouteError(message || 'MINIMUM_STOCK_OPERATION_FAILED', 500)
}
