import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject, throwDatabaseError } from '@/lib/master-data'
import { parseSupplierOrderBody, supplierOrderRpcArgs, throwSupplierOrderError } from '@/lib/supplier-order'

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const { data, error } = await caller.client.rpc('get_purchase_supplier_orders')
    if (error) throwDatabaseError(error)
    return Response.json(data ?? {})
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
