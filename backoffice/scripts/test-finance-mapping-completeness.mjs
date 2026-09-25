import assert from 'node:assert/strict'
import { buildFinanceMappingCompleteness } from '../src/lib/finance-mapping-completeness.ts'

const asOf = '2026-09-24T10:00:00.000Z'
const base = {
  accountFunctions: [
    { function_key: 'REQUIRED_FN', function_name: 'Wajib', compatible_account_types: ['ASSET'] },
    { function_key: 'CONDITIONAL_FN', function_name: 'Kondisional', compatible_account_types: ['LIABILITY'] },
    { function_key: 'OPTIONAL_FN', function_name: 'Opsional', compatible_account_types: ['ASSET'] },
  ],
  systemEvents: [{
    system_key: 'TEST_EVENT', event_group: 'FINANCE', event_name: 'Test Event',
    required_account_functions: ['REQUIRED_FN'],
    conditional_account_functions: ['CONDITIONAL_FN'],
    optional_account_functions: ['OPTIONAL_FN'],
  }],
  accounts: [
    { id: 'asset', account_code: '1000', account_name: 'Asset', account_type: 'ASSET', is_postable: true, is_active: true },
    { id: 'liability', account_code: '2000', account_name: 'Liability', account_type: 'LIABILITY', is_postable: true, is_active: true },
  ],
  categories: [{ id: 'category', category_name: 'Kategori', system_key: 'TEST_EVENT', is_active: true }],
  rules: [{
    id: 'rule-required', transaction_category_id: 'category', system_key: 'TEST_EVENT',
    account_function_key: 'REQUIRED_FN', account_id: 'asset', status: 'ACTIVE',
    effective_from: '2026-01-01T00:00:00.000Z', effective_to: null,
  }],
  fallbacks: [{
    id: 'fallback-conditional', account_function_key: 'CONDITIONAL_FN', account_id: 'liability',
    status: 'ACTIVE', effective_from: '2026-01-01T00:00:00.000Z', effective_to: null,
  }],
  asOf,
}

const rows = buildFinanceMappingCompleteness(base)
assert.equal(rows.length, 3)
assert.equal(rows.find((row) => row.account_function_key === 'REQUIRED_FN')?.resolution, 'DIRECT_RULE')
assert.equal(rows.find((row) => row.account_function_key === 'CONDITIONAL_FN')?.resolution, 'COMPANY_FALLBACK')
assert.equal(rows.find((row) => row.account_function_key === 'OPTIONAL_FN')?.resolution, 'MISSING')

const ambiguous = buildFinanceMappingCompleteness({
  ...base,
  rules: [...base.rules, { ...base.rules[0], id: 'rule-required-duplicate' }],
})
assert.equal(ambiguous.find((row) => row.account_function_key === 'REQUIRED_FN')?.resolution, 'AMBIGUOUS')

const invalid = buildFinanceMappingCompleteness({
  ...base,
  rules: [{ ...base.rules[0], account_id: 'liability' }],
})
assert.equal(invalid.find((row) => row.account_function_key === 'REQUIRED_FN')?.resolution, 'INVALID_ACCOUNT')

const futureRule = buildFinanceMappingCompleteness({
  ...base,
  rules: [{ ...base.rules[0], effective_from: '2027-01-01T00:00:00.000Z' }],
})
assert.equal(futureRule.find((row) => row.account_function_key === 'REQUIRED_FN')?.resolution, 'MISSING')

console.log('finance mapping completeness tests: PASS')
