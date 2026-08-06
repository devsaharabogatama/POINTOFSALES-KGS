import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { throwDatabaseError } from '@/lib/master-data'

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const [customers, requests, policy, stores] = await Promise.all([
      caller.client.from('customers')
        .select('id,name,current_balance,is_active,is_system_customer')
        .eq('company_id', companyId).eq('is_system_customer', false)
        .order('name'),
      caller.client.from('customer_balance_correction_requests')
        .select(`id,customer_id,store_id,request_no,direction,amount,
          source_account_function,reason,evidence_url,status,ledger_entry_id,
          created_by,reviewed_by,created_at,reviewed_at,rejection_reason,
          master_version`)
        .eq('company_id', companyId).order('created_at', { ascending: false })
        .limit(500),
      caller.client.from('customer_balance_company_policies')
        .select('lifecycle_state,master_version').eq('company_id', companyId)
        .maybeSingle(),
      caller.client.from('stores').select('id,store_name,status')
        .eq('company_id', companyId).eq('status', 'ACTIVE').order('store_name'),
    ])
    for (const result of [customers, requests, policy, stores]) {
      if (result.error) throwDatabaseError(result.error)
    }
    const actorIds = [...new Set((requests.data ?? []).flatMap((row) => [
      row.created_by, row.reviewed_by,
    ]).filter((value): value is string => Boolean(value)))]
    const actors = actorIds.length
      ? await caller.client.from('profiles').select('id,name,email').in('id', actorIds)
      : { data: [], error: null }
    if (actors.error) throwDatabaseError(actors.error)
    return Response.json({
      companyId,
      currentUserId: caller.user.id,
      customers: customers.data ?? [],
      requests: requests.data ?? [],
      policy: policy.data ?? null,
      stores: stores.data ?? [],
      actors: actors.data ?? [],
    })
  } catch (error) {
    return apiError(error)
  }
}
