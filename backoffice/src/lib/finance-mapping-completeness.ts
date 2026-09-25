export type FinanceRequirement = 'REQUIRED' | 'CONDITIONAL' | 'OPTIONAL'

export type FinanceMappingResolution =
  | 'DIRECT_RULE'
  | 'COMPANY_FALLBACK'
  | 'MISSING'
  | 'AMBIGUOUS'
  | 'INVALID_ACCOUNT'
  | 'FUNCTION_INACTIVE'

type AccountFunction = {
  function_key: string
  function_name: string
  compatible_account_types: string[]
}

type SystemEvent = {
  system_key: string
  event_group: string
  event_name: string
  required_account_functions: string[]
  conditional_account_functions: string[]
  optional_account_functions: string[]
}

type Account = {
  id: string
  account_code: string
  account_name: string
  account_type: string
  is_postable: boolean
  is_active: boolean
}

type Category = {
  id: string
  category_name: string
  system_key: string
  is_active: boolean
}

type Rule = {
  id: string
  transaction_category_id: string
  system_key: string
  account_function_key: string
  account_id: string
  effective_from: string
  effective_to: string | null
  status: string
}

type Fallback = {
  id: string
  account_function_key: string
  account_id: string
  effective_from: string
  effective_to: string | null
  status: string
}

export type FinanceMappingCompletenessRow = {
  category_id: string
  category_name: string
  system_key: string
  event_group: string
  event_name: string
  account_function_key: string
  function_name: string
  requirement: FinanceRequirement
  resolution: FinanceMappingResolution
  account_id: string | null
  account_code: string | null
  account_name: string | null
}

function isEffective(
  row: { effective_from: string; effective_to: string | null; status: string },
  asOf: number,
) {
  if (row.status !== 'ACTIVE') return false
  const from = Date.parse(row.effective_from)
  const to = row.effective_to ? Date.parse(row.effective_to) : null
  return Number.isFinite(from) && from <= asOf && (to === null || (Number.isFinite(to) && to > asOf))
}

function orderedFunctions(event: SystemEvent) {
  const requirementByFunction = new Map<string, FinanceRequirement>()
  for (const functionKey of event.optional_account_functions ?? []) {
    requirementByFunction.set(functionKey, 'OPTIONAL')
  }
  for (const functionKey of event.conditional_account_functions ?? []) {
    requirementByFunction.set(functionKey, 'CONDITIONAL')
  }
  for (const functionKey of event.required_account_functions ?? []) {
    requirementByFunction.set(functionKey, 'REQUIRED')
  }
  return [...requirementByFunction.entries()].sort(([left], [right]) => left.localeCompare(right))
}

export function buildFinanceMappingCompleteness({
  accountFunctions,
  systemEvents,
  accounts,
  categories,
  rules,
  fallbacks,
  asOf,
}: {
  accountFunctions: AccountFunction[]
  systemEvents: SystemEvent[]
  accounts: Account[]
  categories: Category[]
  rules: Rule[]
  fallbacks: Fallback[]
  asOf: string
}): FinanceMappingCompletenessRow[] {
  const asOfTime = Date.parse(asOf)
  if (!Number.isFinite(asOfTime)) throw new Error('FINANCE_MAPPING_AS_OF_INVALID')

  const eventByKey = new Map(systemEvents.map((event) => [event.system_key, event]))
  const functionByKey = new Map(accountFunctions.map((item) => [item.function_key, item]))
  const accountById = new Map(accounts.map((account) => [account.id, account]))
  const effectiveRules = rules.filter((rule) => isEffective(rule, asOfTime))
  const effectiveFallbacks = fallbacks.filter((fallback) => isEffective(fallback, asOfTime))
  const result: FinanceMappingCompletenessRow[] = []

  for (const category of categories.filter((item) => item.is_active)) {
    const event = eventByKey.get(category.system_key)
    if (!event) continue

    for (const [functionKey, requirement] of orderedFunctions(event)) {
      const accountFunction = functionByKey.get(functionKey)
      const directRules = effectiveRules.filter((rule) =>
        rule.transaction_category_id === category.id &&
        rule.system_key === category.system_key &&
        rule.account_function_key === functionKey,
      )
      const companyFallbacks = effectiveFallbacks.filter(
        (fallback) => fallback.account_function_key === functionKey,
      )

      let resolution: FinanceMappingResolution
      let accountId: string | null = null
      if (!accountFunction) {
        resolution = 'FUNCTION_INACTIVE'
      } else if (directRules.length > 1) {
        resolution = 'AMBIGUOUS'
      } else if (directRules.length === 1) {
        resolution = 'DIRECT_RULE'
        accountId = directRules[0].account_id
      } else if (companyFallbacks.length > 1) {
        resolution = 'AMBIGUOUS'
      } else if (companyFallbacks.length === 1) {
        resolution = 'COMPANY_FALLBACK'
        accountId = companyFallbacks[0].account_id
      } else {
        resolution = 'MISSING'
      }

      const account = accountId ? accountById.get(accountId) : undefined
      if (
        accountId &&
        (!account || !account.is_active || !account.is_postable ||
          !accountFunction?.compatible_account_types.includes(account.account_type))
      ) {
        resolution = 'INVALID_ACCOUNT'
      }

      result.push({
        category_id: category.id,
        category_name: category.category_name,
        system_key: category.system_key,
        event_group: event.event_group,
        event_name: event.event_name,
        account_function_key: functionKey,
        function_name: accountFunction?.function_name ?? functionKey,
        requirement,
        resolution,
        account_id: account?.id ?? null,
        account_code: account?.account_code ?? null,
        account_name: account?.account_name ?? null,
      })
    }
  }

  return result.sort((left, right) =>
    left.event_group.localeCompare(right.event_group) ||
    left.event_name.localeCompare(right.event_name) ||
    left.category_name.localeCompare(right.category_name) ||
    left.function_name.localeCompare(right.function_name),
  )
}
