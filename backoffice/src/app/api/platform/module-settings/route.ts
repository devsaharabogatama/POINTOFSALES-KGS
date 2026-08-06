import { ApiRouteError, apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject, throwDatabaseError } from '@/lib/master-data'

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
    const [catalog, settings] = await Promise.all([
      caller.client.from('platform_features')
        .select('feature_code,feature_name,module_code,description,is_active')
        .eq('is_active', true).order('module_code').order('feature_name'),
      caller.client.from('company_features')
        .select('feature_code,is_enabled,config,updated_at')
        .eq('company_id', companyId),
    ])
    if (catalog.error) throwDatabaseError(catalog.error)
    if (settings.error) throwDatabaseError(settings.error)
    const byCode = new Map((settings.data ?? []).map((row) => [row.feature_code, row]))
    return Response.json({
      companyId,
      data: (catalog.data ?? []).map((feature) => ({
        ...feature,
        is_enabled: byCode.get(feature.feature_code)?.is_enabled ?? false,
        updated_at: byCode.get(feature.feature_code)?.updated_at ?? null,
      })),
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
