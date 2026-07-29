import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject, throwDatabaseError } from '@/lib/master-data'
import {
  parseStockTransferBody,
  stockTransferRpcArgs,
  throwStockTransferRpcError,
} from '@/lib/stock-transfer'

const documentFields = `
  id,company_id,document_no,source_warehouse_id,destination_warehouse_id,
  transfer_date,status,notes,line_count,total_quantity_base,total_cost,
  master_version,posted_at,canceled_at,created_at,updated_at
`

const lineFields = `
  id,company_id,document_id,line_no,product_id,base_uom_id,quantity_base,
  transferred_cost,fifo_layer_count,product_sku_snapshot,
  product_name_snapshot,base_uom_name_snapshot,notes,created_at
`

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const { data: documents, error: documentError } = await caller.client
      .from('stock_transfer_documents')
      .select(documentFields)
      .eq('company_id', companyId)
      .order('created_at', { ascending: false })
      .limit(500)
    if (documentError) throwDatabaseError(documentError)

    const documentIds = (documents ?? []).map((document) => document.id)
    const lineQuery = caller.client
      .from('stock_transfer_lines')
      .select(lineFields)
      .eq('company_id', companyId)
      .order('line_no')
      .limit(10000)
    const allocationQuery = caller.client
      .from('stock_transfer_fifo_allocations')
      .select(
        'id,document_id,line_id,quantity_base,unit_cost_base,total_cost,created_at',
      )
      .eq('company_id', companyId)
      .order('created_at')
      .limit(20000)

    const [
      { data: lines, error: lineError },
      { data: allocations, error: allocationError },
      { data: balances, error: balanceError },
      { data: movements, error: movementError },
    ] = await Promise.all([
      documentIds.length
        ? lineQuery.in('document_id', documentIds)
        : Promise.resolve({ data: [], error: null }),
      documentIds.length
        ? allocationQuery.in('document_id', documentIds)
        : Promise.resolve({ data: [], error: null }),
      caller.client
        .from('product_stocks')
        .select('product_id,warehouse_id,stock_qty,updated_at')
        .eq('company_id', companyId)
        .limit(10000),
      caller.client
        .from('stock_movements')
        .select(
          'id,product_id,warehouse_id,qty_change,movement_type,reference_table,reference_id,balance_after_base_qty,posted_at',
        )
        .eq('company_id', companyId)
        .eq('reference_table', 'stock_transfer_documents')
        .order('posted_at', { ascending: false })
        .limit(20000),
    ])
    if (lineError) throwDatabaseError(lineError)
    if (allocationError) throwDatabaseError(allocationError)
    if (balanceError) throwDatabaseError(balanceError)
    if (movementError) throwDatabaseError(movementError)

    return Response.json({
      companyId,
      data: documents ?? [],
      lines: lines ?? [],
      allocations: allocations ?? [],
      balances: balances ?? [],
      movements: movements ?? [],
    })
  } catch (error) {
    return apiError(error)
  }
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const input = parseStockTransferBody(await readJsonObject(request), false)
    const { data, error } = await caller.client.rpc(
      'save_stock_transfer_document',
      stockTransferRpcArgs(null, input),
    )
    if (error) throwStockTransferRpcError(error)
    return Response.json({ data }, { status: 201 })
  } catch (error) {
    return apiError(error)
  }
}
