import { ApiRouteError, apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import {
  enumValue,
  readJsonObject,
  requiredText,
  requiredVersion,
  uuidValue,
} from '@/lib/master-data'

function rpcFailure(message: string): never {
  const known = [
    'SALES_DOCUMENT_NOT_FOUND', 'SALES_INVOICE_NOT_FOUND',
    'INVALID_SALES_DOCUMENT_TYPE',
    'SALES_ORDER_NOT_FOUND', 'SALES_ORDER_FINAL',
    'SALES_ORDER_DISPATCH_STARTED', 'SALES_ORDER_CANCEL_FORBIDDEN',
    'SALES_ORDER_VERIFIED_PAYMENT_REVERSAL_REQUIRED',
    'SALES_ORDER_CASH_REFUND_REQUIRES_OPEN_SESSION',
    'SALES_ORDER_CASH_REFUND_REQUIRES_CURRENT_OPEN_SESSION',
    'SALES_ORDER_REVISION_PENDING',
    'MASTER_VERSION_CONFLICT', 'CUSTOM_PERMISSION_DENIED',
    'CANCEL_REASON_REQUIRED', 'IDEMPOTENCY_PAYLOAD_CONFLICT',
  ]
  const code = known.find((candidate) => message.includes(candidate))
  throw new ApiRouteError(code ?? 'SALES_DOCUMENT_OPERATION_FAILED', 400)
}

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const salesIdParam = new URL(request.url).searchParams.get('salesId')
    if (salesIdParam) {
      const salesId = uuidValue(salesIdParam)
      const [invoiceRpc, revisionRpc] = await Promise.all([
        caller.client.rpc('get_sales_invoice_document', {
          p_sales_id: salesId,
        }),
        caller.client.rpc('get_sales_order_revision_links'),
      ])
      if (invoiceRpc.error) rpcFailure(invoiceRpc.error.message)
      if (revisionRpc.error) rpcFailure(revisionRpc.error.message)
      const links = Array.isArray(revisionRpc.data)
        ? revisionRpc.data as Array<Record<string, unknown>> : []
      const revision = links.find((item) =>
        item.sourceSalesId === salesId || item.replacementSalesId === salesId)
      return Response.json({ companyId, invoice: {
        ...(invoiceRpc.data as Record<string, unknown>),
        revision: revision ?? null,
      } })
    }
    const [documentRpc, revisionRpc] = await Promise.all([
      caller.client.rpc('get_sales_documents'),
      caller.client.rpc('get_sales_order_revision_links'),
    ])
    if (documentRpc.error) throw documentRpc.error
    if (revisionRpc.error) rpcFailure(revisionRpc.error.message)
    const payload = documentRpc.data as { data?: unknown[] } | null
    const links = Array.isArray(revisionRpc.data)
      ? revisionRpc.data as Array<Record<string, unknown>> : []
    const rows = Array.isArray(payload?.data)
      ? payload.data as Array<Record<string, unknown>> : []
    return Response.json({ companyId, data: rows.map((row) => ({
      ...row,
      revision: links.find((item) =>
        item.sourceSalesId === row.salesId || item.replacementSalesId === row.salesId) ?? null,
    })) })
  } catch (error) {
    return apiError(error)
  }
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const body = await readJsonObject(request)
    const salesId = uuidValue(String(body.salesId ?? ''))
    if (String(body.action ?? '').toUpperCase() === 'CANCEL') {
      const { data, error } = await caller.client.rpc(
        'cancel_sales_order_from_backoffice', {
          p_sales_id: salesId,
          p_master_version: requiredVersion(body),
          p_idempotency_key: uuidValue(String(body.idempotencyKey ?? ''),
            'IDEMPOTENCY_KEY_REQUIRED'),
          p_reason: requiredText(body, 'reason', { maxLength: 500 }),
        },
      )
      if (error) rpcFailure(error.message)
      return Response.json({ data })
    }
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
