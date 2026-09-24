import { ApiRouteError, apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject, throwDatabaseError, uuidValue } from '@/lib/master-data'

async function requireSuperAdmin(
  caller: Awaited<ReturnType<typeof requireCaller>>,
) {
  const { data, error } = await caller.client.from('profiles')
    .select('role').eq('id', caller.user.id).single()
  if (error) throwDatabaseError(error)
  if (data.role !== 'super_admin') throw new ApiRouteError('SUPER_ADMIN_REQUIRED', 403)
}

async function requireSettingsViewer(
  caller: Awaited<ReturnType<typeof requireCaller>>,
  companyId: string,
) {
  const { data: profile, error: profileError } = await caller.client
    .from('profiles').select('role').eq('id', caller.user.id).single()
  if (profileError) throwDatabaseError(profileError)
  if (profile.role === 'super_admin') return

  const { data: membership, error: membershipError } = await caller.client
    .from('company_memberships')
    .select('role_code')
    .eq('company_id', companyId)
    .eq('user_id', caller.user.id)
    .eq('status', 'ACTIVE')
    .in('role_code', ['COMPANY_OWNER', 'COMPANY_ADMIN', 'STORE_MANAGER'])
    .maybeSingle()
  if (membershipError) throwDatabaseError(membershipError)
  if (!membership) throw new ApiRouteError('MODULE_SETTINGS_ACCESS_REQUIRED', 403)
}

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    await requireSettingsViewer(caller, companyId)
    const [catalog, settings, warehouses, purchaseWarehouses, purchaseReplenishment] = await Promise.all([
      caller.client.from('platform_features')
        .select('feature_code,feature_name,module_code,description,is_active')
        .eq('is_active', true).order('module_code').order('feature_name'),
      caller.client.from('company_features')
        .select('feature_code,is_enabled,config,updated_at')
        .eq('company_id', companyId),
      caller.client.from('warehouses')
        .select('id,code,name,store_id')
        .eq('company_id', companyId).eq('is_active', true)
        .eq('is_sale_source', true).order('name'),
      caller.client.from('warehouses')
        .select('id,code,name,store_id')
        .eq('company_id', companyId).eq('is_active', true)
        .eq('is_purchase_destination', true)
        .or('warehouse_type.is.null,warehouse_type.neq.TRANSIT').order('name'),
      caller.client.rpc('get_purchase_replenishment_setting'),
    ])
    if (catalog.error) throwDatabaseError(catalog.error)
    if (settings.error) throwDatabaseError(settings.error)
    if (warehouses.error) throwDatabaseError(warehouses.error)
    if (purchaseWarehouses.error) throwDatabaseError(purchaseWarehouses.error)
    if (purchaseReplenishment.error) throwDatabaseError(purchaseReplenishment.error)
    const byCode = new Map((settings.data ?? []).map((row) => [row.feature_code, row]))
    return Response.json({
      companyId,
      data: (catalog.data ?? []).map((feature) => ({
        ...feature,
        is_enabled: byCode.get(feature.feature_code)?.is_enabled ?? false,
        config: byCode.get(feature.feature_code)?.config ?? {},
        updated_at: byCode.get(feature.feature_code)?.updated_at ?? null,
      })),
      backofficeSalesWarehouses: warehouses.data ?? [],
      purchaseReceiptWarehouses: purchaseWarehouses.data ?? [],
      purchaseReplenishment: purchaseReplenishment.data ?? null,
    })
  } catch (error) {
    return apiError(error)
  }
}

