import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { throwDatabaseError } from '@/lib/master-data'

const documentFields = `
  id,company_id,return_no,source_sales_id,source_invoice_no_snapshot,store_id,
  source_session_id,executing_session_id,customer_id,status,
  approval_mode_snapshot,notes,refund_before_rounding,rounding_direction,
  rounding_adjustment,refund_total,master_version,created_by,created_at,
  updated_at,posted_by,posted_at,canceled_by,canceled_at,cancel_reason,
  financial_event_id
`
const lineFields = `
  id,document_id,source_sales_detail_id,product_sku_snapshot,
  product_name_snapshot,sale_uom_name_snapshot,quantity_uom,quantity_base,
  return_condition,destination_warehouse_id,refund_before_rounding,
  tax_refund_amount,fifo_cost_restored
`
const refundFields = `
  id,document_id,payment_method_name_snapshot,payment_method_type_snapshot,
  amount,transfer_destination,transfer_reference,proof_url
`

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const url = new URL(request.url)
    const status = url.searchParams.get('status')?.trim().toUpperCase()

    let documentQuery = caller.client
      .from('sales_return_documents')
      .select(documentFields)
      .eq('company_id', companyId)
      .order('created_at', { ascending: false })
      .limit(500)
    if (status && ['DRAFT', 'POSTED', 'CANCELED'].includes(status)) {
      documentQuery = documentQuery.eq('status', status)
    }
    const { data: documents, error: documentError } = await documentQuery
    if (documentError) throwDatabaseError(documentError)
    const documentIds = (documents ?? []).map((row) => row.id)

    const [lineResult, refundResult] = await Promise.all([
      documentIds.length
        ? caller.client
            .from('sales_return_lines')
            .select(lineFields)
            .eq('company_id', companyId)
            .in('document_id', documentIds)
            .order('product_name_snapshot')
            .limit(10000)
        : Promise.resolve({ data: [], error: null }),
      documentIds.length
        ? caller.client
            .from('sales_return_refunds')
            .select(refundFields)
            .eq('company_id', companyId)
            .in('document_id', documentIds)
            .order('created_at')
            .limit(5000)
        : Promise.resolve({ data: [], error: null }),
    ])
    if (lineResult.error) throwDatabaseError(lineResult.error)
    if (refundResult.error) throwDatabaseError(refundResult.error)

    const customerIds = new Set((documents ?? []).map((row) => row.customer_id))
    const storeIds = new Set((documents ?? []).map((row) => row.store_id))
    const sessionIds = new Set(
      (documents ?? []).flatMap((row) => [row.source_session_id, row.executing_session_id]),
    )
    const actorIds = new Set(
      (documents ?? [])
        .flatMap((row) => [row.created_by, row.posted_by, row.canceled_by])
        .filter(Boolean),
    )
    const warehouseIds = new Set(
      (lineResult.data ?? []).map((row) => row.destination_warehouse_id).filter(Boolean),
    )

    const [customers, stores, sessions, actors, warehouses] = await Promise.all([
      customerIds.size
        ? caller.client.from('customers').select('id,name').eq('company_id', companyId).in('id', [...customerIds])
        : Promise.resolve({ data: [], error: null }),
      storeIds.size
        ? caller.client.from('stores').select('id,store_name').eq('company_id', companyId).in('id', [...storeIds])
        : Promise.resolve({ data: [], error: null }),
      sessionIds.size
        ? caller.client.from('cashier_sessions').select('id,session_code,status').eq('company_id', companyId).in('id', [...sessionIds])
        : Promise.resolve({ data: [], error: null }),
      actorIds.size
        ? caller.client.from('profiles').select('id,name').in('id', [...actorIds])
        : Promise.resolve({ data: [], error: null }),
      warehouseIds.size
        ? caller.client.from('warehouses').select('id,name,warehouse_type').eq('company_id', companyId).in('id', [...warehouseIds])
        : Promise.resolve({ data: [], error: null }),
    ])
    for (const result of [customers, stores, sessions, actors, warehouses]) {
      if (result.error) throwDatabaseError(result.error)
    }

    return Response.json({
      companyId,
      data: documents ?? [],
      lines: lineResult.data ?? [],
      refunds: refundResult.data ?? [],
      customers: customers.data ?? [],
      stores: stores.data ?? [],
      sessions: sessions.data ?? [],
      actors: actors.data ?? [],
      warehouses: warehouses.data ?? [],
    })
  } catch (error) {
    return apiError(error)
  }
}
