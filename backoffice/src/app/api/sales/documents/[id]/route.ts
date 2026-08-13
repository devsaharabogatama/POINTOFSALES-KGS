import { ApiRouteError, apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import {
  enumValue,
  optionalText,
  readJsonObject,
  requiredText,
  requiredVersion,
  uuidValue,
} from '@/lib/master-data'

type RouteContext = { params: Promise<{ id: string }> }

function rpcFailure(message: string): never {
  const known = [
    'SALES_DOCUMENT_NOT_FOUND', 'SALES_INVOICE_NOT_FOUND',
    'SALES_DELIVERY_NOT_FOUND', 'MASTER_VERSION_CONFLICT',
    'SALES_DELIVERY_MANAGER_REQUIRED', 'INVALID_SALES_DELIVERY_TRANSITION',
    'INVALID_SALES_DOCUMENT_TYPE',
  ]
  const code = known.find((candidate) => message.includes(candidate))
  throw new ApiRouteError(code ?? 'SALES_DOCUMENT_OPERATION_FAILED',
    code?.endsWith('_REQUIRED') ? 403 : code === 'MASTER_VERSION_CONFLICT' ? 409 : 400)
}

export async function GET(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const { id } = await context.params
    const salesId = uuidValue(id)
    const invoiceRpc = await caller.client.rpc('get_sales_invoice_document', {
      p_sales_id: salesId,
    })
    if (invoiceRpc.error) rpcFailure(invoiceRpc.error.message)
    return Response.json({
      companyId,
      invoice: invoiceRpc.data,
    })
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
    const deliveryDocumentId = uuidValue(String(body.deliveryDocumentId ?? ''))
    const action = enumValue(body.action, ['DISPATCH', 'DELIVER', 'CANCEL'] as const, 'INVALID_SALES_DELIVERY_ACTION')
    const reason = action === 'CANCEL'
      ? requiredText(body, 'reason', { maxLength: 500 })
      : optionalText(body, 'reason', { maxLength: 500 }) ?? null
    const { data, error } = await caller.client.rpc('update_sales_delivery_status', {
      p_delivery_document_id: deliveryDocumentId,
      p_master_version: requiredVersion(body),
      p_action: action,
      p_reason: reason,
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
    const documentType = enumValue(body.documentType,
      ['SALES_INVOICE'] as const, 'INVALID_SALES_DOCUMENT_TYPE')
    const documentId = uuidValue(String(body.documentId ?? ''))
    const { data, error } = await caller.client.rpc('record_sales_document_print', {
      p_document_type: documentType,
      p_document_id: documentId,
    })
    if (error) rpcFailure(error.message)
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}
