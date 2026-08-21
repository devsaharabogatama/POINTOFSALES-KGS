import { ApiRouteError, apiError, requireActiveCompany, requireCaller, requirePermissionCapability } from '@/lib/server-auth'
import {
  isImportType,
  isOperationMode,
  isReferenceMode,
  isUuid,
} from '@/lib/master-import'
import { readObject, requireImportManager, throwImportError } from '@/lib/master-import-server'

const jobFields = `
  id,import_type,reference_mode,operation_mode,file_name,status,total_rows,
  created_rows,updated_rows,skipped_rows,error_rows,confirmed_update_count,
  master_version,uploaded_at,validated_at,committed_at,updated_at
`

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    await requireImportManager(caller, companyId)
    const cleanup = await caller.client.rpc('cleanup_stale_master_import_jobs')
    if (cleanup.error) throwImportError(cleanup.error)
    const optionalPermission = (permissionKey: string) => requirePermissionCapability(
      caller, companyId, permissionKey, 'VIEW',
    ).catch((error) => {
      if (error instanceof ApiRouteError && error.message === 'CUSTOM_PERMISSION_DENIED') return null
      throw error
    })
    const [productPermission, minimumStockPermission] = await Promise.all([
      optionalPermission('inventory.products'),
      optionalPermission('inventory.minimum_stock'),
    ])
    let query = caller.client
      .from('master_import_jobs')
      .select(jobFields)
      .eq('company_id', companyId)
      .order('created_at', { ascending: false })
      .limit(50)
    if (!productPermission) query = query.neq('import_type', 'PRODUCT')
    if (!minimumStockPermission) {
      query = query.neq('import_type', 'PRODUCT_WAREHOUSE_MINIMUM_STOCK')
    }
    const { data, error } = await query
    if (error) throwImportError(error)
    return Response.json({ companyId, data: data ?? [] })
  } catch (error) {
    return apiError(error)
  }
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    await requireImportManager(caller, companyId)
    const body = readObject(await request.json())
    if (!isUuid(body.clientRequestId)) throw new ApiRouteError('INVALID_CLIENT_REQUEST_ID', 400)
    if (!isImportType(body.importType)) throw new ApiRouteError('UNSUPPORTED_IMPORT_TYPE', 400)
    if (body.importType === 'PRODUCT') {
      await requirePermissionCapability(caller, companyId, 'inventory.products', 'IMPORT')
    }
    if (body.importType === 'PRODUCT_WAREHOUSE_MINIMUM_STOCK') {
      await requirePermissionCapability(
        caller, companyId, 'inventory.minimum_stock', 'IMPORT',
      )
    }
    if (!isReferenceMode(body.referenceMode)) throw new ApiRouteError('INVALID_IMPORT_REFERENCE_MODE', 400)
    if (!isOperationMode(body.operationMode)) throw new ApiRouteError('INVALID_IMPORT_OPERATION_MODE', 400)
    if (typeof body.fileName !== 'string' || !body.fileName.trim() || body.fileName.length > 255) {
      throw new ApiRouteError('IMPORT_FILE_NAME_INVALID', 400)
    }
    if (typeof body.fileChecksum !== 'string' || !/^[0-9a-f]{64}$/i.test(body.fileChecksum)) {
      throw new ApiRouteError('INVALID_IMPORT_FILE_CHECKSUM', 400)
    }
    if (![',', ';', '\t', '|'].includes(String(body.delimiter))) {
      throw new ApiRouteError('INVALID_IMPORT_DELIMITER', 400)
    }
    const { data, error } = await caller.client.rpc('create_master_import_job', {
      p_client_request_id: body.clientRequestId,
      p_import_type: body.importType,
      p_reference_mode: body.referenceMode,
      p_operation_mode: body.operationMode,
      p_file_name: body.fileName.trim(),
      p_file_checksum: body.fileChecksum.toLowerCase(),
      p_delimiter: body.delimiter,
    })
    if (error) throwImportError(error)
    return Response.json({ data }, { status: data?.action === 'CREATE' ? 201 : 200 })
  } catch (error) {
    return apiError(error)
  }
}
