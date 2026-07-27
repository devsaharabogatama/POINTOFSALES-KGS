import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject, uuidValue } from '@/lib/master-data'
import {
  accountRpcArgs,
  parseChartOfAccount,
  throwFinanceMasterRpcError,
} from '@/lib/finance-master'

type RouteContext = { params: Promise<{ id: string }> }

export async function PATCH(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const { id } = await context.params
    const accountId = uuidValue(id)
    const input = parseChartOfAccount(await readJsonObject(request), true)
    const { data, error } = await caller.client.rpc(
      'save_chart_of_account', accountRpcArgs(accountId, input),
    )
    if (error) throwFinanceMasterRpcError(error)
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}
