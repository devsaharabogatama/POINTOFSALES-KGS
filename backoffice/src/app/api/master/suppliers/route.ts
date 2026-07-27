import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { parseIncludeInactive, readJsonObject, throwDatabaseError } from '@/lib/master-data'
import { parseSupplierBody, supplierRpcArgs, throwSupplierRpcError } from '@/lib/supplier-master'

const selectFields = `
  id,company_id,supplier_code,supplier_name,contact_name,phone,address,npwp,
  payment_term,bank_name,bank_account_number,bank_account_holder,is_active,
  master_version,created_at,updated_at
`

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    let query = caller.client
      .from('suppliers')
      .select(selectFields)
      .eq('company_id', companyId)
      .order('supplier_name')
      .limit(300)
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
    const input = parseSupplierBody(await readJsonObject(request), false)
    const { data, error } = await caller.client.rpc('save_supplier', supplierRpcArgs(null, input))
    if (error) throwSupplierRpcError(error)
    return Response.json({ data }, { status: 201 })
  } catch (error) {
    return apiError(error)
  }
}
