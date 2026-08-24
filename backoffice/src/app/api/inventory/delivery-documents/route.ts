import { ApiRouteError, apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'

function optionalDate(value: string | null, field: string) {
  if (!value) return null
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    throw new ApiRouteError(`${field}_INVALID`, 400)
  }
  const parsed = new Date(`${value}T00:00:00.000Z`)
  if (Number.isNaN(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== value) {
    throw new ApiRouteError(`${field}_INVALID`, 400)
  }
  return value
}

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const url = new URL(request.url)
    const dateFrom = optionalDate(url.searchParams.get('dateFrom'), 'DELIVERY_DATE_FROM')
    const dateTo = optionalDate(url.searchParams.get('dateTo'), 'DELIVERY_DATE_TO')
    if (dateFrom && dateTo && dateFrom > dateTo) {
      throw new ApiRouteError('INVALID_DELIVERY_DATE_RANGE', 400)
    }
    const { data, error } = await caller.client.rpc('get_inventory_delivery_documents', {
      p_date_from: dateFrom,
      p_date_to: dateTo,
    })
    if (error) throw error
    const payload = data as { data?: unknown[] } | null
    return Response.json({ companyId, data: payload?.data ?? [] })
  } catch (error) {
    return apiError(error)
  }
}
