import { createClient, type SupabaseClient, type User } from '@supabase/supabase-js'

const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL ?? ''
const supabaseAnonKey =
  process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ??
  process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ??
  ''

export type CallerContext = {
  token: string
  user: User
  client: SupabaseClient
}

export function getBearerToken(request: Request): string | null {
  const header = request.headers.get('authorization')
  if (!header?.startsWith('Bearer ')) return null
  return header.slice(7).trim() || null
}

export async function requireCaller(request: Request): Promise<CallerContext> {
  const token = getBearerToken(request)
  if (!token) throw new Error('AUTHENTICATION_REQUIRED')
  if (!supabaseUrl || !supabaseAnonKey) throw new Error('SUPABASE_NOT_CONFIGURED')

  const client = createClient(supabaseUrl, supabaseAnonKey, {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { autoRefreshToken: false, persistSession: false },
  })
  const { data, error } = await client.auth.getUser(token)
  if (error || !data.user) throw new Error('INVALID_SESSION')

  return { token, user: data.user, client }
}

export function createAdminClient() {
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY
  if (!supabaseUrl || !serviceRoleKey) throw new Error('SUPABASE_ADMIN_NOT_CONFIGURED')
  return createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  })
}

export async function canManageCompany(
  caller: CallerContext,
  companyId: string,
): Promise<boolean> {
  const { data: profile } = await caller.client
    .from('profiles')
    .select('role')
    .eq('id', caller.user.id)
    .maybeSingle()

  if (profile?.role === 'super_admin') return true

  const { data: membership } = await caller.client
    .from('company_memberships')
    .select('role_code')
    .eq('company_id', companyId)
    .eq('user_id', caller.user.id)
    .eq('status', 'ACTIVE')
    .in('role_code', ['COMPANY_OWNER', 'COMPANY_ADMIN'])
    .maybeSingle()

  return Boolean(membership)
}

export function apiError(error: unknown) {
  const message = error instanceof Error ? error.message : 'UNKNOWN_ERROR'
  const status =
    message === 'AUTHENTICATION_REQUIRED' || message === 'INVALID_SESSION'
      ? 401
      : message.endsWith('_REQUIRED') || message === 'FORBIDDEN'
        ? 403
        : 500

  return Response.json({ error: message }, { status })
}
