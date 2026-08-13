import { ApiRouteError, apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { enumValue, optionalText, readJsonObject, requiredText, requiredVersion, uuidValue } from '@/lib/master-data'

type RouteContext = { params: Promise<{ id: string }> }

function rpcFailure(message: string): never {
  const known = ['SALES_DELIVERY_NOT_FOUND', 'MASTER_VERSION_CONFLICT',
    'INVALID_SALES_DELIVERY_TRANSITION', 'CANCEL_REASON_REQUIRED',
    'CUSTOM_PERMISSION_DENIED']
  const code = known.find((candidate) => message.includes(candidate))
  throw new ApiRouteError(code ?? 'SALES_DELIVERY_OPERATION_FAILED',
    code === 'CUSTOM_PERMISSION_DENIED' ? 403 : code === 'MASTER_VERSION_CONFLICT' ? 409 : 400)
}

export async function GET(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const salesId = uuidValue((await context.params).id)
    const { data, error } = await caller.client.rpc('get_inventory_delivery_document', {
      p_sales_id: salesId,
    })
    if (error) rpcFailure(error.message)
    return Response.json({ companyId, delivery: data })
  } catch (error) {
    return apiError(error)
  }
}

export async function PATCH(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    uuidValue((await context.params).id)
    const body = await readJsonObject(request)
    const action = enumValue(body.action, ['DISPATCH', 'DELIVER', 'CANCEL'] as const,
      'INVALID_SALES_DELIVERY_ACTION')
    const reason = action === 'CANCEL'
      ? requiredText(body, 'reason', { maxLength: 500 })
      : optionalText(body, 'reason', { maxLength: 500 }) ?? null
    const { data, error } = await caller.client.rpc('update_sales_delivery_status', {
      p_delivery_document_id: uuidValue(String(body.deliveryDocumentId ?? '')),
      p_master_version: requiredVersion(body), p_action: action, p_reason: reason,
    })
    if (error) rpcFailure(error.message)
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}

export async function POST(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    uuidValue((await context.params).id)
    const body = await readJsonObject(request)
    const { data, error } = await caller.client.rpc('record_inventory_delivery_print', {
      p_delivery_document_id: uuidValue(String(body.deliveryDocumentId ?? '')),
    })
    if (error) rpcFailure(error.message)
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}
