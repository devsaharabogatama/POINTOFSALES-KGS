import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { uuidValue } from '@/lib/master-data'
import { throwCustomerBalanceRpcError } from '@/lib/customer-balance'

type RouteContext = { params: Promise<{ id: string }> }

export async function GET(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const { id } = await context.params
    const url = new URL(request.url)
    const { data, error } = await caller.client.rpc(
      'get_customer_balance_statement',
      {
        p_customer_id: uuidValue(id),
        p_from: url.searchParams.get('from') || null,
        p_to: url.searchParams.get('to') || null,
      },
    )
    if (error) throwCustomerBalanceRpcError(error)
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}
