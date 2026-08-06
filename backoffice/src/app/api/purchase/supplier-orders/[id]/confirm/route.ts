import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject, requiredVersion, uuidValue } from '@/lib/master-data'
import { throwSupplierOrderError } from '@/lib/supplier-order'

export async function POST(request: Request, { params }: { params: Promise<{ id: string }> }) {
  try {
    const caller = await requireCaller(request); await requireActiveCompany(caller)
    const { id } = await params; const body = await readJsonObject(request)
    const key = typeof body.idempotencyKey === 'string' ? uuidValue(body.idempotencyKey, 'IDEMPOTENCY_KEY_INVALID') : crypto.randomUUID()
    const { data, error } = await caller.client.rpc('confirm_supplier_order', { p_document_id: uuidValue(id, 'SUPPLIER_ORDER_ID_INVALID'), p_master_version: requiredVersion(body), p_idempotency_key: key })
    if (error) throwSupplierOrderError(error)
    return Response.json({ data })
  } catch (error) { return apiError(error) }
}
