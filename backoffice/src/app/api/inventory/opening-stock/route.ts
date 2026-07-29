import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject, throwDatabaseError } from '@/lib/master-data'
import {
  openingStockRpcArgs,
  parseOpeningStockBody,
  throwOpeningStockRpcError,
} from '@/lib/opening-stock'

const documentFields = `
  id,company_id,document_no,warehouse_id,effective_date,status,notes,
  line_count,total_quantity_base,total_cost,posting_idempotency_key,
  financial_event_id,master_version,created_by,updated_by,posted_by,
  posted_at,created_at,updated_at
`

const lineFields = `
  id,company_id,document_id,line_no,product_id,base_uom_id,quantity_base,
  unit_cost_base,total_cost,product_sku_snapshot,product_name_snapshot,
  base_uom_code_snapshot,base_uom_name_snapshot,zero_cost_reason,notes
`

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const { data: documents, error: documentError } = await caller.client
      .from('opening_stock_documents')
      .select(documentFields)
      .eq('company_id', companyId)
      .order('created_at', { ascending: false })
      .limit(200)
    if (documentError) throwDatabaseError(documentError)

    const documentIds = (documents ?? []).map((document) => document.id)
    const lineQuery = caller.client
      .from('opening_stock_lines')
      .select(lineFields)
      .eq('company_id', companyId)
      .order('line_no')
      .limit(5000)
    const { data: lines, error: lineError } = documentIds.length
      ? await lineQuery.in('document_id', documentIds)
      : { data: [], error: null }
    if (lineError) throwDatabaseError(lineError)

    const [
      { data: balances, error: balanceError },
      { data: movements, error: movementError },
      { data: batches, error: batchError },
    ] = await Promise.all([
      caller.client
        .from('product_stocks')
        .select('id,product_id,warehouse_id,stock_qty,updated_at')
        .eq('company_id', companyId)
        .limit(5000),
      caller.client
        .from('stock_movements')
        .select(
          'id,product_id,warehouse_id,qty_change,movement_type,reference_table,reference_id,created_at',
        )
        .eq('company_id', companyId)
        .order('created_at', { ascending: false })
        .limit(10000),
      caller.client
        .from('product_batches')
        .select(
          'id,product_id,warehouse_id,qty_purchased,qty_remaining,cogs_unit,opening_stock_line_id,created_at',
        )
        .eq('company_id', companyId)
        .not('opening_stock_line_id', 'is', null)
        .limit(5000),
    ])
    if (balanceError) throwDatabaseError(balanceError)
    if (movementError) throwDatabaseError(movementError)
    if (batchError) throwDatabaseError(batchError)

    return Response.json({
      companyId,
      data: documents ?? [],
      lines: lines ?? [],
      balances: balances ?? [],
      movements: movements ?? [],
      batches: batches ?? [],
    })
  } catch (error) {
    return apiError(error)
  }
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const input = parseOpeningStockBody(await readJsonObject(request), false)
    const { data, error } = await caller.client.rpc(
      'save_opening_stock_document',
      openingStockRpcArgs(null, input),
    )
    if (error) throwOpeningStockRpcError(error)
    return Response.json({ data }, { status: 201 })
  } catch (error) {
    return apiError(error)
  }
}
