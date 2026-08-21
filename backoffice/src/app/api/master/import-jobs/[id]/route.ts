import { ApiRouteError, apiError, requireActiveCompany, requireCaller, requirePermissionCapability } from '@/lib/server-auth'
import { isUuid } from '@/lib/master-import'
import { readObject, requireImportManager, throwImportError } from '@/lib/master-import-server'

type RouteContext = { params: Promise<{ id: string }> }

const jobFields = `
  id,import_type,reference_mode,operation_mode,file_name,file_checksum,delimiter,
  mapping,status,total_rows,created_rows,updated_rows,skipped_rows,error_rows,
  confirmed_update_count,master_version,uploaded_at,validated_at,committed_at,updated_at
`

export async function GET(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    await requireImportManager(caller, companyId)
    const { id } = await context.params
    if (!isUuid(id)) throw new ApiRouteError('IMPORT_JOB_NOT_FOUND', 404)
    const [jobResult, rowResult, eventResult, storeResult] = await Promise.all([
      caller.client.from('master_import_jobs').select(jobFields)
        .eq('company_id', companyId).eq('id', id).maybeSingle(),
      caller.client.from('master_import_rows')
        .select('row_number,group_key,source_data,operation,row_status,warnings,errors,before_state,after_state')
        .eq('company_id', companyId).eq('job_id', id).order('row_number').limit(5000),
      caller.client.from('master_import_job_events')
        .select('event_type,after_state,created_at')
        .eq('company_id', companyId).eq('job_id', id)
        .order('created_at', { ascending: false }).limit(20),
      caller.client.from('stores').select('id,store_name')
        .eq('company_id', companyId).order('store_name').limit(500),
    ])
    for (const result of [jobResult, rowResult, eventResult, storeResult]) {
      if (result.error) throwImportError(result.error)
    }
    if (!jobResult.data) throw new ApiRouteError('IMPORT_JOB_NOT_FOUND', 404)
    if (jobResult.data.import_type === 'PRODUCT') {
      await requirePermissionCapability(caller, companyId, 'inventory.products', 'VIEW')
    }
    if (jobResult.data.import_type === 'PRODUCT_WAREHOUSE_MINIMUM_STOCK') {
      await requirePermissionCapability(
        caller, companyId, 'inventory.minimum_stock', 'VIEW',
      )
    }
    return Response.json({
      data: jobResult.data,
      rows: rowResult.data ?? [],
      events: eventResult.data ?? [],
      stores: storeResult.data ?? [],
    })
  } catch (error) {
    return apiError(error)
  }
}

