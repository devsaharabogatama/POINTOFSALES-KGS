import { ApiRouteError, apiError, canManageCompany, requireActiveCompany, requireCaller } from '@/lib/server-auth'

const allowedPresets = new Set(['IKUTI_ROLE', 'LIHAT_SAJA', 'OPERASIONAL', 'TANPA_AKSES'])

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request)
    const activeCompanyId = await requireActiveCompany(caller)
    const body = await request.json() as Record<string, unknown>
    const requestedCompanyId = typeof body.companyId === 'string' ? body.companyId.trim() : ''
    const companyId = requestedCompanyId || activeCompanyId
    const { data: profile, error: profileError } = await caller.client
      .from('profiles').select('role').eq('id', caller.user.id).single()
    if (profileError) throw profileError
    if (profile.role !== 'super_admin' && companyId !== activeCompanyId) {
      throw new ApiRouteError('COMPANY_ACCESS_DENIED', 403)
    }
    if (!(await canManageCompany(caller, companyId))) {
      throw new ApiRouteError('COMPANY_ACCESS_DENIED', 403)
    }
    const targetUserId = typeof body.targetUserId === 'string' ? body.targetUserId.trim() : ''
    const permissionKey = typeof body.permissionKey === 'string' ? body.permissionKey.trim() : ''
    const restrictionPreset = typeof body.restrictionPreset === 'string'
      ? body.restrictionPreset.trim().toUpperCase() : ''
    const expectedVersion = body.expectedVersion == null ? null : Number(body.expectedVersion)
    if (!targetUserId || !/^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$/.test(permissionKey) ||
        !allowedPresets.has(restrictionPreset) ||
        (expectedVersion !== null && (!Number.isInteger(expectedVersion) || expectedVersion < 1))) {
      throw new ApiRouteError('PERMISSION_OVERRIDE_INPUT_INVALID', 400)
    }
    const { data, error } = await caller.client.rpc('save_user_permission_override', {
      p_company_id: companyId,
      p_target_user_id: targetUserId,
      p_permission_key: permissionKey,
      p_restriction_preset: restrictionPreset,
      p_expected_version: expectedVersion,
    })
    if (error) {
      const status = error.message.includes('VERSION_CONFLICT') ? 409 : 400
      throw new ApiRouteError(error.message, status)
    }
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}
