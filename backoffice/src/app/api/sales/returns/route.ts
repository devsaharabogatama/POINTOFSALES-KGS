import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { throwDatabaseError } from '@/lib/master-data'

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const url = new URL(request.url)
    const status = url.searchParams.get('status')?.trim().toUpperCase()
    const { data, error } = await caller.client.rpc('get_sales_returns', {
      p_status: status && ['DRAFT', 'POSTED', 'CANCELED'].includes(status)
        ? status : null,
    })
    if (error) throwDatabaseError(error)
    return Response.json(data ?? {})
  } catch (error) {
    return apiError(error)
  }
}