export async function PATCH(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    await requireImportManager(caller, companyId)
    const { id } = await context.params
    if (!isUuid(id)) throw new ApiRouteError('IMPORT_JOB_NOT_FOUND', 404)
    const { data: jobScope, error: jobScopeError } = await caller.client
      .from('master_import_jobs').select('import_type')
      .eq('company_id', companyId).eq('id', id).maybeSingle()
    if (jobScopeError) throwImportError(jobScopeError)
    if (!jobScope) throw new ApiRouteError('IMPORT_JOB_NOT_FOUND', 404)
    if (jobScope.import_type === 'PRODUCT') {
      await requirePermissionCapability(caller, companyId, 'inventory.products', 'IMPORT')
    }
    if (jobScope.import_type === 'PRODUCT_WAREHOUSE_MINIMUM_STOCK') {
      await requirePermissionCapability(
        caller, companyId, 'inventory.minimum_stock', 'IMPORT',
      )
    }
    const body = readObject(await request.json())
    const masterVersion = Number(body.masterVersion)
    if (!Number.isSafeInteger(masterVersion) || masterVersion < 1) {
      throw new ApiRouteError('MASTER_VERSION_REQUIRED', 400)
    }

    if (body.action === 'STAGE') {
      const mapping = readObject(body.mapping)
      if (!Array.isArray(body.rows) || body.rows.length < 1 || body.rows.length > 5000) {
        throw new ApiRouteError('IMPORT_ROWS_INVALID', 400)
      }
      const seen = new Set<number>()
      const parsedRows = body.rows.map((raw) => {
        const row = readObject(raw)
        const rowNumber = Number(row.rowNumber)
        const sourceData = readObject(row.sourceData)
        if (!Number.isSafeInteger(rowNumber) || rowNumber < 1 || seen.has(rowNumber)) {
          throw new ApiRouteError('INVALID_IMPORT_ROW_NUMBER', 400)
        }
        seen.add(rowNumber)
        if (Object.keys(sourceData).length > 100) throw new ApiRouteError('IMPORT_COLUMN_LIMIT_EXCEEDED', 400)
        const cleanSource: Record<string, string> = {}
        for (const [key, value] of Object.entries(sourceData)) {
          if (!key.trim() || key.length > 120 || typeof value !== 'string' || value.length > 10000) {
            throw new ApiRouteError('INVALID_IMPORT_SOURCE_DATA', 400)
          }
          cleanSource[key] = value
        }
        return { rowNumber, sourceData: cleanSource }
      })
      const rows = jobScope.import_type === 'PRODUCT_UOM'
        ? parsedRows.filter((row) => {
            const mode = Object.entries(row.sourceData).find(([key]) =>
              key.trim().toLowerCase() === 'row_mode')?.[1]
            return mode?.trim().toUpperCase() !== 'REFERENCE'
          })
        : parsedRows
      if (rows.length < 1) throw new ApiRouteError('IMPORT_ROWS_INVALID', 400)
      if (jobScope.import_type === 'PRODUCT_UOM') {
        const mappedValue = (
          row: { sourceData: Record<string, string> }, field: string,
        ) => {
          const column = mapping[field]
          return typeof column === 'string' ? row.sourceData[column]?.trim() ?? '' : ''
        }
        const inputFields = [
          'factorToBase', 'purchaseAllowed', 'salesAllowed', 'purchasePrice',
          'salePrice', 'barcode', 'weightIfLargestKg',
        ]
        const missingUomRows = rows.filter((row) =>
          !mappedValue(row, 'uomName') &&
          inputFields.some((field) => mappedValue(row, field) !== ''),
        )
        if (missingUomRows.length > 0) {
          throw new ApiRouteError(
            `PRODUCT_UOM_NAME_REQUIRED:${missingUomRows
              .slice(0, 10).map((row) => row.rowNumber).join(',')}`,
            400,
          )
        }
        const modeOf = (row: { sourceData: Record<string, string> }) =>
          Object.entries(row.sourceData).find(([key]) =>
            key.trim().toLowerCase() === 'row_mode')?.[1]?.trim().toUpperCase() ?? ''
        const normalizedBarcode = (value: string) =>
          value.replace(/\s+/g, '').toUpperCase()
        const pairOf = (row: { sourceData: Record<string, string> }) =>
          `${mappedValue(row, 'productSku').toUpperCase()}|${mappedValue(row, 'uomName').toLocaleUpperCase('id-ID')}`
        const referenceBarcodePairs = new Map<string, string>()
        for (const row of parsedRows) {
          if (modeOf(row) !== 'REFERENCE') continue
          const barcode = normalizedBarcode(mappedValue(row, 'barcode'))
          if (barcode) referenceBarcodePairs.set(barcode, pairOf(row))
        }
        const inputBarcodePairs = new Map<string, string>()
        const conflictingBarcodeRows: number[] = []
        for (const row of rows) {
          const barcode = normalizedBarcode(mappedValue(row, 'barcode'))
          if (!barcode) continue
          const pair = pairOf(row)
          const referencePair = referenceBarcodePairs.get(barcode)
          const inputPair = inputBarcodePairs.get(barcode)
          if ((referencePair && referencePair !== pair) ||
              (inputPair && inputPair !== pair)) {
            conflictingBarcodeRows.push(row.rowNumber)
          } else {
            inputBarcodePairs.set(barcode, pair)
          }
        }
        if (conflictingBarcodeRows.length > 0) {
          throw new ApiRouteError(
            `PRODUCT_UOM_BARCODE_CONFLICT:${conflictingBarcodeRows
              .slice(0, 10).join(',')}`,
            400,
          )
        }
      }
      const cleanMapping: Record<string, string> = {}
      for (const [key, value] of Object.entries(mapping)) {
        if (typeof value !== 'string' || value.length > 120) {
          throw new ApiRouteError('INVALID_IMPORT_MAPPING', 400)
        }
        cleanMapping[key] = value
      }
      const storeReferenceColumn = cleanMapping.storeReference
      if (storeReferenceColumn) {
        const { data: stores, error: storeError } = await caller.client
          .from('stores')
          .select('id,store_code,store_name')
          .eq('company_id', companyId)
          .eq('status', 'ACTIVE')
          .limit(5000)
        if (storeError) throwImportError(storeError)
        const references = new Map<string, string | null>()
        const register = (value: string, id: string) => {
          const normalized = value.trim().toLocaleLowerCase('id-ID').replace(/\s+/g, ' ')
          if (!normalized) return
          if (!references.has(normalized)) {
            references.set(normalized, id)
            return
          }
          if (references.get(normalized) !== id) references.set(normalized, null)
        }
        for (const store of stores ?? []) {
          register(store.store_name, store.id)
          register(store.store_code, store.id)
          register(`${store.store_name} (${store.store_code})`, store.id)
        }
        for (const row of rows) {
          const raw = row.sourceData[storeReferenceColumn]?.trim() ?? ''
          const normalized = raw.toLocaleLowerCase('id-ID').replace(/\s+/g, ' ')
          row.sourceData.__resolved_store_id = raw
            ? references.get(normalized) ?? '00000000-0000-0000-0000-000000000000'
            : ''
        }
        cleanMapping.storeId = '__resolved_store_id'
        delete cleanMapping.storeReference
      }
      const { data, error } = await caller.client.rpc('stage_master_import_rows', {
        p_job_id: id,
        p_master_version: masterVersion,
        p_mapping: cleanMapping,
        p_rows: rows,
      })
      if (error) throwImportError(error)
      return Response.json({ data })
    }

    if (body.action === 'VALIDATE') {
      const { data, error } = await caller.client.rpc('validate_master_import_job', {
        p_job_id: id,
        p_master_version: masterVersion,
      })
      if (error) throwImportError(error)
      return Response.json({ data })
    }

    if (body.action === 'COMMIT') {
      const updateCount = Number(body.confirmUpdateCount)
      if (!Number.isSafeInteger(updateCount) || updateCount < 0) {
        throw new ApiRouteError('IMPORT_UPDATE_CONFIRMATION_REQUIRED', 400)
      }
      const { data, error } = await caller.client.rpc('commit_master_import_job', {
        p_job_id: id,
        p_master_version: masterVersion,
        p_confirm_update_count: updateCount,
      })
      if (error) throwImportError(error)
      return Response.json({ data })
    }

    if (body.action === 'CANCEL') {
      const reason = typeof body.reason === 'string' ? body.reason.trim() : null
      const { data, error } = await caller.client.rpc('cancel_master_import_job', {
        p_job_id: id,
        p_master_version: masterVersion,
        p_reason: reason || null,
      })
      if (error) throwImportError(error)
      return Response.json({ data })
    }

    throw new ApiRouteError('INVALID_IMPORT_ACTION', 400)
  } catch (error) {
    return apiError(error)
  }
}
