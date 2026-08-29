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
    const [documentResult, workspaceResult] = await Promise.all([
      caller.client.rpc('get_inventory_delivery_documents', {
        p_date_from: dateFrom,
        p_date_to: dateTo,
      }),
      caller.client.rpc('get_inventory_delivery_dispatch_workspace', {
        p_date_from: dateFrom,
        p_date_to: dateTo,
      }),
    ])
    if (documentResult.error) throw documentResult.error
    if (workspaceResult.error) throw workspaceResult.error
    const payload = documentResult.data as { data?: Array<Record<string, unknown>> } | null
    const workspace = workspaceResult.data as {
      deliveries?: Array<Record<string, unknown>>
      lines?: Array<Record<string, unknown>>
    } | null
    const canonicalById = new Map(
      (workspace?.deliveries ?? []).map((row) => [String(row.id), row]),
    )
    const rows = (payload?.data ?? []).map((row) => {
      const canonical = canonicalById.get(String(row.deliveryDocumentId))
      return canonical ? {
        ...row,
        reservationId: canonical.reservation_id,
        reservationStatus: canonical.reservation_status,
        dispatchVersion: canonical.dispatch_version,
        totalReservedBaseQty: canonical.total_reserved_base_qty,
        totalDispatchedBaseQty: canonical.reservation_dispatched_base_qty,
      } : { ...row, reservationId: null }
    })
    return Response.json({
      companyId,
      dispatchWorkspaceVersion: 1,
      data: rows,
      dispatchLines: workspace?.lines ?? [],
    })
  } catch (error) {
    return apiError(error)
  }
}
