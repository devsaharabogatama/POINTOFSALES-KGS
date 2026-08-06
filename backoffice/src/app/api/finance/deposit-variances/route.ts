import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { throwDatabaseError } from '@/lib/master-data'

const exceptionFields = `
  id,store_id,cash_deposit_document_id,variance_type,original_amount,
  resolved_amount,remaining_amount,status,responsible_party_type,
  responsible_party_id,responsible_party_reason,responsible_party_assigned_by,
  responsible_party_assigned_at,opened_at,master_version,created_by,updated_by,
  created_at,updated_at,resolved_by,resolved_at,written_off_by,written_off_at
`
const requestFields = `
  id,variance_exception_id,request_no,allocation_amount,resolution_type,
  settlement_account_function,reason,evidence_url,resolution_reference,status,
  requires_review,allocation_id,financial_event_id,created_by,reviewed_by,
  created_at,reviewed_at,rejection_reason,master_version
`
const allocationFields = `
  id,variance_exception_id,allocation_amount,resolution_type,reason,evidence_url,
  resolution_reference,account_function_snapshot,submitted_by,submitted_at,
  reviewed_by,reviewed_at,created_at
`

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const { data: exceptions, error } = await caller.client
      .from('deposit_variance_exceptions')
      .select(exceptionFields)
      .eq('company_id', companyId)
      .order('opened_at', { ascending: false })
      .limit(500)
    if (error) throwDatabaseError(error)

    const exceptionIds = (exceptions ?? []).map((row) => row.id)
    const documentIds = [...new Set((exceptions ?? []).map(
      (row) => row.cash_deposit_document_id,
    ))]
    const storeIds = [...new Set((exceptions ?? []).map((row) => row.store_id))]

    const [requests, allocations, documents, stores, memberships] = await Promise.all([
      exceptionIds.length
        ? caller.client.from('deposit_variance_resolution_requests')
            .select(requestFields).eq('company_id', companyId)
            .in('variance_exception_id', exceptionIds)
            .order('created_at', { ascending: false })
        : Promise.resolve({ data: [], error: null }),
      exceptionIds.length
        ? caller.client.from('deposit_variance_allocations')
            .select(allocationFields).eq('company_id', companyId)
            .in('variance_exception_id', exceptionIds)
            .order('created_at', { ascending: false })
        : Promise.resolve({ data: [], error: null }),
      documentIds.length
        ? caller.client.from('cash_deposit_documents')
            .select(`id,deposit_no,destination_type,destination_name_snapshot,
              total_expected_deposit,actual_deposit_amount,deposit_variance,
              deposit_at,evidence_url,approved_at`)
            .eq('company_id', companyId).in('id', documentIds)
        : Promise.resolve({ data: [], error: null }),
      storeIds.length
        ? caller.client.from('stores').select('id,store_name')
            .eq('company_id', companyId).in('id', storeIds)
        : Promise.resolve({ data: [], error: null }),
      caller.client.from('company_memberships')
        .select('user_id,role_code').eq('company_id', companyId)
        .eq('status', 'ACTIVE').order('role_code'),
    ])
    for (const result of [requests, allocations, documents, stores, memberships]) {
      if (result.error) throwDatabaseError(result.error)
    }

    const actorIds = [...new Set([
      ...(exceptions ?? []).flatMap((row) => [
        row.created_by, row.updated_by, row.responsible_party_id,
        row.responsible_party_assigned_by, row.resolved_by, row.written_off_by,
      ]),
      ...(requests.data ?? []).flatMap((row) => [row.created_by, row.reviewed_by]),
      ...(allocations.data ?? []).flatMap((row) => [row.submitted_by, row.reviewed_by]),
      ...(memberships.data ?? []).map((row) => row.user_id),
    ].filter((value): value is string => Boolean(value)))]
    const actors = actorIds.length
      ? await caller.client.from('profiles').select('id,name,email').in('id', actorIds)
      : { data: [], error: null }
    if (actors.error) throwDatabaseError(actors.error)

    return Response.json({
      companyId,
      data: exceptions ?? [],
      requests: requests.data ?? [],
      allocations: allocations.data ?? [],
      documents: documents.data ?? [],
      stores: stores.data ?? [],
      actors: actors.data ?? [],
      members: (memberships.data ?? []).map((membership) => ({
        ...membership,
        profile: actors.data?.find((actor) => actor.id === membership.user_id) ?? null,
      })),
    })
  } catch (error) {
    return apiError(error)
  }
}
