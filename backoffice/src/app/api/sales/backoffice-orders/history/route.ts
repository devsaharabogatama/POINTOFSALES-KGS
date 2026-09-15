import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { uuidValue } from '@/lib/master-data'

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const id = new URL(request.url).searchParams.get('salesId')
    const { data, error } = await caller.client.rpc('get_office_retail_history', {
      p_sales_id: id ? uuidValue(id) : null,
    })
    if (error) throw error
    return Response.json(data)
  } catch (error) { return apiError(error) }
}
