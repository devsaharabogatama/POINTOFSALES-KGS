import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { throwDatabaseError } from '@/lib/master-data'

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const [
      { data: movements, error: movementError },
      { data: products, error: productError },
      { data: warehouses, error: warehouseError },
      { data: openingDocuments, error: openingDocumentError },
      { data: transferDocuments, error: transferDocumentError },
      { data: adjustmentDocuments, error: adjustmentDocumentError },
    ] = await Promise.all([
      caller.client
        .from('stock_movements')
        .select(
          'id,product_id,warehouse_id,qty_change,movement_type,reference_table,reference_id,created_at,base_uom_name_snapshot,balance_after_base_qty,actor_id,posted_at,movement_status,notes',
        )
        .eq('company_id', companyId)
        .order('posted_at', { ascending: false, nullsFirst: false })
        .order('created_at', { ascending: false })
        .limit(20000),
      caller.client
        .from('products')
        .select('id,sku,name,is_active')
        .eq('company_id', companyId)
        .order('name')
        .limit(10000),
      caller.client
        .from('warehouses')
        .select('id,name,warehouse_type,location,is_active')
        .eq('company_id', companyId)
        .order('name')
        .limit(5000),
      caller.client
        .from('opening_stock_documents')
        .select('id,document_no,status')
        .eq('company_id', companyId)
        .limit(10000),
      caller.client
        .from('stock_transfer_documents')
        .select('id,document_no,status')
        .eq('company_id', companyId)
        .limit(10000),
      caller.client
        .from('stock_adjustment_documents')
        .select('id,document_no,status')
        .eq('company_id', companyId)
        .limit(10000),
    ])

    if (movementError) throwDatabaseError(movementError)
    if (productError) throwDatabaseError(productError)
    if (warehouseError) throwDatabaseError(warehouseError)
    if (openingDocumentError) throwDatabaseError(openingDocumentError)
    if (transferDocumentError) throwDatabaseError(transferDocumentError)
    if (adjustmentDocumentError) throwDatabaseError(adjustmentDocumentError)

    const actorIds = Array.from(
      new Set(
        (movements ?? [])
          .map((movement) => movement.actor_id)
          .filter((actorId): actorId is string => Boolean(actorId)),
      ),
    )
    let actors: { id: string; name: string }[] = []
    if (actorIds.length) {
      const { data, error } = await caller.client
        .from('profiles')
        .select('id,name')
        .in('id', actorIds)
      if (error) throwDatabaseError(error)
      actors = data ?? []
    }

    return Response.json({
      companyId,
      data: movements ?? [],
      products: products ?? [],
      warehouses: warehouses ?? [],
      openingDocuments: openingDocuments ?? [],
      transferDocuments: transferDocuments ?? [],
      adjustmentDocuments: adjustmentDocuments ?? [],
      actors,
    })
  } catch (error) {
    return apiError(error)
  }
}
