import { apiError, requireCaller } from '@/lib/server-auth'

type MembershipRow = {
  company_id: string
  role_code: string
  is_default_company: boolean
  companies: { id: string; company_code: string; company_name: string; status: string } | null
}

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const { data: profile, error: profileError } = await caller.client
      .from('profiles')
      .select('id, name, email, role')
      .eq('id', caller.user.id)
      .single()

    if (profileError) throw profileError
    const isSuperAdmin = profile.role === 'super_admin'

    if (isSuperAdmin) {
      const { data: companies, error } = await caller.client
        .from('companies')
        .select('id, company_code, company_name, status')
        .eq('status', 'ACTIVE')
        .order('company_name')
      if (error) throw error

      return Response.json({
        profile,
        isSuperAdmin,
        companies: (companies ?? []).map((company) => ({
          ...company,
          roleCode: 'SUPER_ADMIN',
          isDefault: false,
        })),
      })
    }

    const { data, error } = await caller.client
      .from('company_memberships')
      .select('company_id, role_code, is_default_company, companies(id, company_code, company_name, status)')
      .eq('user_id', caller.user.id)
      .eq('status', 'ACTIVE')
    if (error) throw error

    const memberships = (data ?? []) as unknown as MembershipRow[]
    return Response.json({
      profile,
      isSuperAdmin,
      companies: memberships
        .filter((row) => row.companies?.status === 'ACTIVE')
        .map((row) => ({
          ...row.companies,
          roleCode: row.role_code,
          isDefault: row.is_default_company,
        })),
    })
  } catch (error) {
    return apiError(error)
  }
}
