import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { throwDatabaseError } from '@/lib/master-data'

const documentFields = `
  id,company_id,store_id,deposit_no,destination_type,
  destination_name_snapshot,actual_deposit_amount,total_expected_deposit,
  deposit_variance,variance_type,deposit_at,evidence_url,notes,status,
  proof_mode_snapshot,master_version,created_by,submitted_by,approved_by,
  rejected_by,canceled_by,created_at,updated_at,submitted_at,approved_at,
  rejected_at,canceled_at,rejection_reason,cancel_reason,financial_event_id
`

const lineFields = `
  id,deposit_document_id,store_id,cashier_session_id,line_no,
  session_code_snapshot,cashier_id,cashier_name_snapshot,
  closing_cash_actual_snapshot,next_session_float_reserved,
  posted_deposit_allocations_snapshot,expected_deposit_amount,
  allocation_status
`

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const status = new URL(request.url).searchParams
      .get('status')?.trim().toUpperCase()

    let query = caller.client
      .from('cash_deposit_documents')
      .select(documentFields)
      .eq('company_id', companyId)
      .order('created_at', { ascending: false })
      .limit(500)
    if (status && [
      'DRAFT', 'SUBMITTED', 'APPROVED', 'REJECTED', 'CANCELED',
    ].includes(status)) query = query.eq('status', status)
    const { data: documents, error } = await query
    if (error) throwDatabaseError(error)

    const documentIds = (documents ?? []).map((row) => row.id)
    const storeIds = [...new Set((documents ?? []).map((row) => row.store_id))]
    const actorIds = [...new Set((documents ?? []).flatMap((row) => [
      row.created_by, row.submitted_by, row.approved_by,
      row.rejected_by, row.canceled_by,
    ]).filter((value): value is string => Boolean(value)))]
    const [lines, stores, actors] = await Promise.all([
      documentIds.length
        ? caller.client.from('cash_deposit_session_lines')
            .select(lineFields).eq('company_id', companyId)
            .in('deposit_document_id', documentIds).order('line_no')
        : Promise.resolve({ data: [], error: null }),
      storeIds.length
        ? caller.client.from('stores').select('id,store_name')
            .eq('company_id', companyId).in('id', storeIds)
        : Promise.resolve({ data: [], error: null }),
      actorIds.length
        ? caller.client.from('profiles').select('id,name').in('id', actorIds)
        : Promise.resolve({ data: [], error: null }),
    ])
    for (const result of [lines, stores, actors]) {
      if (result.error) throwDatabaseError(result.error)
    }
    return Response.json({
      companyId,
      data: documents ?? [],
      lines: lines.data ?? [],
      stores: stores.data ?? [],
      actors: actors.data ?? [],
    })
  } catch (error) {
    return apiError(error)
  }
}
