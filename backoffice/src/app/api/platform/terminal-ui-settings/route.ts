import { ApiRouteError, apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject, requiredVersion, uuidValue } from '@/lib/master-data'

const featureKeys = new Set([
  'SALES_RETURN', 'EXPENSE', 'STOCK_REQUEST', 'GOODS_RECEIPT',
  'PURCHASE_RETURN', 'CASH_DEPOSIT', 'OFFLINE',
])

function rpcFailure(message: string): never {
  const known = ['TERMINAL_UI_SETTINGS_ACCESS_DENIED', 'POS_TERMINAL_NOT_FOUND',
    'INVALID_POS_TERMINAL_UI_FEATURE', 'MASTER_VERSION_CONFLICT']
  const code = known.find((candidate) => message.includes(candidate))
  throw new ApiRouteError(code ?? 'TERMINAL_UI_SETTINGS_FAILED',
    code === 'TERMINAL_UI_SETTINGS_ACCESS_DENIED' ? 403 : code === 'MASTER_VERSION_CONFLICT' ? 409 : 400)
}

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const { data, error } = await caller.client.rpc('get_pos_terminal_ui_settings')
    if (error) rpcFailure(error.message)
    return Response.json(data ?? {})
  } catch (error) { return apiError(error) }
}

export async function PATCH(request: Request) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const body = await readJsonObject(request)
    if (!Array.isArray(body.hiddenFeatureKeys) || body.hiddenFeatureKeys.some(
      (value) => typeof value !== 'string' || !featureKeys.has(value.toUpperCase()),
    )) throw new ApiRouteError('INVALID_POS_TERMINAL_UI_FEATURE', 400)
    const { data, error } = await caller.client.rpc('save_pos_terminal_ui_settings', {
      p_terminal_id: uuidValue(String(body.terminalId ?? '')),
      p_expected_version: requiredVersion(body),
      p_hidden_feature_keys: body.hiddenFeatureKeys.map((value) => String(value).toUpperCase()),
    })
    if (error) rpcFailure(error.message)
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}
