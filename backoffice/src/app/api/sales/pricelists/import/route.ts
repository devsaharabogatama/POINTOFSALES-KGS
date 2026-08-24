import { ApiRouteError, apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { requireDataExchangeAction } from '@/lib/data-exchange-server'

type Body = {
  mode?: unknown
  fileName?: unknown
  checksum?: unknown
  clientRequestId?: unknown
  rows?: unknown
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    await requireDataExchangeAction(caller, companyId, 'PRICELISTS', 'IMPORT')
    const body = await request.json() as Body
    const apply = body.mode === 'APPLY'
    if (body.mode !== 'PREVIEW' && !apply) throw new ApiRouteError('INVALID_IMPORT_MODE', 400)
    if (typeof body.fileName !== 'string' || !body.fileName.trim()) {
      throw new ApiRouteError('PRICELIST_IMPORT_FILE_NAME_INVALID', 400)
    }
    if (typeof body.checksum !== 'string' || !/^[0-9a-f]{64}$/i.test(body.checksum)) {
      throw new ApiRouteError('PRICELIST_IMPORT_CHECKSUM_INVALID', 400)
    }
    if (!Array.isArray(body.rows)) throw new ApiRouteError('PRICELIST_IMPORT_ROWS_REQUIRED', 400)
    if (apply && (typeof body.clientRequestId !== 'string'
      || !/^[0-9a-f-]{36}$/i.test(body.clientRequestId))) {
      throw new ApiRouteError('CLIENT_REQUEST_ID_REQUIRED', 400)
    }
    const { data, error } = await caller.client.rpc('process_distributor_pricelist_import', {
      p_rows: body.rows,
      p_source_file_name: body.fileName.trim(),
      p_source_file_checksum: body.checksum.toLowerCase(),
      p_client_request_id: apply ? body.clientRequestId : null,
      p_apply: apply,
      p_confirmation: apply ? 'IMPORT_DISTRIBUTOR_PRICELIST' : null,
    })
    if (error) throw new ApiRouteError(error.message || 'PRICELIST_IMPORT_FAILED', 400)
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}
