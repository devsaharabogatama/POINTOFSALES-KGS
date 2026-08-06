import {
  ApiRouteError,
  apiError,
  requireActiveCompany,
  requireCaller,
} from '@/lib/server-auth'
import { readJsonObject, throwDatabaseError } from '@/lib/master-data'

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
const SETTINGS_ROLES = ['COMPANY_OWNER', 'COMPANY_ADMIN', 'STORE_MANAGER']

async function requireAllowanceManager(
  caller: Awaited<ReturnType<typeof requireCaller>>,
  companyId: string,
) {
  const { data: profile, error: profileError } = await caller.client
    .from('profiles')
    .select('role')
    .eq('id', caller.user.id)
    .single()
  if (profileError) throwDatabaseError(profileError)
  if (profile.role === 'super_admin') {
    return { roleCode: 'SUPER_ADMIN' }
  }

  const { data: membership, error: membershipError } = await caller.client
    .from('company_memberships')
    .select('role_code')
    .eq('company_id', companyId)
    .eq('user_id', caller.user.id)
    .eq('status', 'ACTIVE')
    .in('role_code', SETTINGS_ROLES)
    .maybeSingle()
  if (membershipError) throwDatabaseError(membershipError)
  if (!membership) {
    throw new ApiRouteError('OFFLINE_ALLOWANCE_MANAGER_REQUIRED', 403)
  }
  return { roleCode: membership.role_code }
}

function requiredUuid(value: unknown, errorCode: string) {
  if (typeof value !== 'string' || !UUID_PATTERN.test(value)) {
    throw new ApiRouteError(errorCode, 400)
  }
  return value
}

