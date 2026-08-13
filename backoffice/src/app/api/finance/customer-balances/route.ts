import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { throwDatabaseError } from '@/lib/master-data'

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const result = await caller.client.rpc('get_finance_customer_balances')
    if (result.error) throwDatabaseError(result.error)
    return Response.json(result.data ?? {
      companyId, currentUserId: caller.user.id, customers: [], requests: [],
      policy: null, stores: [], actors: [],
    })
  } catch (error) {
    return apiError(error)
  }
}
