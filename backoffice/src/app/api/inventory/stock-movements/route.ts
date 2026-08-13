import { apiError, requireActiveCompany, requireCaller, requirePermissionCapability } from '@/lib/server-auth'
import { throwDatabaseError } from '@/lib/master-data'

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    await requirePermissionCapability(
      caller, companyId, 'inventory.stock_movements', 'VIEW',
    )
    const { data, error } = await caller.client.rpc('get_inventory_stock_movements')
    if (error) throwDatabaseError(error)
    return Response.json(data ?? {
      companyId, data: [], products: [], warehouses: [],
      openingDocuments: [], transferDocuments: [], adjustmentDocuments: [], actors: [],
    })
  } catch (error) {
    return apiError(error)
  }
}
