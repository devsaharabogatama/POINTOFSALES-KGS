import {
  ApiRouteError,
  apiError,
  canManageCompany,
  requireActiveCompany,
  requireCaller,
} from '@/lib/server-auth'

type CompanyAccessBody = {
  action?: string
  targetUserId?: string
  companyId?: string
  roleCode?: string
  storeId?: string
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request)
    const activeCompanyId = await requireActiveCompany(caller)
    const body = (await request.json()) as CompanyAccessBody
    const action = body.action?.trim().toUpperCase()
    const targetUserId = body.targetUserId?.trim()
    const companyId = body.companyId?.trim()
    const roleCode = body.roleCode?.trim().toUpperCase()
    const storeId = body.storeId && body.storeId !== 'NONE' ? body.storeId : null
    if (!targetUserId || !companyId || !action) {
      throw new ApiRouteError('COMPANY_ACCESS_INPUT_INVALID', 400)
    }
    if (!(await canManageCompany(caller, companyId))) {
      throw new ApiRouteError('COMPANY_ACCESS_DENIED', 403)
    }
    const { data: profile, error: profileError } = await caller.client
      .from('profiles').select('role').eq('id', caller.user.id).single()
    if (profileError) throw profileError
    const isSuperAdmin = profile.role === 'super_admin'
    if (!isSuperAdmin && companyId !== activeCompanyId) {
      throw new ApiRouteError('COMPANY_ACCESS_DENIED', 403)
    }

    if (action === 'SAVE') {
      if (!roleCode) throw new ApiRouteError('ROLE_REQUIRED', 400)
      const { data, error } = await caller.client.rpc('save_user_company_access', {
        p_company_id: companyId,
        p_target_user_id: targetUserId,
        p_role_code: roleCode,
        p_store_id: storeId,
      })
      if (error) throw new ApiRouteError(error.message, 400)
      return Response.json({ data })
    }
    if (action === 'DEACTIVATE') {
      const { data, error } = await caller.client.rpc(
        'deactivate_user_company_access',
        { p_company_id: companyId, p_target_user_id: targetUserId },
      )
      if (error) throw new ApiRouteError(error.message, 400)
      return Response.json({ data })
    }
    throw new ApiRouteError('COMPANY_ACCESS_ACTION_INVALID', 400)
  } catch (error) {
    return apiError(error)
  }
}
