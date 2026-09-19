import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { uuidValue } from '@/lib/master-data'
import { salesReturnAdjustmentMap } from '@/lib/sales-return-commercial'

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const id = new URL(request.url).searchParams.get('salesId')
    const [history, adjustments, commercial] = await Promise.all([
      caller.client.rpc('get_office_retail_history', {
        p_sales_id: id ? uuidValue(id) : null,
      }),
      caller.client.rpc('get_sales_return_commercial_adjustments'),
      caller.client.rpc('get_sales_invoice_commercial_statuses'),
    ])
    if (history.error) throw history.error
    const adjustmentMissing = adjustments.error?.code === 'PGRST202'
      || Boolean(adjustments.error?.message?.includes('get_sales_return_commercial_adjustments'))
    if (adjustments.error && !adjustmentMissing) throw adjustments.error
    const commercialMissing = commercial.error?.code === 'PGRST202'
      || Boolean(commercial.error?.message?.includes('get_sales_invoice_commercial_statuses'))
    if (commercial.error && !commercialMissing) throw commercial.error
    const adjustmentMap = salesReturnAdjustmentMap(adjustments.data)
    const commercialRows = (commercial.data as { data?: Array<Record<string, unknown>> } | null)?.data ?? []
    const commercialMap = new Map(commercialRows.filter((row) => row.sourceKind === 'RETAIL'
      && typeof row.sourceId === 'string').map((row) => [row.sourceId as string, row]))
    const payload = history.data as { data?: Array<Record<string, unknown>> } | null
    return Response.json({ ...payload, data: (payload?.data ?? []).map((row) => ({
      ...row,
      ...(typeof row.id === 'string' ? commercialMap.get(row.id) ?? {} : {}),
      returnAdjustment: typeof row.id === 'string'
        ? adjustmentMap.get(`RETAINED_RETAIL:${row.id}`) ?? null : null,
    })) })
  } catch (error) { return apiError(error) }
}
