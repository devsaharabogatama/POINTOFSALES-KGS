import {
  apiError,
  canManageCompany,
  createAdminClient,
  requireCaller,
} from '@/lib/server-auth'

const ALLOWED_ROLES = new Set([
  'COMPANY_ADMIN',
  'STORE_MANAGER',
  'WAREHOUSE_ADMIN',
  'FINANCE',
  'ACCOUNTING',
  'CASHIER',
])

type CreateStaffBody = {
  email?: string
  password?: string
  name?: string
  role_code?: string
  company_id?: string
  store_id?: string
}

export async function POST(request: Request) {
  let createdUserId: string | null = null
  try {
    const caller = await requireCaller(request)
    const body = (await request.json()) as CreateStaffBody
    const email = body.email?.trim().toLowerCase()
    const password = body.password
    const name = body.name?.trim()
    const roleCode = body.role_code?.trim().toUpperCase()
    const companyId = body.company_id
    const storeId = body.store_id

    if (!email || !password || !name || !roleCode || !companyId) {
      return Response.json({ error: 'INVALID_STAFF_PAYLOAD' }, { status: 400 })
    }
    if (password.length < 8) {
      return Response.json({ error: 'PASSWORD_MINIMUM_8_CHARACTERS' }, { status: 400 })
    }
    if (!ALLOWED_ROLES.has(roleCode)) {
      return Response.json({ error: 'ROLE_NOT_ALLOWED' }, { status: 400 })
    }
    if (roleCode === 'CASHIER' && (!storeId || storeId === 'NONE')) {
      return Response.json(
        { error: 'CASHIER_STORE_ASSIGNMENT_REQUIRED' },
        { status: 400 },
      )
    }
    if (!(await canManageCompany(caller, companyId))) {
      return Response.json({ error: 'FORBIDDEN' }, { status: 403 })
    }

    const admin = createAdminClient()
    if (storeId && storeId !== 'NONE') {
      const { data: store, error: storeError } = await admin
        .from('stores')
        .select('id')
        .eq('id', storeId)
        .eq('company_id', companyId)
        .maybeSingle()
      if (storeError || !store) {
        return Response.json({ error: 'STORE_NOT_IN_COMPANY' }, { status: 400 })
      }
    }

    const { data: authUser, error: authError } = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: { name },
    })
    if (authError) return Response.json({ error: authError.message }, { status: 400 })
    createdUserId = authUser.user.id

    const { error: profileError } = await admin.from('profiles').upsert({
      id: createdUserId,
      email,
      name,
      role: 'cashier',
    })
    if (profileError) throw profileError

    const { error: membershipError } = await admin.from('company_memberships').insert({
      company_id: companyId,
      user_id: createdUserId,
      role_code: roleCode,
      status: 'ACTIVE',
    })
    if (membershipError) throw membershipError

    if (storeId && storeId !== 'NONE') {
      const { error: storeMembershipError } = await admin.from('store_memberships').insert({
        company_id: companyId,
        store_id: storeId,
        user_id: createdUserId,
        role_code: roleCode,
        status: 'ACTIVE',
      })
      if (storeMembershipError) throw storeMembershipError
    }

    return Response.json({ success: true, userId: createdUserId }, { status: 201 })
  } catch (error) {
    if (createdUserId) {
      try {
        await createAdminClient().auth.admin.deleteUser(createdUserId)
      } catch {
        // Preserve the original provisioning error. Orphan cleanup can be retried manually.
      }
    }
    return apiError(error)
  }
}
