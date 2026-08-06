import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { throwDatabaseError } from '@/lib/master-data'

const documentFields = `
  id,company_id,document_no,store_id,pos_terminal_id,cashier_session_id,
  category_name_snapshot,responsible_party_type,responsible_party_id,
  responsible_party_name_snapshot,requested_amount,disbursed_amount,
  actual_expense_amount,returned_amount,outstanding_amount,
  requested_payment_method_id,
  requested_payment_method_name_snapshot,requested_payment_method_type_snapshot,
  recipient,description,evidence_url,expected_settlement_date,status,
  approval_required_snapshot,evidence_policy_snapshot,master_version,
  created_by,submitted_by,approved_by,rejected_by,canceled_by,created_at,
  updated_at,submitted_at,approved_at,rejected_at,canceled_at,
  rejection_reason,cancel_reason,disbursed_by,disbursed_at,settled_by,settled_at
`

const settlementRequestFields = `
  id,document_id,store_id,actual_expense_amount,evidence_url,status,
  submitted_by,reviewed_by,submitted_at,reviewed_at,rejection_reason,
  master_version
`

const additionalRequestFields = `
  id,document_id,store_id,amount,payment_method_id,
  payment_method_name_snapshot,payment_method_type_snapshot,evidence_url,
  approval_required_snapshot,status,document_master_version_snapshot,
  requested_by,approved_by,rejected_by,disbursed_by,requested_at,approved_at,
  rejected_at,rejection_reason,disbursed_at,expense_disbursement_id,master_version
`

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const status = new URL(request.url).searchParams.get('status')?.trim().toUpperCase()

    let query = caller.client
      .from('expense_documents')
      .select(documentFields)
      .eq('company_id', companyId)
      .order('created_at', { ascending: false })
      .limit(500)
    if (status && [
      'DRAFT', 'SUBMITTED', 'APPROVED', 'REJECTED', 'CANCELED',
      'PAYMENT_PENDING', 'DISBURSED', 'PARTIALLY_SETTLED', 'SETTLED',
      'SETTLED_NO_EXPENSE', 'REVERSED',
    ].includes(status)) {
      query = query.eq('status', status)
    }
    const { data: documents, error } = await query
    if (error) throwDatabaseError(error)

    const documentIds = (documents ?? []).map((row) => row.id)
    const { data: settlementRequests, error: settlementError } = documentIds.length
      ? await caller.client
          .from('expense_settlement_requests')
          .select(settlementRequestFields)
          .eq('company_id', companyId)
          .in('document_id', documentIds)
          .order('submitted_at', { ascending: false })
      : { data: [], error: null }
    if (settlementError) throwDatabaseError(settlementError)

    const { data: additionalRequests, error: additionalError } = documentIds.length
      ? await caller.client
          .from('expense_additional_disbursement_requests')
          .select(additionalRequestFields)
          .eq('company_id', companyId)
          .in('document_id', documentIds)
          .order('requested_at', { ascending: false })
      : { data: [], error: null }
    if (additionalError) throwDatabaseError(additionalError)

    const storeIds = [...new Set((documents ?? []).map((row) => row.store_id))]
    const sessionIds = [...new Set(
      (documents ?? []).map((row) => row.cashier_session_id).filter(Boolean),
    )]
    const actorIds = [...new Set([
      ...(documents ?? []).flatMap((row) => [
        row.created_by, row.submitted_by, row.approved_by,
        row.rejected_by, row.canceled_by, row.disbursed_by, row.settled_by,
      ]),
      ...(settlementRequests ?? []).flatMap((row) => [
        row.submitted_by, row.reviewed_by,
      ]),
      ...(additionalRequests ?? []).flatMap((row) => [
        row.requested_by, row.approved_by, row.rejected_by, row.disbursed_by,
      ]),
    ].filter((value): value is string => Boolean(value)))]
    const paymentMethodIds = [...new Set(
      [
        ...(documents ?? []).map((row) => row.requested_payment_method_id),
        ...(additionalRequests ?? []).map((row) => row.payment_method_id),
      ],
    )]

    const [stores, sessions, actors, paymentMethods] = await Promise.all([
      storeIds.length
        ? caller.client.from('stores').select('id,store_name').eq('company_id', companyId).in('id', storeIds)
        : Promise.resolve({ data: [], error: null }),
      sessionIds.length
        ? caller.client.from('cashier_sessions').select('id,session_code,status').eq('company_id', companyId).in('id', sessionIds)
        : Promise.resolve({ data: [], error: null }),
      actorIds.length
        ? caller.client.from('profiles').select('id,name').in('id', actorIds)
        : Promise.resolve({ data: [], error: null }),
      paymentMethodIds.length
        ? caller.client
            .from('payment_methods')
            .select('id,payment_method_name,method_type,proof_mode,settlement_route,is_active')
            .eq('company_id', companyId)
            .in('id', paymentMethodIds)
        : Promise.resolve({ data: [], error: null }),
    ])
    for (const result of [stores, sessions, actors, paymentMethods]) {
      if (result.error) throwDatabaseError(result.error)
    }

    return Response.json({
      companyId,
      data: documents ?? [],
      stores: stores.data ?? [],
      sessions: sessions.data ?? [],
      actors: actors.data ?? [],
      paymentMethods: paymentMethods.data ?? [],
      settlementRequests: settlementRequests ?? [],
      additionalRequests: additionalRequests ?? [],
    })
  } catch (error) {
    return apiError(error)
  }
}
