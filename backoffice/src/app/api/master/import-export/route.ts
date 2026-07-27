import { ApiRouteError, apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { csvDocument, importDefinitions, isImportType } from '@/lib/master-import'
import { requireImportManager, throwImportError } from '@/lib/master-import-server'

function csvResponse(content: string, fileName: string) {
  return new Response(content, {
    headers: {
      'Content-Type': 'text/csv; charset=utf-8',
      'Content-Disposition': `attachment; filename="${fileName}"`,
      'Cache-Control': 'no-store',
    },
  })
}

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    await requireImportManager(caller, companyId)
    const url = new URL(request.url)
    const importType = url.searchParams.get('type')
    const kind = url.searchParams.get('kind') ?? 'data'
    if (!isImportType(importType)) throw new ApiRouteError('UNSUPPORTED_IMPORT_TYPE', 400)
    if (!['data', 'template'].includes(kind)) throw new ApiRouteError('INVALID_EXPORT_KIND', 400)
    const definition = importDefinitions[importType]
    if (kind === 'template') {
      return csvResponse(csvDocument(definition.templateHeaders, []), `template-${importType.toLowerCase()}.csv`)
    }

    let result
    let rows: Record<string, unknown>[] = []
    if (importType === 'PRODUCT_CATEGORY') {
      result = await caller.client.from('product_categories')
        .select('id,category_name,is_active')
        .eq('company_id', companyId).order('category_name').limit(5000)
      rows = (result.data ?? []).map((row) => ({
        internal_id: row.id, name: row.category_name,
        is_active: row.is_active,
      }))
    } else if (importType === 'UOM') {
      result = await caller.client.from('uoms')
        .select('id,name,uom_type,allow_decimal,decimal_precision,is_active')
        .eq('company_id', companyId).order('name').limit(5000)
      rows = (result.data ?? []).map((row) => ({
        internal_id: row.id, name: row.name, uom_type: row.uom_type,
        allow_decimal: row.allow_decimal, decimal_precision: row.decimal_precision,
        is_active: row.is_active,
      }))
    } else if (importType === 'WAREHOUSE') {
      const [warehouseResult, storeResult] = await Promise.all([
        caller.client.from('warehouses')
          .select('id,name,warehouse_type,store_id,location,is_sale_source,is_purchase_destination,is_active')
          .eq('company_id', companyId).order('name').limit(5000),
        caller.client.from('stores').select('id,store_code,store_name')
          .eq('company_id', companyId).order('store_name').limit(5000),
      ])
      result = warehouseResult
      if (storeResult.error) throwImportError(storeResult.error)
      const storeNames = new Map((storeResult.data ?? []).map((store) => [
        store.id,
        `${store.store_name} (${store.store_code})`,
      ]))
      rows = (result.data ?? []).map((row) => ({
        internal_id: row.id, name: row.name,
        warehouse_type: row.warehouse_type,
        store_name: row.store_id ? storeNames.get(row.store_id) ?? '' : '',
        location: row.location, is_sale_source: row.is_sale_source,
        is_purchase_destination: row.is_purchase_destination, is_active: row.is_active,
      }))
    } else if (importType === 'SUPPLIER') {
      result = await caller.client.from('suppliers')
        .select('id,supplier_name,contact_name,phone,address,npwp,payment_term,bank_name,bank_account_number,bank_account_holder,is_active')
        .eq('company_id', companyId).order('supplier_name').limit(5000)
      rows = (result.data ?? []).map((row) => ({
        internal_id: row.id, name: row.supplier_name,
        contact_name: row.contact_name, phone: row.phone, address: row.address,
        npwp: row.npwp, payment_term: row.payment_term, bank_name: row.bank_name,
        bank_account_number: row.bank_account_number,
        bank_account_holder: row.bank_account_holder, is_active: row.is_active,
      }))
    } else if (importType === 'CUSTOMER_CATEGORY') {
      result = await caller.client.from('customer_categories')
        .select('id,category_name,is_active')
        .eq('company_id', companyId).order('category_name').limit(5000)
      rows = (result.data ?? []).map((row) => ({
        internal_id: row.id,
        name: row.category_name,
        is_active: row.is_active,
      }))
    } else if (importType === 'CHART_OF_ACCOUNT') {
      result = await caller.client.from('chart_of_accounts')
        .select('id,account_code,account_name,account_type,normal_balance,parent_account_id,system_function_key,is_postable,allow_manual_posting,allow_reconciliation,is_active')
        .eq('company_id', companyId).order('account_code').limit(5000)
      const accountCodes = new Map((result.data ?? []).map((row) => [
        row.id,
        row.account_code,
      ]))
      rows = (result.data ?? []).map((row) => ({
        internal_id: row.id,
        code: row.account_code,
        name: row.account_name,
        account_type: row.account_type,
        normal_balance: row.normal_balance,
        parent_account_code: row.parent_account_id
          ? accountCodes.get(row.parent_account_id) ?? ''
          : '',
        system_function_key: row.system_function_key,
        is_postable: row.is_postable,
        allow_manual_posting: row.allow_manual_posting,
        allow_reconciliation: row.allow_reconciliation,
        is_active: row.is_active,
      }))
    } else {
      result = await caller.client.from('transaction_categories')
        .select('id,category_name,system_key,description,is_active')
        .eq('company_id', companyId).order('category_name').limit(5000)
      rows = (result.data ?? []).map((row) => ({
        internal_id: row.id,
        name: row.category_name,
        system_key: row.system_key,
        description: row.description,
        is_active: row.is_active,
      }))
    }
    if (result.error) throwImportError(result.error)
    return csvResponse(
      csvDocument(definition.exportHeaders, rows),
      `export-${importType.toLowerCase()}-${new Date().toISOString().slice(0, 10)}.csv`,
    )
  } catch (error) {
    return apiError(error)
  }
}
