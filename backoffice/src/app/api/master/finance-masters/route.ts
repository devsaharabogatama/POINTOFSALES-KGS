import {
  ApiRouteError,
  apiError,
  requireActiveCompany,
  requireCaller,
} from '@/lib/server-auth'
import { readJsonObject, throwDatabaseError } from '@/lib/master-data'
import {
  accountRpcArgs,
  categoryRpcArgs,
  fallbackRpcArgs,
  parseChartOfAccount,
  parseCompanyFallback,
  parseTransactionCategory,
  parseTransactionRule,
  ruleRpcArgs,
  throwFinanceMasterRpcError,
} from '@/lib/finance-master'

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const [functions, events, accounts, categories, rules, fallbacks] = await Promise.all([
      caller.client.from('account_functions')
        .select('function_key,function_name,compatible_account_types,is_active')
        .eq('is_active', true).order('function_name'),
      caller.client.from('system_events')
        .select('system_key,event_group,event_name,required_account_functions,conditional_account_functions,is_active')
        .eq('is_active', true).order('event_group').order('event_name'),
      caller.client.from('chart_of_accounts')
        .select('id,account_code,account_name,account_type,normal_balance,parent_account_id,system_function_key,is_system_account,is_postable,allow_manual_posting,allow_reconciliation,is_active,master_version')
        .eq('company_id', companyId).order('account_code').limit(1000),
      caller.client.from('transaction_categories')
        .select('id,category_code,category_name,system_key,description,is_active,is_system_default,master_version,created_at,updated_at')
        .eq('company_id', companyId).order('category_name').limit(500),
      caller.client.from('transaction_account_rules')
        .select('id,transaction_category_id,system_key,account_function_key,account_id,effective_from,effective_to,rule_version,status,approved_at,created_at')
        .eq('company_id', companyId).order('effective_from', { ascending: false })
        .limit(1000),
      caller.client.from('company_account_function_fallbacks')
        .select('id,account_function_key,account_id,effective_from,effective_to,fallback_version,status,approved_at,created_at')
        .eq('company_id', companyId).order('effective_from', { ascending: false })
        .limit(1000),
    ])
    for (const result of [functions, events, accounts, categories, rules, fallbacks]) {
      if (result.error) throwDatabaseError(result.error)
    }
    return Response.json({
      companyId,
      accountFunctions: functions.data ?? [],
      systemEvents: events.data ?? [],
      accounts: accounts.data ?? [],
      categories: categories.data ?? [],
      rules: rules.data ?? [],
      fallbacks: fallbacks.data ?? [],
    })
  } catch (error) {
    return apiError(error)
  }
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const body = await readJsonObject(request)
    if (body.entityType === 'CATEGORY') {
      const input = parseTransactionCategory(body, false)
      const { data, error } = await caller.client.rpc(
        'save_transaction_category', categoryRpcArgs(null, input),
      )
      if (error) throwFinanceMasterRpcError(error)
      return Response.json({ data }, { status: 201 })
    }
    if (body.entityType === 'RULE') {
      const input = parseTransactionRule(body)
      const { data, error } = await caller.client.rpc(
        'save_transaction_account_rule', ruleRpcArgs(input),
      )
      if (error) throwFinanceMasterRpcError(error)
      return Response.json({ data }, { status: 201 })
    }
    if (body.entityType === 'ACCOUNT') {
      const input = parseChartOfAccount(body, false)
      const { data, error } = await caller.client.rpc(
        'save_chart_of_account', accountRpcArgs(null, input),
      )
      if (error) throwFinanceMasterRpcError(error)
      return Response.json({ data }, { status: 201 })
    }
    if (body.entityType === 'FALLBACK') {
      const input = parseCompanyFallback(body)
      const { data, error } = await caller.client.rpc(
        'save_company_account_function_fallback', fallbackRpcArgs(input),
      )
      if (error) throwFinanceMasterRpcError(error)
      return Response.json({ data }, { status: 201 })
    }
    throw new ApiRouteError('FINANCE_ENTITY_TYPE_INVALID', 400)
  } catch (error) {
    return apiError(error)
  }
}
