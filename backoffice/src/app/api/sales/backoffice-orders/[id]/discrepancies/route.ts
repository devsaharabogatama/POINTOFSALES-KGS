import { readJsonObject, requiredVersion, uuidValue } from '@/lib/master-data'
import { parseOverageApprovalLines, throwDiscrepancyDatabaseError } from '@/lib/backoffice-sales-discrepancy'
import { ApiRouteError, apiError, requireActiveCompany, requireCaller, requirePermissionCapability } from '@/lib/server-auth'

type Context = { params: Promise<{ id: string }> }

export async function GET(request: Request, { params }: Context) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const { id } = await params
    const { data, error } = await caller.client.rpc('get_backoffice_sales_discrepancy_workspace', {
      p_sales_order_id: uuidValue(id, 'BACKOFFICE_SALES_ORDER_ID_INVALID'),
      p_delivery_order_id: null,
    })
    if (error) throwDiscrepancyDatabaseError(error)
    return Response.json(data)
  } catch (error) {
    return apiError(error)
  }
}

export async function PATCH(request: Request, { params }: Context) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    await requirePermissionCapability(caller, companyId, 'sales.sales_orders', 'MANAGE')
    const { id } = await params
    uuidValue(id, 'BACKOFFICE_SALES_ORDER_ID_INVALID')
    const body = await readJsonObject(request)
    if (String(body.action ?? '').trim().toUpperCase() !== 'APPROVE_OVERAGE') {
      throw new ApiRouteError('BACKOFFICE_DISCREPANCY_ACTION_INVALID', 400)
    }
    const operationId = uuidValue(String(body.operationId ?? ''), 'IDEMPOTENCY_KEY_REQUIRED')
    const discrepancyId = uuidValue(String(body.discrepancyId ?? ''), 'BACKOFFICE_DISCREPANCY_NOT_FOUND')
    const lines = parseOverageApprovalLines(body.lines)
    const notes = typeof body.notes === 'string' ? body.notes.trim() : ''
    if (notes.length > 500) throw new ApiRouteError('OVERAGE_APPROVAL_PAYLOAD_INVALID', 400)
    const { data, error } = await caller.client.rpc('approve_backoffice_sales_delivery_overage', {
      p_discrepancy_id: discrepancyId,
      p_expected_version: requiredVersion(body),
      p_operation_id: operationId,
      p_payload: { lines },
      p_notes: notes || null,
    })
    if (error) throwDiscrepancyDatabaseError(error)
    return Response.json({ companyId, data })
  } catch (error) {
    return apiError(error)
  }
}
