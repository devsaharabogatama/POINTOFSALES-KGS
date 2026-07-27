import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { throwDatabaseError } from '@/lib/master-data'

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const now = new Date().toISOString()
    const [rules, versions, features] = await Promise.all([
      caller.client
        .from('tax_rules')
        .select('id,tax_name,tax_scope,is_active')
        .eq('company_id', companyId)
        .eq('is_active', true)
        .order('tax_name'),
      caller.client
        .from('tax_rule_versions')
        .select('tax_rule_id,rate_percent,effective_from,effective_to,status')
        .eq('company_id', companyId)
        .eq('status', 'ACTIVE')
        .lte('effective_from', now)
        .or(`effective_to.is.null,effective_to.gt.${now}`),
      caller.client
        .from('company_features')
        .select('feature_code,is_enabled')
        .eq('company_id', companyId)
        .in('feature_code', ['tax_sales_enabled', 'tax_purchase_enabled']),
    ])
    for (const result of [rules, versions, features]) {
      if (result.error) throwDatabaseError(result.error)
    }

    const currentVersions = new Map(
      (versions.data ?? []).map((version) => [version.tax_rule_id, version]),
    )
    const featureMap = new Map(
      (features.data ?? []).map((feature) => [feature.feature_code, feature.is_enabled]),
    )
    return Response.json({
      companyId,
      data: (rules.data ?? [])
        .filter((rule) => currentVersions.has(rule.id))
        .map((rule) => ({
          id: rule.id,
          name: rule.tax_name,
          scope: rule.tax_scope,
          ratePercent: currentVersions.get(rule.id)?.rate_percent ?? 0,
        })),
      entitlements: {
        salesEnabled: featureMap.get('tax_sales_enabled') === true,
        purchaseEnabled: featureMap.get('tax_purchase_enabled') === true,
      },
    })
  } catch (error) {
    return apiError(error)
  }
}
