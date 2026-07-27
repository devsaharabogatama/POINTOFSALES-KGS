import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { parseIncludeInactive, readJsonObject, throwDatabaseError } from '@/lib/master-data'
import { parsePricelistBody, pricelistRpcArgs, throwPricelistRpcError } from '@/lib/pricelist-master'

const headerFields = `id,company_id,code,name,scope,customer_id,priority,is_default,
  applies_all_stores,valid_from,valid_until,is_active,notes,master_version,created_at,updated_at`
const ruleFields = `id,pricelist_id,product_id,product_uom_id,min_qty,tier_qty_basis,
  pricing_method,fixed_unit_price,discount_amount_per_unit,discount_percent,
  valid_from,valid_until,is_active,rule_version,master_version`

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    let headerQuery = caller.client.from('pricelists').select(headerFields)
      .eq('company_id', companyId).order('priority', { ascending: false }).order('name').limit(300)
    if (!parseIncludeInactive(request)) headerQuery = headerQuery.eq('is_active', true)

    const [headersResult, assignmentsResult, rulesResult, storesResult] = await Promise.all([
      headerQuery,
      caller.client.from('pricelist_store_assignments').select('id,pricelist_id,store_id')
        .eq('company_id', companyId).limit(1000),
      caller.client.from('pricelist_rules').select(ruleFields)
        .eq('company_id', companyId).eq('is_active', true).order('min_qty', { ascending: false }).limit(2000),
      caller.client.from('stores').select('id,store_code,store_name,status')
        .eq('company_id', companyId).eq('status', 'ACTIVE').order('store_name').limit(300),
    ])
    for (const result of [headersResult, assignmentsResult, rulesResult, storesResult]) {
      if (result.error) throwDatabaseError(result.error)
    }
    const assignments = assignmentsResult.data ?? []
    const rules = rulesResult.data ?? []
    const data = (headersResult.data ?? []).map((header) => ({
      ...header,
      store_assignments: assignments.filter((row) => row.pricelist_id === header.id),
      rules: rules.filter((row) => row.pricelist_id === header.id),
    }))
    return Response.json({ companyId, data, stores: storesResult.data ?? [] })
  } catch (error) {
    return apiError(error)
  }
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const input = parsePricelistBody(await readJsonObject(request), false)
    const { data, error } = await caller.client.rpc(
      'save_reusable_pricelist_with_rules', pricelistRpcArgs(null, input),
    )
    if (error) throwPricelistRpcError(error)
    return Response.json({ data }, { status: 201 })
  } catch (error) {
    return apiError(error)
  }
}
