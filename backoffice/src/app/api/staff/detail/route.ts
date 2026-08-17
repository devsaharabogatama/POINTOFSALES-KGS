import { ApiRouteError, apiError, canManageCompany, createAdminClient, requireActiveCompany, requireCaller } from '@/lib/server-auth'

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const activeCompanyId = await requireActiveCompany(caller)
    const url = new URL(request.url)
    const userId = url.searchParams.get('userId')?.trim()
    const requestedCompanyId = url.searchParams.get('companyId')?.trim()
    if (!userId) throw new ApiRouteError('TARGET_USER_REQUIRED', 400)
    if (!(await canManageCompany(caller, activeCompanyId))) {
      throw new ApiRouteError('COMPANY_ACCESS_DENIED', 403)
    }

    const { data: callerProfile, error: callerProfileError } = await caller.client
      .from('profiles').select('role').eq('id', caller.user.id).single()
    if (callerProfileError) throw callerProfileError
    const isSuperAdmin = callerProfile.role === 'super_admin'
    const admin = createAdminClient()

    const { data: targetMemberships, error: targetMembershipError } = await admin
      .from('company_memberships')
      .select('company_id,created_at,is_default_company')
      .eq('user_id', userId)
      .eq('status', 'ACTIVE')
      .order('is_default_company', { ascending: false })
      .order('created_at')
    if (targetMembershipError) throw targetMembershipError
    const targetCompanyIds = new Set((targetMemberships ?? []).map((row) => row.company_id))
    let selectedCompanyId: string | null = null
    if (requestedCompanyId) {
      if (!targetCompanyIds.has(requestedCompanyId)) {
        throw new ApiRouteError('TARGET_COMPANY_MEMBERSHIP_NOT_FOUND', 404)
      }
      selectedCompanyId = requestedCompanyId
    } else if (targetCompanyIds.has(activeCompanyId)) {
      selectedCompanyId = activeCompanyId
    } else if (isSuperAdmin) {
      selectedCompanyId = targetMemberships?.[0]?.company_id ?? null
    } else {
      throw new ApiRouteError('TARGET_COMPANY_MEMBERSHIP_NOT_FOUND', 404)
    }
    if (!isSuperAdmin && selectedCompanyId !== activeCompanyId) {
      throw new ApiRouteError('COMPANY_ACCESS_DENIED', 403)
    }

    let permissionProfile: unknown = { items: [] }
    if (selectedCompanyId) {
      const { data, error: permissionError } = await caller.client.rpc(
        'list_user_permission_profile',
        { p_company_id: selectedCompanyId, p_target_user_id: userId },
      )
      if (permissionError) {
        if (permissionError.message.includes('PERMISSION_TARGET_ACCESS_DENIED')) {
          throw new ApiRouteError('PERMISSION_TARGET_ACCESS_DENIED', 403)
        }
        throw permissionError
      }
      permissionProfile = data
    }

    const [profileResult, membershipResult, storeMembershipResult, catalogResult, companyResult, storeResult] = await Promise.all([
      admin.from('profiles').select('id,name,email').eq('id', userId).single(),
      admin.from('company_memberships')
        .select('company_id,role_code,status,is_default_company,companies(id,company_code,company_name,status)')
        .eq('user_id', userId)
        .eq('status', 'ACTIVE')
        .order('created_at'),
      admin.from('store_memberships')
        .select('company_id,store_id,role_code,status,stores!fk_store_memberships_company_store(id,store_code,store_name)')
        .eq('user_id', userId)
        .eq('status', 'ACTIVE'),
      admin.from('access_permission_catalog')
        .select('permission_key,module_key,permission_label,is_customizable,enforcement_status')
        .order('module_key')
        .order('permission_key'),
      admin.from('companies')
        .select('id,company_code,company_name,status')
        .eq('status', 'ACTIVE')
        .order('company_name'),
      admin.from('stores')
        .select('id,company_id,store_code,store_name,status')
        .eq('status', 'ACTIVE')
        .order('store_name'),
    ])
    if (profileResult.error) throw profileResult.error
    if (membershipResult.error) throw membershipResult.error
    if (storeMembershipResult.error) throw storeMembershipResult.error
    if (catalogResult.error) throw catalogResult.error
    if (companyResult.error) throw companyResult.error
    if (storeResult.error) throw storeResult.error

    const memberships = (membershipResult.data ?? []).filter(
      (row) => isSuperAdmin || row.company_id === activeCompanyId,
    )
    const storeMemberships = (storeMembershipResult.data ?? []).filter(
      (row) => isSuperAdmin || row.company_id === activeCompanyId,
    )

    return Response.json({
      profile: profileResult.data,
      memberships,
      storeMemberships,
      permissionProfile,
      permissionCatalog: catalogResult.data ?? [],
      activeCompanyId,
      selectedCompanyId,
      canAssignOtherCompany: isSuperAdmin,
      canAssignOwner: isSuperAdmin,
      assignmentCompanies: (companyResult.data ?? []).filter(
        (company) => isSuperAdmin || company.id === activeCompanyId,
      ),
      assignmentStores: (storeResult.data ?? []).filter(
        (store) => isSuperAdmin || store.company_id === activeCompanyId,
      ),
    })
  } catch (error) {
    return apiError(error)
  }
}
