import { apiError, ApiRouteError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import {
  enumValue,
  optionalBoolean,
  optionalText,
  parseIncludeInactive,
  readJsonObject,
  requiredText,
  throwDatabaseError,
  WAREHOUSE_TYPES,
  uuidValue,
} from '@/lib/master-data'

const selectFields =
  'id, company_id, code, name, warehouse_type, store_id, location, is_sale_source, is_purchase_destination, allow_negative_stock, is_active, master_version, created_at, updated_at'

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

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    let query = caller.client
      .from('warehouses')
      .select(selectFields)
      .eq('company_id', companyId)
      .order('name')
      .limit(200)
    if (!parseIncludeInactive(request)) query = query.eq('is_active', true)

    const { data, error } = await query
    if (error) throwDatabaseError(error)
    return Response.json({ companyId, data: data ?? [] })
  } catch (error) {
    return apiError(error)
  }
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const body = await readJsonObject(request)
    const name = requiredText(body, 'name', { maxLength: 150 })
    const warehouseType = enumValue(
      body.warehouseType,
      WAREHOUSE_TYPES,
      'WAREHOUSE_TYPE_INVALID',
    )
    const rawStoreId = optionalText(body, 'storeId')
    const storeId = rawStoreId ? uuidValue(rawStoreId, 'STORE_ID_INVALID') : null
    if (warehouseType === 'STORE' && !storeId) {
      throw new ApiRouteError('STORE_WAREHOUSE_REQUIRES_STORE', 400)
    }
    if (storeId) await validateStore(caller, companyId, storeId)

    const { data, error } = await caller.client.rpc('save_inventory_warehouse', {
      p_warehouse_id: null,
      p_expected_version: null,
      p_name: name,
      p_warehouse_type: warehouseType,
      p_store_id: storeId,
      p_location: optionalText(body, 'location', { maxLength: 500 }) ?? null,
      p_is_sale_source: optionalBoolean(body, 'isSaleSource') ?? false,
      p_is_purchase_destination: optionalBoolean(body, 'isPurchaseDestination') ?? false,
      p_is_active: optionalBoolean(body, 'isActive') ?? true,
    })

    if (error) throwDatabaseError(error)
    return Response.json({ data: data?.data }, { status: 201 })
  } catch (error) {
    return apiError(error)
  }
}
