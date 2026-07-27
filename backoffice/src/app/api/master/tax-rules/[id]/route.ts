import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject, uuidValue } from '@/lib/master-data'
import { parseTaxRuleBody, taxRuleRpcArgs, throwTaxRuleRpcError } from '@/lib/tax-master'

type RouteContext = { params: Promise<{ id: string }> }

export async function PATCH(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const { id } = await context.params
    const input = parseTaxRuleBody(await readJsonObject(request), true)
    const { data, error } = await caller.client.rpc(
      'save_tax_rule', taxRuleRpcArgs(uuidValue(id), input),
    )
    if (error) throwTaxRuleRpcError(error)
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}
