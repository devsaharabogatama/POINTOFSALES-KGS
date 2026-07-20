import { apiError, createAdminClient, requireCaller } from '@/lib/server-auth'

type RegisterTenantBody = {
  email?: string
  password?: string
  name?: string
  company_code?: string
  company_name?: string
}

export async function POST(request: Request) {
  let createdUserId: string | null = null
  let createdCompanyId: string | null = null

  try {
    const caller = await requireCaller(request)
    const { data: callerProfile } = await caller.client
      .from('profiles')
      .select('role')
      .eq('id', caller.user.id)
      .single()
    if (callerProfile?.role !== 'super_admin') {
      return Response.json({ error: 'SUPER_ADMIN_REQUIRED' }, { status: 403 })
    }

    const body = (await request.json()) as RegisterTenantBody
    const email = body.email?.trim().toLowerCase()
    const password = body.password
    const name = body.name?.trim()
    const companyCode = body.company_code?.trim().toUpperCase()
    const companyName = body.company_name?.trim()

    if (!email || !password || !name || !companyCode || !companyName) {
      return Response.json({ error: 'INVALID_TENANT_PAYLOAD' }, { status: 400 })
    }
    if (password.length < 8) {
      return Response.json({ error: 'PASSWORD_MINIMUM_8_CHARACTERS' }, { status: 400 })
    }

    const admin = createAdminClient()
    const { data: authUser, error: authError } = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: { name },
    })
    if (authError) return Response.json({ error: authError.message }, { status: 400 })
    createdUserId = authUser.user.id
    createdCompanyId = crypto.randomUUID()
    const storeId = crypto.randomUUID()

    const slug = companyCode.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '')
    const { error: companyError } = await admin.from('companies').insert({
      id: createdCompanyId,
      company_code: companyCode,
      company_name: companyName,
      company_slug: slug,
      status: 'ACTIVE',
    })
    if (companyError) throw companyError

    const { error: profileError } = await admin
      .from('profiles')
      .upsert({ id: createdUserId, email, name, role: 'cashier' })
    if (profileError) throw profileError

    const { error: storeError } = await admin.from('stores').insert({
        id: storeId,
        company_id: createdCompanyId,
        store_code: 'STORE-MAIN',
        store_name: 'Toko Utama',
        status: 'ACTIVE',
      })
    if (storeError) throw storeError

    const { error: warehouseError } = await admin.from('warehouses').insert([
        { company_id: createdCompanyId, code: 'GDS', name: 'Gudang Utama', is_active: true },
        { company_id: createdCompanyId, code: 'KGS', name: 'Gudang Toko', is_active: true },
      ])
    if (warehouseError) throw warehouseError

    const { error: companyMembershipError } = await admin.from('company_memberships').insert({
        company_id: createdCompanyId,
        user_id: createdUserId,
        role_code: 'COMPANY_OWNER',
        status: 'ACTIVE',
        is_default_company: true,
      })
    if (companyMembershipError) throw companyMembershipError

    const { error: storeMembershipError } = await admin.from('store_memberships').insert({
        company_id: createdCompanyId,
        store_id: storeId,
        user_id: createdUserId,
        role_code: 'COMPANY_OWNER',
        status: 'ACTIVE',
      })
    if (storeMembershipError) throw storeMembershipError

    return Response.json(
      { success: true, companyId: createdCompanyId, ownerUserId: createdUserId },
      { status: 201 },
    )
  } catch (error) {
    const admin = createAdminClient()
    if (createdCompanyId) await admin.from('companies').delete().eq('id', createdCompanyId)
    if (createdUserId) await admin.auth.admin.deleteUser(createdUserId)
    return apiError(error)
  }
}
