import { apiError, ApiRouteError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import {
  ensurePatchFields,
  enumValue,
  optionalBoolean,
  optionalText,
  readJsonObject,
  requiredText,
  requiredVersion,
  throwDatabaseError,
  WAREHOUSE_TYPES,
  uuidValue,
} from '@/lib/master-data'

const selectFields =
  'id, company_id, code, name, warehouse_type, store_id, location, is_sale_source, is_purchase_destination, allow_negative_stock, is_active, master_version, created_at, updated_at'
type RouteContext = { params: Promise<{ id: string }> }

async function validateStore(
  caller: Awaited<ReturnType<typeof requireCaller>>,
  companyId: string,
  storeId: string,
) {
  const { data, error } = await caller.client
    .from('stores')
    .select('id')
    .eq('company_id', companyId)
    .eq('id', storeId)
    .eq('status', 'ACTIVE')
    .maybeSingle()
  if (error) throwDatabaseError(error)
  if (!data) throw new ApiRouteError('ACTIVE_STORE_NOT_FOUND', 400)
}

export async function PATCH(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const params = await context.params
    const id = uuidValue(params.id || '', 'MASTER_ID_INVALID')
    const body = await readJsonObject(request)
    const masterVersion = requiredVersion(body)
    ensurePatchFields(body, [
      'name',
      'warehouseType',
      'storeId',
      'location',
      'isSaleSource',
      'isPurchaseDestination',
      'isActive',
    ])

    const currentResult = await caller.client
      .from('warehouses')
      .select('warehouse_type, store_id, master_version')
      .eq('company_id', companyId)
      .eq('id', id)
      .maybeSingle()
    if (currentResult.error) throwDatabaseError(currentResult.error)
    if (!currentResult.data) throw new ApiRouteError('MASTER_NOT_FOUND', 404)
    if (currentResult.data.master_version !== masterVersion) {
      throw new ApiRouteError('MASTER_VERSION_CONFLICT', 409)
    }

    const warehouseType =
      'warehouseType' in body
        ? enumValue(body.warehouseType, WAREHOUSE_TYPES, 'WAREHOUSE_TYPE_INVALID')
        : currentResult.data.warehouse_type
    if (!warehouseType) throw new ApiRouteError('WAREHOUSE_TYPE_REQUIRED', 400)
    const rawStoreInput = optionalText(body, 'storeId')
    const storeInput = rawStoreInput ? uuidValue(rawStoreInput, 'STORE_ID_INVALID') : rawStoreInput
    const storeId = storeInput === undefined ? currentResult.data.store_id : storeInput
    if (warehouseType === 'STORE' && !storeId) {
      throw new ApiRouteError('STORE_WAREHOUSE_REQUIRES_STORE', 400)
    }
    if (storeId) await validateStore(caller, companyId, storeId)

    const changes: Record<string, string | boolean | null> = {
      warehouse_type: warehouseType,
      store_id: storeId,
    }
    if ('name' in body) changes.name = requiredText(body, 'name', { maxLength: 150 })
    const location = optionalText(body, 'location', { maxLength: 500 })
    if (location !== undefined) changes.location = location
    const saleSource = optionalBoolean(body, 'isSaleSource')
    if (saleSource !== undefined) changes.is_sale_source = saleSource
    const purchaseDestination = optionalBoolean(body, 'isPurchaseDestination')
    if (purchaseDestination !== undefined) {
      changes.is_purchase_destination = purchaseDestination
    }
    const isActive = optionalBoolean(body, 'isActive')
    if (isActive !== undefined) changes.is_active = isActive

    const { data, error } = await caller.client
      .from('warehouses')
      .update(changes)
      .eq('company_id', companyId)
      .eq('id', id)
      .eq('master_version', masterVersion)
      .select(selectFields)
      .maybeSingle()
    if (error) throwDatabaseError(error)
    if (!data) throw new ApiRouteError('MASTER_VERSION_CONFLICT_OR_NOT_FOUND', 409)
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}
