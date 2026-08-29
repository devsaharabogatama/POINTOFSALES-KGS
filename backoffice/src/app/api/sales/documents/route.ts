import { ApiRouteError, apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { enumValue, readJsonObject, uuidValue } from '@/lib/master-data'

function rpcFailure(message: string): never {
  const known = [
    'SALES_DOCUMENT_NOT_FOUND', 'SALES_INVOICE_NOT_FOUND',
    'INVALID_SALES_DOCUMENT_TYPE',
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
      const invoiceRpc = await caller.client.rpc('get_sales_invoice_document', {
        p_sales_id: salesId,
      })
      if (invoiceRpc.error) rpcFailure(invoiceRpc.error.message)
      return Response.json({ companyId, invoice: invoiceRpc.data })
    }
    const { data, error } = await caller.client.rpc('get_sales_documents')
    if (error) throw error
    const payload = data as { data?: unknown[] } | null
    return Response.json({ companyId, data: payload?.data ?? [] })
  } catch (error) {
    return apiError(error)
  }
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const body = await readJsonObject(request)
    uuidValue(String(body.salesId ?? ''))
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
