import { ApiRouteError, apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject, throwDatabaseError } from '@/lib/master-data'

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
const SETTINGS_ROLES = ['COMPANY_OWNER', 'COMPANY_ADMIN', 'STORE_MANAGER']

async function requireSettingsRole(
  caller: Awaited<ReturnType<typeof requireCaller>>,
  companyId: string,
) {
  const { data: profile, error: profileError } = await caller.client
    .from('profiles').select('role').eq('id', caller.user.id).single()
  if (profileError) throwDatabaseError(profileError)
  if (profile.role === 'super_admin') {
    return { roleCode: 'SUPER_ADMIN', isCompanyManager: true }
  }

  const { data: membership, error: membershipError } = await caller.client
    .from('company_memberships')
    .select('role_code')
    .eq('company_id', companyId)
    .eq('user_id', caller.user.id)
    .eq('status', 'ACTIVE')
    .in('role_code', SETTINGS_ROLES)
    .maybeSingle()
  if (membershipError) throwDatabaseError(membershipError)
  if (!membership) throw new ApiRouteError('OFFLINE_SETTINGS_ACCESS_REQUIRED', 403)
  return {
    roleCode: membership.role_code,
    isCompanyManager: ['COMPANY_OWNER', 'COMPANY_ADMIN'].includes(
      membership.role_code,
    ),
  }
}

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const access = await requireSettingsRole(caller, companyId)
    const [feature, policies, stores, terminals] = await Promise.all([
      caller.client.from('company_features')
        .select('is_enabled,updated_at')
        .eq('company_id', companyId)
        .eq('feature_code', 'offline_pos_enabled')
        .maybeSingle(),
      caller.client.from('pos_offline_allowance_policies')
        .select(
          'id,scope_type,store_id,terminal_id,allocation_percent,is_enabled,master_version,updated_at',
        )
        .eq('company_id', companyId)
        .order('scope_type'),
      caller.client.from('stores')
        .select('id,store_name')
        .eq('company_id', companyId)
        .eq('status', 'ACTIVE')
        .order('store_name'),
      caller.client.from('pos_terminals')
        .select('id,store_id,pos_name')
        .eq('company_id', companyId)
        .eq('status', 'ACTIVE')
        .order('pos_name'),
    ])
    if (feature.error) throwDatabaseError(feature.error)
    if (policies.error) throwDatabaseError(policies.error)
    if (stores.error) throwDatabaseError(stores.error)
    if (terminals.error) throwDatabaseError(terminals.error)

    return Response.json({
      data: {
        featureEnabled: feature.data?.is_enabled ?? false,
        roleCode: access.roleCode,
        canManageCompanyPolicy: access.isCompanyManager,
        policies: policies.data ?? [],
        stores: stores.data ?? [],
        terminals: terminals.data ?? [],
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
    const body = await readJsonObject(request)
    const scopeType =
      typeof body.scopeType === 'string' ? body.scopeType.toUpperCase() : ''
    if (!['COMPANY', 'STORE', 'TERMINAL'].includes(scopeType)) {
      throw new ApiRouteError('OFFLINE_POLICY_SCOPE_INVALID', 400)
    }
    if (scopeType === 'COMPANY' && !access.isCompanyManager) {
      throw new ApiRouteError('OFFLINE_COMPANY_POLICY_MANAGER_REQUIRED', 403)
    }

    const policyId =
      body.policyId === null || body.policyId === undefined ? null : body.policyId
    const storeId =
      body.storeId === null || body.storeId === undefined ? null : body.storeId
    const terminalId =
      body.terminalId === null || body.terminalId === undefined
        ? null
        : body.terminalId
    if (policyId !== null &&
        (typeof policyId !== 'string' || !UUID_PATTERN.test(policyId))) {
      throw new ApiRouteError('OFFLINE_POLICY_ID_INVALID', 400)
    }
    if (scopeType !== 'COMPANY' &&
        (typeof storeId !== 'string' || !UUID_PATTERN.test(storeId))) {
      throw new ApiRouteError('OFFLINE_POLICY_STORE_REQUIRED', 400)
    }
    if (scopeType === 'TERMINAL' &&
        (typeof terminalId !== 'string' || !UUID_PATTERN.test(terminalId))) {
      throw new ApiRouteError('OFFLINE_POLICY_TERMINAL_REQUIRED', 400)
    }
    if (typeof body.enabled !== 'boolean') {
      throw new ApiRouteError('OFFLINE_POLICY_ENABLED_MUST_BE_BOOLEAN', 400)
    }

    const percent = Number(body.allocationPercent)
    if (scopeType !== 'TERMINAL' &&
        (!Number.isFinite(percent) || percent <= 0 || percent > 100)) {
      throw new ApiRouteError('OFFLINE_POLICY_PERCENT_INVALID', 400)
    }
    const masterVersion =
      policyId === null ? null : Number(body.masterVersion)
    if (policyId !== null &&
        (!Number.isInteger(masterVersion) || masterVersion === null ||
          masterVersion < 1)) {
      throw new ApiRouteError('MASTER_VERSION_REQUIRED', 400)
    }

    const { data, error } = await caller.client.rpc(
      'save_pos_offline_allowance_policy',
      {
        p_policy_id: policyId,
        p_master_version: masterVersion,
        p_scope_type: scopeType,
        p_store_id: scopeType === 'COMPANY' ? null : storeId,
        p_terminal_id: scopeType === 'TERMINAL' ? terminalId : null,
        p_allocation_percent:
          scopeType === 'TERMINAL' ? null : percent / 100,
        p_is_enabled: body.enabled,
      },
    )
    if (error) {
      const known = [
        'OFFLINE_COMPANY_POLICY_MANAGER_REQUIRED',
        'OFFLINE_STORE_POLICY_MANAGER_REQUIRED',
        'OFFLINE_POLICY_SCOPE_INVALID',
        'OFFLINE_POLICY_STORE_REQUIRED',
        'OFFLINE_TERMINAL_POLICY_SHAPE_INVALID',
        'ACTIVE_STORE_NOT_FOUND',
        'ACTIVE_POS_TERMINAL_NOT_FOUND',
        'OFFLINE_POLICY_PERCENT_INVALID',
        'OFFLINE_POLICY_NOT_FOUND',
        'MASTER_VERSION_CONFLICT',
        'OFFLINE_POLICY_IDENTITY_IMMUTABLE',
        'OFFLINE_POLICY_SCOPE_ALREADY_EXISTS',
      ].find((code) => error.message.includes(code))
      if (known) {
        const forbidden = known.endsWith('_MANAGER_REQUIRED')
        throw new ApiRouteError(known, forbidden ? 403 : 400)
      }
      throwDatabaseError(error)
    }
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}