function throwAllowanceRpcError(error: { message: string }) {
  const known = [
    'OFFLINE_POS_FEATURE_DISABLED',
    'OPEN_CASHIER_SESSION_REQUIRED',
    'OFFLINE_ALLOWANCE_SESSION_ACCESS_DENIED',
    'OFFLINE_TERMINAL_NOT_ENABLED',
    'OFFLINE_COMPANY_POLICY_NOT_ENABLED',
    'ACTIVE_STOCK_PRODUCT_WITH_BASE_UOM_NOT_FOUND',
    'OFFLINE_ALLOWANCE_STOCK_UNAVAILABLE',
    'OFFLINE_ALLOWANCE_QUANTITY_UNAVAILABLE',
    'OFFLINE_ALLOWANCE_NOT_FOUND',
    'MASTER_VERSION_CONFLICT',
    'OFFLINE_QUEUE_RESOLUTION_REQUIRED',
    'OFFLINE_ALLOWANCE_FORCE_REVOKE_FORBIDDEN',
    'OFFLINE_ALLOWANCE_REVOKE_REASON_REQUIRED',
    'OFFLINE_ALLOWANCE_RELEASE_FORBIDDEN',
    'CONSUMED_OFFLINE_ALLOWANCE_CANNOT_RELEASE',
  ].find((code) => error.message.includes(code))
  if (!known) throwDatabaseError(error)
  const forbidden =
    known.endsWith('_ACCESS_DENIED') || known.endsWith('_FORBIDDEN')
  const notFound = known === 'OFFLINE_ALLOWANCE_NOT_FOUND'
  const conflict = [
    'OFFLINE_POS_FEATURE_DISABLED',
    'MASTER_VERSION_CONFLICT',
    'OFFLINE_QUEUE_RESOLUTION_REQUIRED',
  ].includes(known)
  throw new ApiRouteError(
    known,
    forbidden ? 403 : notFound ? 404 : conflict ? 409 : 400,
  )
}

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const access = await requireAllowanceManager(caller, companyId)
    const [
      feature,
      sessions,
      allowances,
      products,
      stocks,
      uoms,
      stores,
      terminals,
      warehouses,
    ] = await Promise.all([
      caller.client
        .from('company_features')
        .select('is_enabled')
        .eq('company_id', companyId)
        .eq('feature_code', 'offline_pos_enabled')
        .maybeSingle(),
      caller.client
        .from('cashier_sessions')
        .select(
          'id,session_code,cashier_id,store_id,pos_id,sales_warehouse_id,opened_at,status',
        )
        .eq('company_id', companyId)
        .eq('status', 'OPEN')
        .order('opened_at', { ascending: false })
        .limit(500),
      caller.client
        .from('pos_offline_stock_allowances')
        .select(
          'id,policy_id,store_id,warehouse_id,terminal_id,cashier_session_id,cashier_id,product_id,base_uom_id,allocated_base_qty,consumed_base_qty,allocation_percent_snapshot,stock_qty_snapshot,unreserved_qty_snapshot,status,released_at,released_by,release_reason,master_version,created_at,updated_at',
        )
        .eq('company_id', companyId)
        .order('created_at', { ascending: false })
        .limit(5000),
      caller.client
        .from('products')
        .select('id,name,sku,uom_id,is_active,is_bundle')
        .eq('company_id', companyId)
        .eq('is_active', true)
        .eq('is_bundle', false)
        .order('name')
        .limit(10000),
      caller.client
        .from('product_stocks')
        .select('product_id,warehouse_id,stock_qty,updated_at')
        .eq('company_id', companyId)
        .gt('stock_qty', 0)
        .limit(20000),
      caller.client
        .from('uoms')
        .select('id,name,allow_decimal,decimal_precision')
        .eq('company_id', companyId)
        .limit(5000),
      caller.client
        .from('stores')
        .select('id,store_name')
        .eq('company_id', companyId)
        .limit(5000),
      caller.client
        .from('pos_terminals')
        .select('id,pos_name')
        .eq('company_id', companyId)
        .limit(5000),
      caller.client
        .from('warehouses')
        .select('id,name')
        .eq('company_id', companyId)
        .limit(5000),
    ])

    for (const result of [
      feature,
      sessions,
      allowances,
      products,
      stocks,
      uoms,
      stores,
      terminals,
      warehouses,
    ]) {
      if (result.error) throwDatabaseError(result.error)
    }

    const actorIds = new Set<string>()
    for (const session of sessions.data ?? []) actorIds.add(session.cashier_id)
    for (const allowance of allowances.data ?? []) {
      actorIds.add(allowance.cashier_id)
      if (allowance.released_by) actorIds.add(allowance.released_by)
    }
    const actors = actorIds.size
      ? await caller.client
          .from('profiles')
          .select('id,name')
          .in('id', [...actorIds])
          .limit(5000)
      : { data: [], error: null }
    if (actors.error) throwDatabaseError(actors.error)

    return Response.json({
      data: {
        actorId: caller.user.id,
        roleCode: access.roleCode,
        featureEnabled: feature.data?.is_enabled ?? false,
        sessions: sessions.data ?? [],
        allowances: allowances.data ?? [],
        products: products.data ?? [],
        stocks: stocks.data ?? [],
        uoms: uoms.data ?? [],
        stores: stores.data ?? [],
        terminals: terminals.data ?? [],
        warehouses: warehouses.data ?? [],
        actors: actors.data ?? [],
      },
    })
  } catch (error) {
    return apiError(error)
  }
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    await requireAllowanceManager(caller, companyId)
    const body = await readJsonObject(request)
    const action =
      typeof body.action === 'string' ? body.action.toUpperCase() : ''

    if (action === 'ISSUE') {
      const sessionId = requiredUuid(
        body.cashierSessionId,
        'OFFLINE_ALLOWANCE_SESSION_ID_INVALID',
      )
      const productId = requiredUuid(
        body.productId,
        'OFFLINE_ALLOWANCE_PRODUCT_ID_INVALID',
      )
      const { data, error } = await caller.client.rpc(
        'issue_pos_offline_stock_allowance',
        {
          p_cashier_session_id: sessionId,
          p_product_id: productId,
        },
      )
      if (error) throwAllowanceRpcError(error)
      return Response.json({ data })
    }

    if (action === 'RELEASE' || action === 'FORCE_REVOKE') {
      const allowanceId = requiredUuid(
        body.allowanceId,
        'OFFLINE_ALLOWANCE_ID_INVALID',
      )
      const masterVersion = Number(body.masterVersion)
      if (!Number.isInteger(masterVersion) || masterVersion < 1) {
        throw new ApiRouteError('MASTER_VERSION_REQUIRED', 400)
      }
      const reason =
        typeof body.reason === 'string' ? body.reason.trim() : ''
      if (action === 'FORCE_REVOKE' && !reason) {
        throw new ApiRouteError(
          'OFFLINE_ALLOWANCE_REVOKE_REASON_REQUIRED',
          400,
        )
      }
      if (reason.length > 500) {
        throw new ApiRouteError('OFFLINE_ALLOWANCE_REASON_TOO_LONG', 400)
      }
      const { data, error } = await caller.client.rpc(
        'release_pos_offline_stock_allowance',
        {
          p_allowance_id: allowanceId,
          p_master_version: masterVersion,
          p_force: action === 'FORCE_REVOKE',
          p_reason: reason || null,
        },
      )
      if (error) throwAllowanceRpcError(error)
      return Response.json({ data })
    }

    throw new ApiRouteError('OFFLINE_ALLOWANCE_ACTION_INVALID', 400)
  } catch (error) {
    return apiError(error)
  }
}
