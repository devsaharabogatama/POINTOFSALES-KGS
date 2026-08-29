import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject, throwDatabaseError } from '@/lib/master-data'
import { parseSupplierOrderBody, supplierOrderRpcArgs, throwSupplierOrderError } from '@/lib/supplier-order'

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const [ordersResult, demandResult] = await Promise.all([
      caller.client.rpc('get_purchase_supplier_orders'),
      caller.client.rpc('get_purchase_procurement_demands'),
    ])
    if (ordersResult.error) throwDatabaseError(ordersResult.error)
    if (demandResult.error) throwDatabaseError(demandResult.error)
    const orders = (ordersResult.data ?? {}) as Record<string, unknown>
    const demand = (demandResult.data ?? {}) as Record<string, unknown>
    return Response.json({
      ...orders,
      procurementWorkspaceVersion: 1,
      procurementDemands: demand.demands ?? [],
      procurementDemandLines: demand.lines ?? [],
      procurementAmendments: demand.amendments ?? [],
    })
  } catch (error) { return apiError(error) }
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const input = parseSupplierOrderBody(await readJsonObject(request))
    const { data, error } = await caller.client.rpc('save_supplier_order', supplierOrderRpcArgs(null, input))
    if (error) throwSupplierOrderError(error)
    return Response.json({ data }, { status: 201 })
  } catch (error) { return apiError(error) }
}
