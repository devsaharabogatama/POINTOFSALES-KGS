import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { throwDatabaseError } from '@/lib/master-data'

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const { data, error } = await caller.client.rpc(
      'get_finance_deposit_variances',
    )
    if (error) throwDatabaseError(error)
    return Response.json(data)
  } catch (error) {
    return apiError(error)
  }
}
