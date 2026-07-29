import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject, throwDatabaseError } from '@/lib/master-data'
import {
  parseStockAdjustmentBody,
  stockAdjustmentRpcArgs,
  throwStockAdjustmentRpcError,
} from '@/lib/stock-adjustment'

const documentFields = `
  id,company_id,document_no,warehouse_id,adjustment_date,status,notes,
  line_count,total_gain_quantity_base,total_loss_quantity_base,
  total_gain_value,total_loss_value,master_version,posted_at,canceled_at,
  created_at,updated_at
`
const lineFields = `
  id,company_id,document_id,line_no,product_id,base_uom_id,reason_id,
  system_quantity_snapshot,final_physical_quantity,calculated_difference,
  unit_cost_base,total_value,cost_override_reason,fifo_layer_count,
  product_sku_snapshot,product_name_snapshot,base_uom_name_snapshot,
  reason_name_snapshot,notes,created_at
`

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const { data: documents, error: documentError } = await caller.client
      .from('stock_adjustment_documents')
      .select(documentFields)
      .eq('company_id', companyId)
      .order('created_at', { ascending: false })
      .limit(500)
    if (documentError) throwDatabaseError(documentError)

    const documentIds = (documents ?? []).map((row) => row.id)
    const [
      { data: lines, error: lineError },
      { data: allocations, error: allocationError },
      { data: balances, error: balanceError },
      { data: movements, error: movementError },
      { data: reasons, error: reasonError },
    ] = await Promise.all([
      documentIds.length
        ? caller.client
            .from('stock_adjustment_lines')
            .select(lineFields)
            .eq('company_id', companyId)
            .in('document_id', documentIds)
            .order('line_no')
            .limit(10000)
        : Promise.resolve({ data: [], error: null }),
      documentIds.length
        ? caller.client
            .from('stock_adjustment_fifo_allocations')
            .select(
              'id,document_id,line_id,direction,quantity_base,unit_cost_base,total_value,created_at',
            )
            .eq('company_id', companyId)
            .in('document_id', documentIds)
            .order('created_at')
            .limit(20000)
        : Promise.resolve({ data: [], error: null }),
      caller.client
        .from('product_stocks')
        .select('product_id,warehouse_id,stock_qty,updated_at')
        .eq('company_id', companyId)
        .limit(10000),
      caller.client
        .from('stock_movements')
        .select(
          'id,product_id,warehouse_id,qty_change,movement_type,reference_id,balance_after_base_qty,posted_at',
        )
        .eq('company_id', companyId)
        .eq('reference_table', 'stock_adjustment_documents')
        .order('posted_at', { ascending: false })
        .limit(20000),
      caller.client
        .from('stock_adjustment_reasons')
        .select(
          'id,reason_name,direction_allowed,finance_treatment,is_active,master_version',
        )
        .eq('company_id', companyId)
        .order('reason_name')
        .limit(1000),
    ])
    if (lineError) throwDatabaseError(lineError)
    if (allocationError) throwDatabaseError(allocationError)
    if (balanceError) throwDatabaseError(balanceError)
    if (movementError) throwDatabaseError(movementError)
    if (reasonError) throwDatabaseError(reasonError)

    return Response.json({
      companyId,
      data: documents ?? [],
      lines: lines ?? [],
      allocations: allocations ?? [],
      balances: balances ?? [],
      movements: movements ?? [],
      reasons: reasons ?? [],
    })
  } catch (error) {
    return apiError(error)
  }
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const input = parseStockAdjustmentBody(await readJsonObject(request), false)
    const { data, error } = await caller.client.rpc(
      'save_stock_adjustment_document',
      stockAdjustmentRpcArgs(null, input),
    )
    if (error) throwStockAdjustmentRpcError(error)
    return Response.json({ data }, { status: 201 })
  } catch (error) {
    return apiError(error)
  }
}
