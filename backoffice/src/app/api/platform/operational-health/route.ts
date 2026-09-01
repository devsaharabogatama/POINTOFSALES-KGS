import { ApiRouteError, apiError, requireCaller } from '@/lib/server-auth'

export const dynamic = 'force-dynamic'

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const { data: profile, error: profileError } = await caller.client
      .from('profiles').select('role').eq('id', caller.user.id).single()
    if (profileError) throw profileError
    if (profile.role !== 'super_admin') {
      throw new ApiRouteError('SUPER_ADMIN_REQUIRED', 403)
    }

    const { data, error } = await caller.client.rpc(
      'get_platform_operational_health',
    )
    if (error) {
      if (error.message.includes('SUPER_ADMIN_REQUIRED')) {
        throw new ApiRouteError('SUPER_ADMIN_REQUIRED', 403)
      }
      if (error.message.includes('statement timeout')) {
        throw new ApiRouteError('PLATFORM_HEALTH_QUERY_TIMEOUT', 503)
      }
      throw error
    }
    return Response.json({ data }, {
      headers: { 'Cache-Control': 'no-store, max-age=0' },
    })
  } catch (error) {
    return apiError(error)
  }
}
