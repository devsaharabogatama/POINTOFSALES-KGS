import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { parseIncludeInactive, readJsonObject, throwDatabaseError } from '@/lib/master-data'
import { parseSupplierBody, supplierRpcArgs, throwSupplierRpcError } from '@/lib/supplier-master'

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const { data, error } = await caller.client.rpc('get_contacts_suppliers', {
      p_include_inactive: parseIncludeInactive(request),
    })
    if (error) throwDatabaseError(error)
    const payload = (data ?? {}) as { data?: unknown[] }
    return Response.json({ companyId, data: payload.data ?? [] })
  } catch (error) {
    return apiError(error)
  }
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const input = parseSupplierBody(await readJsonObject(request), false)
    const { data, error } = await caller.client.rpc(
      'save_contacts_supplier', supplierRpcArgs(null, input),
    )
    if (error) throwSupplierRpcError(error)
    return Response.json({ data }, { status: 201 })
  } catch (error) {
    return apiError(error)
  }
}
