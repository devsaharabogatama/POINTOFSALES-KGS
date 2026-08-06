import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject, throwDatabaseError } from '@/lib/master-data'
import { parseSupplierOrderBody, supplierOrderRpcArgs, throwSupplierOrderError } from '@/lib/supplier-order'

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const results = await Promise.all([
      caller.client.from('stock_request_documents').select('id,request_no,store_id,needed_date,notes,status,line_count,requested_total_base_qty,master_version,requested_at').eq('company_id', companyId).in('status', ['SUBMITTED','ORDERED']).order('requested_at', { ascending: false }).limit(500),
      caller.client.from('stock_request_lines').select('id,document_id,line_no,product_id,requested_uom_id,requested_qty,factor_to_base_snapshot,requested_base_qty,product_sku_snapshot,product_name_snapshot,requested_uom_name_snapshot,notes').eq('company_id', companyId).order('line_no').limit(10000),
      caller.client.from('supplier_order_documents').select('id,order_no,store_id,destination_warehouse_id,supplier_id,order_date,expected_date,status,notes,line_count,total_ordered_base_qty,estimated_total,master_version,created_at').eq('company_id', companyId).order('created_at', { ascending: false }).limit(500),
      caller.client.from('supplier_order_lines').select('id,document_id,line_no,product_id,ordered_uom_id,ordered_qty,ordered_base_qty,estimated_unit_price,estimated_subtotal,product_name_snapshot,ordered_uom_name_snapshot').eq('company_id', companyId).order('line_no').limit(10000),
      caller.client.from('supplier_order_request_allocations').select('id,supplier_order_line_id,stock_request_line_id,allocated_base_qty').eq('company_id', companyId).limit(20000),
      caller.client.from('suppliers').select('id,supplier_name,is_active').eq('company_id', companyId).eq('is_active', true).order('supplier_name'),
      caller.client.from('warehouses').select('id,name,store_id,is_purchase_destination,is_active').eq('company_id', companyId).eq('is_active', true).eq('is_purchase_destination', true).order('name'),
      caller.client.from('stores').select('id,store_name,status').eq('company_id', companyId).eq('status', 'ACTIVE').order('store_name'),
      caller.client.from('product_suppliers').select('product_id,supplier_id,purchase_uom_id,reference_purchase_price,last_purchase_price,is_preferred_supplier,is_active').eq('company_id', companyId).eq('is_active', true),
      caller.client.from('product_uoms').select('product_id,uom_id,purchase_price').eq('company_id', companyId).eq('is_active', true).eq('purchase_allowed', true),
    ])
    for (const result of results) if (result.error) throwDatabaseError(result.error)
    return Response.json({ companyId, requests: results[0].data ?? [], requestLines: results[1].data ?? [], orders: results[2].data ?? [], orderLines: results[3].data ?? [], allocations: results[4].data ?? [], suppliers: results[5].data ?? [], warehouses: results[6].data ?? [], stores: results[7].data ?? [], productSuppliers: results[8].data ?? [], purchaseUoms: results[9].data ?? [] })
  } catch (error) { return apiError(error) }
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const input = parseSupplierOrderBody(await readJsonObject(request))
    const { data, error } = await caller.client.rpc('save_supplier_order', supplierOrderRpcArgs(null, input))
    if (error) throwSupplierOrderError(error)
    return Response.json({ data }, { status: 201 })
  } catch (error) { return apiError(error) }
}
