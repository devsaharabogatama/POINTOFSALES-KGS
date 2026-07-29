import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { parseIncludeInactive, readJsonObject, throwDatabaseError } from '@/lib/master-data'
import { bundleRpcArgs, parseBundleBody, throwBundleRpcError } from '@/lib/bundle-master'

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    let bundleQuery = caller.client
      .from('products')
      .select(`
        id,company_id,sku,name,category_id,uom_id,weight_reference_uom_id,
        weight_per_uom_kg,image_url,is_active,master_version,created_at,updated_at
      `)
      .eq('company_id', companyId)
      .eq('is_bundle', true)
      .order('name')
      .limit(200)
    if (!parseIncludeInactive(request)) bundleQuery = bundleQuery.eq('is_active', true)

    const { data: bundles, error: bundleError } = await bundleQuery
    if (bundleError) throwDatabaseError(bundleError)
    const bundleIds = (bundles ?? []).map((bundle) => bundle.id)
    if (bundleIds.length === 0) {
      return Response.json({ companyId, data: [], components: [], salesUoms: [] })
    }

    const [componentResult, uomResult] = await Promise.all([
      caller.client
        .from('product_bundle_items')
        .select('id,bundle_id,item_id,component_uom_id,component_qty,line_no,master_version')
        .eq('company_id', companyId)
        .in('bundle_id', bundleIds)
        .order('line_no'),
      caller.client
        .from('product_uoms')
        .select('id,product_id,uom_id,factor_to_base,sales_allowed,sale_price,barcode,is_active')
        .eq('company_id', companyId)
        .in('product_id', bundleIds),
    ])
    if (componentResult.error) throwDatabaseError(componentResult.error)
    if (uomResult.error) throwDatabaseError(uomResult.error)

    return Response.json({
      companyId,
      data: bundles ?? [],
      components: componentResult.data ?? [],
      salesUoms: uomResult.data ?? [],
    })
  } catch (error) {
    return apiError(error)
  }
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const input = parseBundleBody(await readJsonObject(request), false)
    const { data, error } = await caller.client.rpc(
      'save_bundle_with_components',
      bundleRpcArgs(null, input),
    )
    if (error) throwBundleRpcError(error)
    return Response.json({ data }, { status: 201 })
  } catch (error) {
    return apiError(error)
  }
}
