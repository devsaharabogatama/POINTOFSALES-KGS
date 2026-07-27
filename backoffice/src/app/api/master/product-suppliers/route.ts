import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { parseIncludeInactive, readJsonObject, throwDatabaseError } from '@/lib/master-data'
import {
  parseProductSupplierBody,
  productSupplierRpcArgs,
  throwSupplierRpcError,
} from '@/lib/supplier-master'

const selectFields = `
  id,company_id,product_id,supplier_id,purchase_uom_id,supplier_product_code,
  reference_purchase_price,last_purchase_price,is_preferred_supplier,is_active,
  last_price_updated_at,master_version,created_at,updated_at
`

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    let query = caller.client
      .from('product_suppliers')
      .select(selectFields)
      .eq('company_id', companyId)
      .order('created_at')
      .limit(500)
    if (!parseIncludeInactive(request)) query = query.eq('is_active', true)
    const { data, error } = await query
    if (error) throwDatabaseError(error)
    return Response.json({ companyId, data: data ?? [] })
  } catch (error) {
    return apiError(error)
  }
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const input = parseProductSupplierBody(await readJsonObject(request), false)
    const { data, error } = await caller.client.rpc(
      'save_product_supplier',
      productSupplierRpcArgs(null, input),
    )
    if (error) throwSupplierRpcError(error)
    return Response.json({ data }, { status: 201 })
  } catch (error) {
    return apiError(error)
  }
}
