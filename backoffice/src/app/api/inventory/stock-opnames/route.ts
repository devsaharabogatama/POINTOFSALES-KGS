import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { throwDatabaseError } from '@/lib/master-data'

const headerFields = `
  id,company_id,opname_no,warehouse_id,status,notes,created_by,created_at,
  scope_type,category_id,count_started_at,movement_watermark_at,
  completed_by,completed_at,reviewed_by,reviewed_at,
  adjustment_document_id,posted_by,posted_at,canceled_by,canceled_at,
  master_version,updated_at
`
const detailFields = `
  id,company_id,opname_id,product_id,system_qty,physical_qty,difference,notes,
  line_status,base_uom_id,system_qty_at_start,expected_qty_at_count,
  variance_at_count,count_started_at,counted_at,counter_id,
  movement_watermark_at,superseded_by_line_id,recount_requested_by,
  recount_requested_at,adjustment_line_id,product_sku_snapshot,
  product_name_snapshot,base_uom_name_snapshot
`

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const { data: sessions, error: sessionError } = await caller.client
      .from('stock_opnames')
      .select(headerFields)
      .eq('company_id', companyId)
      .order('created_at', { ascending: false })
      .limit(500)
    if (sessionError) throwDatabaseError(sessionError)

    const sessionIds = (sessions ?? []).map((row) => row.id)
    const [
      { data: details, error: detailError },
      { data: attempts, error: attemptError },
      { data: warehouses, error: warehouseError },
      { data: adjustments, error: adjustmentError },
    ] = await Promise.all([
      sessionIds.length
        ? caller.client
            .from('stock_opname_details')
            .select(detailFields)
            .eq('company_id', companyId)
            .in('opname_id', sessionIds)
            .order('product_name_snapshot')
            .limit(20000)
        : Promise.resolve({ data: [], error: null }),
      sessionIds.length
        ? caller.client
            .from('stock_opname_count_attempts')
            .select(
              'id,opname_id,opname_detail_id,attempt_no,physical_qty,count_started_at,counted_at,counter_id,movement_count_in_window,result_status,notes',
            )
            .eq('company_id', companyId)
            .in('opname_id', sessionIds)
            .order('attempt_no')
            .limit(30000)
        : Promise.resolve({ data: [], error: null }),
      caller.client
        .from('warehouses')
        .select('id,name,warehouse_type,location,store_id,is_active')
        .eq('company_id', companyId)
        .limit(2000),
      caller.client
        .from('stock_adjustment_documents')
        .select(
          'id,document_no,status,total_gain_quantity_base,total_loss_quantity_base,total_gain_value,total_loss_value,posted_at',
        )
        .eq('company_id', companyId)
        .limit(5000),
    ])
    if (detailError) throwDatabaseError(detailError)
    if (attemptError) throwDatabaseError(attemptError)
    if (warehouseError) throwDatabaseError(warehouseError)
    if (adjustmentError) throwDatabaseError(adjustmentError)

    const actorIds = new Set<string>()
    for (const session of sessions ?? []) {
      for (const id of [
        session.created_by,
        session.completed_by,
        session.reviewed_by,
        session.posted_by,
        session.canceled_by,
      ]) {
        if (id) actorIds.add(id)
      }
    }
    for (const detail of details ?? []) {
      for (const id of [detail.counter_id, detail.recount_requested_by]) {
        if (id) actorIds.add(id)
      }
    }
    const { data: actors, error: actorError } = actorIds.size
      ? await caller.client
          .from('profiles')
          .select('id,name')
          .in('id', [...actorIds])
          .limit(5000)
      : { data: [], error: null }
    if (actorError) throwDatabaseError(actorError)

    return Response.json({
      companyId,
      data: sessions ?? [],
      details: details ?? [],
      attempts: attempts ?? [],
      warehouses: warehouses ?? [],
      adjustments: adjustments ?? [],
      actors: actors ?? [],
    })
  } catch (error) {
    return apiError(error)
  }
}
