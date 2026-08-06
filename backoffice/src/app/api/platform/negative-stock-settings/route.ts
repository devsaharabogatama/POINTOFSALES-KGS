import { ApiRouteError, apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject, throwDatabaseError } from '@/lib/master-data'

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
const VIEW_ROLES = ['COMPANY_OWNER', 'COMPANY_ADMIN', 'STORE_MANAGER']

async function requireSettingsRole(
  caller: Awaited<ReturnType<typeof requireCaller>>,
  companyId: string,
) {
  const { data: profile, error: profileError } = await caller.client
    .from('profiles').select('role').eq('id', caller.user.id).single()
  if (profileError) throwDatabaseError(profileError)
  if (profile.role === 'super_admin') {
    return { roleCode: 'SUPER_ADMIN', canManage: true }
  }
  const { data: membership, error } = await caller.client
    .from('company_memberships')
    .select('role_code')
    .eq('company_id', companyId)
    .eq('user_id', caller.user.id)
    .eq('status', 'ACTIVE')
    .in('role_code', VIEW_ROLES)
    .maybeSingle()
  if (error) throwDatabaseError(error)
  if (!membership) throw new ApiRouteError('NEGATIVE_STOCK_SETTINGS_ACCESS_REQUIRED', 403)
  return {
    roleCode: membership.role_code,
    canManage: ['COMPANY_OWNER', 'COMPANY_ADMIN'].includes(membership.role_code),
  }
}

function requireUuid(value: unknown, code: string) {
  if (typeof value !== 'string' || !UUID_PATTERN.test(value)) {
    throw new ApiRouteError(code, 400)
  }
  return value
}

function optionalPositiveNumber(value: unknown, code: string) {
  if (value === null || value === undefined || value === '') return null
  const number = Number(value)
  if (!Number.isFinite(number) || number <= 0) throw new ApiRouteError(code, 400)
  return number
}

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const access = await requireSettingsRole(caller, companyId)
    const [feature, policy, warehouses, permissions, companyMembers, storeMembers] =
      await Promise.all([
        caller.client.from('company_features')
          .select('is_enabled')
          .eq('company_id', companyId)
          .eq('feature_code', 'pos_negative_stock_enabled')
          .maybeSingle(),
        caller.client.from('pos_negative_stock_policies')
          .select('id,is_active,require_reason,company_negative_limit_base_qty,master_version,updated_at')
          .eq('company_id', companyId)
          .single(),
        caller.client.from('warehouses')
          .select('id,name,store_id,allow_negative_stock,is_active,is_sale_source')
          .eq('company_id', companyId)
          .eq('is_active', true)
          .eq('is_sale_source', true)
          .order('name'),
        caller.client.from('pos_negative_stock_permissions')
          .select('id,warehouse_id,user_id,is_active,max_negative_base_qty,valid_until,grant_reason,master_version,updated_at')
          .eq('company_id', companyId)
          .order('updated_at', { ascending: false }),
        caller.client.from('company_memberships')
          .select('user_id')
          .eq('company_id', companyId)
          .eq('status', 'ACTIVE'),
        caller.client.from('store_memberships')
          .select('user_id')
          .eq('company_id', companyId)
          .eq('status', 'ACTIVE'),
      ])
    for (const result of [feature, policy, warehouses, permissions, companyMembers, storeMembers]) {
      if (result.error) throwDatabaseError(result.error)
    }
    const userIds = [...new Set([
      ...(companyMembers.data ?? []).map((item) => item.user_id),
      ...(storeMembers.data ?? []).map((item) => item.user_id),
    ])]
    const profiles = userIds.length
      ? await caller.client.from('profiles').select('id,name,email').in('id', userIds).order('name')
      : { data: [], error: null }
    if (profiles.error) throwDatabaseError(profiles.error)

    return Response.json({
      data: {
        featureEnabled: feature.data?.is_enabled ?? false,
        roleCode: access.roleCode,
        canManage: access.canManage,
        policy: policy.data,
        warehouses: warehouses.data ?? [],
        permissions: permissions.data ?? [],
        users: profiles.data ?? [],
      },
    })
  } catch (error) {
    return apiError(error)
  }
}

