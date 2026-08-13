import { apiError, createAdminClient, requireCaller } from '@/lib/server-auth'

type AssignExistingStaffBody = {
  email?: string
  target_user_id?: string
  role_code?: string
  company_id?: string
  store_id?: string
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request)
    const { data: callerProfile, error: callerProfileError } = await caller.client
      .from('profiles')
      .select('role')
      .eq('id', caller.user.id)
      .single()
    if (callerProfileError) throw callerProfileError
    if (callerProfile.role !== 'super_admin') {
      return Response.json({ error: 'SUPER_ADMIN_REQUIRED' }, { status: 403 })
    }

    const body = (await request.json()) as AssignExistingStaffBody
    const email = body.email?.trim().toLowerCase()
    const targetUserId = body.target_user_id?.trim()
    const roleCode = body.role_code?.trim().toUpperCase()
    const companyId = body.company_id
    const storeId = body.store_id && body.store_id !== 'NONE' ? body.store_id : null
    if ((!email && !targetUserId) || !roleCode || !companyId) {
      return Response.json({ error: 'INVALID_ASSIGNMENT_PAYLOAD' }, { status: 400 })
    }

    const admin = createAdminClient()
    let targetQuery = admin.from('profiles').select('id').limit(2)
    targetQuery = targetUserId
      ? targetQuery.eq('id', targetUserId)
      : targetQuery.eq('email', email as string)
    const { data: candidates, error: targetError } = await targetQuery
    if (targetError) throw targetError
    if (!candidates || candidates.length !== 1) {
      return Response.json({ error: 'TARGET_USER_NOT_FOUND' }, { status: 404 })
    }

    const { data, error } = await caller.client.rpc(
      'assign_existing_user_to_company',
      {
        p_company_id: companyId,
        p_target_user_id: candidates[0].id,
        p_role_code: roleCode,
        p_store_id: storeId,
      },
    )
    if (error) throw error
    return Response.json({ success: true, result: data })
  } catch (error) {
    return apiError(error)
  }
}
