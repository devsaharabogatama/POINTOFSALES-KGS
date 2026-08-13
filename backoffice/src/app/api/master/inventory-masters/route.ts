import { apiError, requireActiveCompany, requireCaller, requirePermissionCapability } from '@/lib/server-auth'
import { parseIncludeInactive, throwDatabaseError } from '@/lib/master-data'

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const permission = await requirePermissionCapability(
      caller, companyId, 'inventory.master_data', 'VIEW',
    )
    const includeInactive = parseIncludeInactive(request)
    const now = new Date().toISOString()
    let categories = caller.client.from('product_categories')
      .select('id,company_id,category_code,category_name,is_active,master_version,default_sales_tax_rule_id,default_purchase_tax_rule_id,created_at,updated_at')
      .eq('company_id', companyId).order('category_name').limit(200)
    let uoms = caller.client.from('uoms')
      .select('id,company_id,code,name,uom_type,allow_decimal,decimal_precision,is_active,master_version,created_at,updated_at')
      .eq('company_id', companyId).order('name').limit(200)
    let warehouses = caller.client.from('warehouses')
      .select('id,company_id,code,name,warehouse_type,store_id,location,is_sale_source,is_purchase_destination,allow_negative_stock,is_active,master_version,created_at,updated_at')
      .eq('company_id', companyId).order('name').limit(200)
    if (!includeInactive) {
      categories = categories.eq('is_active', true)
      uoms = uoms.eq('is_active', true)
      warehouses = warehouses.eq('is_active', true)
    }
    const [categoryResult,uomResult,warehouseResult,ruleResult,versionResult,featureResult] = await Promise.all([
      categories,uoms,warehouses,
      caller.client.from('tax_rules').select('id,tax_name,tax_scope,is_active')
        .eq('company_id',companyId).eq('is_active',true).order('tax_name'),
      caller.client.from('tax_rule_versions').select('tax_rule_id,rate_percent,effective_from,effective_to,status')
        .eq('company_id',companyId).eq('status','ACTIVE').lte('effective_from',now)
        .or(`effective_to.is.null,effective_to.gt.${now}`),
      caller.client.from('company_features').select('feature_code,is_enabled')
        .eq('company_id',companyId).in('feature_code',['tax_sales_enabled','tax_purchase_enabled']),
    ])
    for (const result of [categoryResult,uomResult,warehouseResult,ruleResult,versionResult,featureResult]) {
      if (result.error) throwDatabaseError(result.error)
    }
    const versions = new Map((versionResult.data ?? []).map((row)=>[row.tax_rule_id,row]))
    const features = new Map((featureResult.data ?? []).map((row)=>[row.feature_code,row.is_enabled]))
    return Response.json({companyId,permission,categories:categoryResult.data??[],uoms:uomResult.data??[],warehouses:warehouseResult.data??[],taxRules:(ruleResult.data??[]).filter((row)=>versions.has(row.id)).map((row)=>({id:row.id,name:row.tax_name,scope:row.tax_scope,ratePercent:versions.get(row.id)?.rate_percent??0})),entitlements:{salesEnabled:features.get('tax_sales_enabled')===true,purchaseEnabled:features.get('tax_purchase_enabled')===true}})
  } catch (error) { return apiError(error) }
}
