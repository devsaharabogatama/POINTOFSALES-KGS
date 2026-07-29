import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { throwDatabaseError, uuidValue } from '@/lib/master-data'

type RouteContext = { params: Promise<{ id: string }> }

export async function GET(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const { id } = await context.params
    const bundleId = uuidValue(id, 'INVALID_BUNDLE_ID')
    const warehouseId = uuidValue(
      new URL(request.url).searchParams.get('warehouseId') ?? '',
      'INVALID_WAREHOUSE_ID',
    )
    const { data, error } = await caller.client.rpc('get_bundle_availability', {
      p_bundle_id: bundleId,
      p_warehouse_id: warehouseId,
    })
    if (error) throwDatabaseError(error)
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}