export async function PATCH(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const access = await requireSettingsRole(caller, companyId)
    if (!access.canManage) {
      throw new ApiRouteError('NEGATIVE_STOCK_SETTINGS_MANAGER_REQUIRED', 403)
    }
    const body = await readJsonObject(request)
    const action = typeof body.action === 'string' ? body.action : ''
    let rpcName = ''
    let rpcArgs: Record<string, unknown> = {}

    if (action === 'SAVE_POLICY') {
      const masterVersion = Number(body.masterVersion)
      if (!Number.isInteger(masterVersion) || masterVersion < 1) {
        throw new ApiRouteError('MASTER_VERSION_REQUIRED', 400)
      }
      if (typeof body.active !== 'boolean' || typeof body.requireReason !== 'boolean') {
        throw new ApiRouteError('NEGATIVE_STOCK_POLICY_SHAPE_INVALID', 400)
      }
      rpcName = 'save_pos_negative_stock_policy'
      rpcArgs = {
        p_expected_master_version: masterVersion,
        p_is_active: body.active,
        p_require_reason: body.requireReason,
        p_company_negative_limit_base_qty: optionalPositiveNumber(
          body.companyLimit,
          'NEGATIVE_STOCK_COMPANY_LIMIT_INVALID',
        ),
      }
    } else if (action === 'SET_WAREHOUSE') {
      if (typeof body.allow !== 'boolean') {
        throw new ApiRouteError('NEGATIVE_STOCK_WAREHOUSE_SHAPE_INVALID', 400)
      }
      rpcName = 'set_warehouse_negative_stock_opt_in'
      rpcArgs = {
        p_warehouse_id: requireUuid(body.warehouseId, 'WAREHOUSE_ID_INVALID'),
        p_allow: body.allow,
      }
    } else if (action === 'SAVE_PERMISSION') {
      const permissionId = body.permissionId === null || body.permissionId === undefined
        ? null
        : requireUuid(body.permissionId, 'NEGATIVE_STOCK_PERMISSION_ID_INVALID')
      const masterVersion = permissionId === null ? null : Number(body.masterVersion)
      if (permissionId !== null && (!Number.isInteger(masterVersion) || Number(masterVersion) < 1)) {
        throw new ApiRouteError('MASTER_VERSION_REQUIRED', 400)
      }
      const grantReason = typeof body.grantReason === 'string' ? body.grantReason.trim() : ''
      if (!grantReason) throw new ApiRouteError('NEGATIVE_STOCK_GRANT_REASON_REQUIRED', 400)
      if (typeof body.active !== 'boolean') {
        throw new ApiRouteError('NEGATIVE_STOCK_PERMISSION_SHAPE_INVALID', 400)
      }
      let validUntil: string | null = null
      if (body.validUntil !== null && body.validUntil !== undefined && body.validUntil !== '') {
        const date = new Date(String(body.validUntil))
        if (Number.isNaN(date.getTime())) throw new ApiRouteError('NEGATIVE_STOCK_VALID_UNTIL_INVALID', 400)
        validUntil = date.toISOString()
      }
      rpcName = 'save_pos_negative_stock_permission'
      rpcArgs = {
        p_permission_id: permissionId,
        p_expected_master_version: masterVersion,
        p_warehouse_id: requireUuid(body.warehouseId, 'WAREHOUSE_ID_INVALID'),
        p_user_id: requireUuid(body.userId, 'USER_ID_INVALID'),
        p_max_negative_base_qty: optionalPositiveNumber(
          body.userLimit,
          'NEGATIVE_STOCK_USER_LIMIT_INVALID',
        ),
        p_valid_until: validUntil,
        p_grant_reason: grantReason,
        p_is_active: body.active,
      }
    } else {
      throw new ApiRouteError('NEGATIVE_STOCK_SETTINGS_ACTION_INVALID', 400)
    }

    const { data, error } = await caller.client.rpc(rpcName, rpcArgs)
    if (error) {
      const known = [
        'NEGATIVE_STOCK_POLICY_FORBIDDEN',
        'NEGATIVE_STOCK_WAREHOUSE_FORBIDDEN',
        'NEGATIVE_STOCK_PERMISSION_FORBIDDEN',
        'NEGATIVE_STOCK_POLICY_NOT_FOUND',
        'NEGATIVE_STOCK_PERMISSION_NOT_FOUND',
        'NEGATIVE_STOCK_GRANT_REASON_REQUIRED',
        'ACTIVE_SALE_SOURCE_WAREHOUSE_REQUIRED',
        'ACTIVE_COMPANY_USER_REQUIRED',
        'MASTER_VERSION_CONFLICT',
      ].find((code) => error.message.includes(code))
      if (known) throw new ApiRouteError(known, known.endsWith('_FORBIDDEN') ? 403 : 400)
      throwDatabaseError(error)
    }
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}
