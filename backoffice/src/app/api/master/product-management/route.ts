import { apiError, requireActiveCompany, requireCaller, requirePermissionCapability } from '@/lib/server-auth'
import { parseIncludeInactive, throwDatabaseError } from '@/lib/master-data'

const selectFields = `
  id,company_id,sku,name,category_id,uom_id,weight_reference_uom_id,
  weight_per_uom_kg,image_url,is_bundle,is_active,master_version,
  sales_tax_rule_id,purchase_tax_rule_id,created_at,updated_at,
  category:product_categories!fk_products_company_category(
    id,category_code,category_name,is_active,
    default_sales_tax_rule_id,default_purchase_tax_rule_id
  ),
  product_uoms:product_uoms!fk_product_uoms_company_product(
    id,uom_id,factor_to_base,purchase_allowed,sales_allowed,purchase_price,
    sale_price,barcode,is_active,conversion_version,master_version,
    uom:uoms!fk_product_uoms_company_uom(
      id,code,name,uom_type,allow_decimal,decimal_precision,is_active
    )
  )
`

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const permission = await requirePermissionCapability(
      caller, companyId, 'inventory.products', 'VIEW',
    )
    let query = caller.client.from('products').select(selectFields)
      .eq('company_id', companyId).eq('is_bundle', false).order('name').limit(200)
    if (!parseIncludeInactive(request)) query = query.eq('is_active', true)
    const { data, error } = await query
    if (error) throwDatabaseError(error)
    return Response.json({ companyId, permission, data: data ?? [] })
  } catch (error) { return apiError(error) }
}
