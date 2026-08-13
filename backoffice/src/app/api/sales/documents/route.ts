import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const { data, error } = await caller.client.rpc('get_sales_documents')
    if (error) throw error
    const payload = data as { data?: unknown[] } | null
    return Response.json({ companyId, data: payload?.data ?? [] })
  } catch (error) {
    return apiError(error)
  }
}
