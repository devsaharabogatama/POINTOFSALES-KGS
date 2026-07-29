import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject, uuidValue } from '@/lib/master-data'
import { bundleRpcArgs, parseBundleBody, throwBundleRpcError } from '@/lib/bundle-master'

type RouteContext = { params: Promise<{ id: string }> }

export async function PATCH(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const { id } = await context.params
    const bundleId = uuidValue(id, 'INVALID_BUNDLE_ID')
    const input = parseBundleBody(await readJsonObject(request), true)
    const { data, error } = await caller.client.rpc(
      'save_bundle_with_components',
      bundleRpcArgs(bundleId, input),
    )
    if (error) throwBundleRpcError(error)
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}