export async function PATCH(request: Request) {
  try {
    const caller = await requireCaller(request)
    await requireSuperAdmin(caller)
    const companyId = await requireActiveCompany(caller)
    const body = await readJsonObject(request)
    if (typeof body.featureCode !== 'string' ||
        !/^[a-z][a-z0-9_]{2,63}$/.test(body.featureCode)) {
      throw new ApiRouteError('INVALID_FEATURE_CODE', 400)
    }
    if (body.featureCode === 'backoffice_delivered_qty_sales_enabled' &&
        'defaultWarehouseId' in body) {
      if (body.defaultWarehouseId !== null && typeof body.defaultWarehouseId !== 'string') {
        throw new ApiRouteError('BACKOFFICE_DEFAULT_WAREHOUSE_INVALID', 400)
      }
      const warehouseId = body.defaultWarehouseId === null
        ? null
        : uuidValue(body.defaultWarehouseId, 'BACKOFFICE_DEFAULT_WAREHOUSE_INVALID')
      const { data, error } = await caller.client.rpc(
        'set_backoffice_sales_default_warehouse',
        { p_warehouse_id: warehouseId },
      )
      if (error) {
        const known = ['SUPER_ADMIN_REQUIRED','BACKOFFICE_SALES_FEATURE_NOT_FOUND',
          'BACKOFFICE_DEFAULT_WAREHOUSE_INVALID'].find((code) => error.message.includes(code))
        if (known) throw new ApiRouteError(known, known === 'SUPER_ADMIN_REQUIRED' ? 403 : 400)
        throwDatabaseError(error)
      }
      return Response.json({ data })
    }
    if (body.featureCode === 'purchase_replenishment_mode') {
      if (typeof body.mode !== 'string' ||
          !['MANUAL', 'AUTO_RO', 'AUTO_PO'].includes(body.mode)) {
        throw new ApiRouteError('PURCHASE_REPLENISHMENT_MODE_INVALID', 400)
      }
      if (!Number.isSafeInteger(body.masterVersion) || Number(body.masterVersion) <= 0) {
        throw new ApiRouteError('MASTER_VERSION_INVALID', 400)
      }
      const { data, error } = await caller.client.rpc('set_purchase_replenishment_mode', {
        p_mode: body.mode,
        p_master_version: Number(body.masterVersion),
      })
      if (error) {
        const known = ['SUPER_ADMIN_REQUIRED', 'PURCHASE_REPLENISHMENT_MODE_INVALID',
          'PURCHASE_REPLENISHMENT_SETTING_NOT_FOUND', 'MASTER_VERSION_CONFLICT']
          .find((code) => error.message.includes(code))
        if (known) throw new ApiRouteError(known,
          known === 'SUPER_ADMIN_REQUIRED' ? 403 : known === 'MASTER_VERSION_CONFLICT' ? 409 : 400)
        throwDatabaseError(error)
      }
      return Response.json({ data })
    }
    if (body.featureCode === 'purchase_replenishment_default_warehouse') {
      if (body.warehouseId !== null && typeof body.warehouseId !== 'string') {
        throw new ApiRouteError('PURCHASE_RECEIPT_WAREHOUSE_INVALID', 400)
      }
      if (!Number.isSafeInteger(body.masterVersion) || Number(body.masterVersion) <= 0) {
        throw new ApiRouteError('MASTER_VERSION_INVALID', 400)
      }
      const warehouseId = body.warehouseId === null
        ? null
        : uuidValue(body.warehouseId, 'PURCHASE_RECEIPT_WAREHOUSE_INVALID')
      const { data, error } = await caller.client.rpc(
        'set_purchase_replenishment_default_warehouse',
        { p_warehouse_id: warehouseId, p_master_version: Number(body.masterVersion) },
      )
      if (error) {
        const known = ['SUPER_ADMIN_REQUIRED', 'PURCHASE_RECEIPT_WAREHOUSE_INVALID',
          'PURCHASE_REPLENISHMENT_SETTING_NOT_FOUND', 'MASTER_VERSION_CONFLICT']
          .find((code) => error.message.includes(code))
        if (known) throw new ApiRouteError(known,
          known === 'SUPER_ADMIN_REQUIRED' ? 403 : known === 'MASTER_VERSION_CONFLICT' ? 409 : 400)
        throwDatabaseError(error)
      }
      return Response.json({ data })
    }
    if (body.featureCode === 'pos_session_close_stock_request') {
      if (typeof body.enabled !== 'boolean') {
        throw new ApiRouteError('SESSION_CLOSE_STOCK_REQUEST_POLICY_INVALID', 400)
      }
      if (!Number.isSafeInteger(body.masterVersion) || Number(body.masterVersion) <= 0) {
        throw new ApiRouteError('MASTER_VERSION_INVALID', 400)
      }
      const { data, error } = await caller.client.rpc(
        'set_session_close_stock_request_policy',
        { p_enabled: body.enabled, p_master_version: Number(body.masterVersion) },
      )
      if (error) {
        const known = ['SUPER_ADMIN_REQUIRED', 'SESSION_CLOSE_STOCK_REQUEST_POLICY_INVALID',
          'PURCHASE_REPLENISHMENT_SETTING_NOT_FOUND', 'MASTER_VERSION_CONFLICT']
          .find((code) => error.message.includes(code))
        if (known) throw new ApiRouteError(known,
          known === 'SUPER_ADMIN_REQUIRED' ? 403 : known === 'MASTER_VERSION_CONFLICT' ? 409 : 400)
        throwDatabaseError(error)
      }
      return Response.json({ data })
    }
    if (typeof body.enabled !== 'boolean') {
      throw new ApiRouteError('FEATURE_ENABLED_MUST_BE_BOOLEAN', 400)
    }
    const { data: existing, error: existingError } = await caller.client
      .from('company_features').select('config')
      .eq('company_id', companyId).eq('feature_code', body.featureCode)
      .maybeSingle()
    if (existingError) throwDatabaseError(existingError)
    const { data, error } = await caller.client.rpc('set_company_feature', {
      p_company_id: companyId,
      p_feature_code: body.featureCode,
      p_enabled: body.enabled,
      p_config: existing?.config ?? {},
    })
    if (error) {
      const known = ['SUPER_ADMIN_REQUIRED', 'COMPANY_NOT_FOUND',
        'ACTIVE_FEATURE_NOT_FOUND', 'FEATURE_CONFIG_MUST_BE_OBJECT']
        .find((code) => error.message.includes(code))
      if (known) throw new ApiRouteError(known, known === 'SUPER_ADMIN_REQUIRED' ? 403 : 400)
      throwDatabaseError(error)
    }
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}
