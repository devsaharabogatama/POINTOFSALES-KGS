import { apiError, requireCaller } from '@/lib/server-auth'

type ActiveCompanyBody = {
  companyId?: string
  source?: string
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request)
    const body = (await request.json()) as ActiveCompanyBody
    const companyId = body.companyId?.trim()
    const source = body.source?.trim().toUpperCase() || 'BACKOFFICE'

    if (!companyId) {
      return Response.json({ error: 'COMPANY_ID_REQUIRED' }, { status: 400 })
    }

    const { data, error } = await caller.client.rpc('set_active_company_context', {
      p_company_id: companyId,
      p_selection_source: source,
    })
    if (error) throw error
    const result = (Array.isArray(data) ? data[0] : data) as
      | { company_id?: string }
      | null
    if (result?.company_id !== companyId) {
      throw new Error('ACTIVE_COMPANY_CONTEXT_NOT_CONFIRMED')
    }

    return Response.json({ activeCompanyId: result.company_id })
  } catch (error) {
    return apiError(error)
  }
}
