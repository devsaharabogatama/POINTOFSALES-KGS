import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject, uuidValue } from '@/lib/master-data'
import { parseSupplierBody, supplierRpcArgs, throwSupplierRpcError } from '@/lib/supplier-master'

type RouteContext = { params: Promise<{ id: string }> }

export async function PATCH(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const { id } = await context.params
    const supplierId = uuidValue(id)
    const input = parseSupplierBody(await readJsonObject(request), true)
    const { data, error } = await caller.client.rpc(
      'save_contacts_supplier',
      supplierRpcArgs(supplierId, input),
    )
    if (error) throwSupplierRpcError(error)
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}
