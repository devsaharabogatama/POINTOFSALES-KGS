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
      .select('name, warehouse_type, store_id, location, is_sale_source, is_purchase_destination, is_active, master_version')
      .eq('company_id', companyId)
      .eq('id', id)
      .maybeSingle()
    if (currentResult.error) throwDatabaseError(currentResult.error)
    if (!currentResult.data) throw new ApiRouteError('MASTER_NOT_FOUND', 404)

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

    const name = 'name' in body
      ? requiredText(body, 'name', { maxLength: 150 })
      : currentResult.data.name
    const location = optionalText(body, 'location', { maxLength: 500 })
    const saleSource = optionalBoolean(body, 'isSaleSource')
    const purchaseDestination = optionalBoolean(body, 'isPurchaseDestination')
    const isActive = optionalBoolean(body, 'isActive')

    const { data, error } = await caller.client.rpc('save_inventory_warehouse', {
      p_warehouse_id: id,
      p_expected_version: masterVersion,
      p_name: name,
      p_warehouse_type: warehouseType,
      p_store_id: storeId,
      p_location: location === undefined ? currentResult.data.location : location,
      p_is_sale_source: saleSource ?? currentResult.data.is_sale_source,
      p_is_purchase_destination: purchaseDestination ?? currentResult.data.is_purchase_destination,
      p_is_active: isActive ?? currentResult.data.is_active,
    })
    if (error) throwDatabaseError(error)
    return Response.json({ data: data?.data })
  } catch (error) {
    return apiError(error)
  }
}
