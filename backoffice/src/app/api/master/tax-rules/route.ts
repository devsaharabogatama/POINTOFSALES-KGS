import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject, throwDatabaseError } from '@/lib/master-data'
import { parseTaxRuleBody, taxRuleRpcArgs, throwTaxRuleRpcError } from '@/lib/tax-master'

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const [rules, versions, accounts, features] = await Promise.all([
      caller.client.from('tax_rules')
        .select('id,tax_code,tax_name,tax_scope,is_active,master_version,created_at,updated_at')
        .eq('company_id', companyId).order('tax_name').limit(500),
      caller.client.from('tax_rule_versions')
        .select('id,tax_rule_id,rate_percent,calculation_scope,default_price_mode,account_function_key,account_id,is_recoverable,effective_from,effective_to,rule_version,status,approved_at,created_at')
        .eq('company_id', companyId).order('rule_version', { ascending: false }).limit(1500),
      caller.client.from('chart_of_accounts')
        .select('id,account_code,account_name,account_type,system_function_key,is_postable,is_active')
        .eq('company_id', companyId).eq('is_active', true).eq('is_postable', true)
        .in('account_type', ['ASSET', 'LIABILITY']).order('account_code').limit(500),
      caller.client.from('company_features').select('feature_code,is_enabled')
        .eq('company_id', companyId)
        .in('feature_code', ['tax_sales_enabled', 'tax_purchase_enabled']),
    ])
    for (const result of [rules, versions, accounts, features]) {
      if (result.error) throwDatabaseError(result.error)
    }
    const versionRows = versions.data ?? []
    const featureMap = new Map((features.data ?? []).map((row) => [row.feature_code, row.is_enabled]))
    return Response.json({
      companyId,
      data: (rules.data ?? []).map((rule) => ({
        ...rule,
        versions: versionRows.filter((version) => version.tax_rule_id === rule.id),
      })),
      accounts: accounts.data ?? [],
      entitlements: {
        salesEnabled: featureMap.get('tax_sales_enabled') === true,
        purchaseEnabled: featureMap.get('tax_purchase_enabled') === true,
      },
    })
  } catch (error) {
    return apiError(error)
  }
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const input = parseTaxRuleBody(await readJsonObject(request), false)
    const { data, error } = await caller.client.rpc('save_tax_rule', taxRuleRpcArgs(null, input))
    if (error) throwTaxRuleRpcError(error)
    return Response.json({ data }, { status: 201 })
  } catch (error) {
    return apiError(error)
  }
}
