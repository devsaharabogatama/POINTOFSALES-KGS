import { createClient } from '@supabase/supabase-js'
import { randomUUID } from 'node:crypto'

function hasValidUrl(value) {
  try {
    const parsed = new URL(value)
    return (
      ['http:', 'https:'].includes(parsed.protocol) &&
      !parsed.hostname.includes('your-project')
    )
  } catch {
    return false
  }
}

function hasValidPublicKey(value) {
  const normalized = value.toLowerCase()
  return (
    value.length >= 20 &&
    !normalized.includes('your-anon') &&
    !normalized.includes('placeholder')
  )
}

const required = [
  'G4_TEST_EMAIL',
  'G4_TEST_PASSWORD',
  'G4_TEST_DRAFT_NO',
]

for (const name of required) {
  if (!process.env[name]) {
    throw new Error(`Missing required environment variable: ${name}`)
  }
}

if (process.env.G4_TEST_CONFIRM_POST !== 'YES_POST_STAGING_DRAFT') {
  throw new Error(
    'Refusing to post. Set G4_TEST_CONFIRM_POST=YES_POST_STAGING_DRAFT only for a disposable staging Draft.',
  )
}

const viteUrl = (process.env.VITE_SUPABASE_URL ?? '').trim()
const backofficeUrl = (process.env.NEXT_PUBLIC_SUPABASE_URL ?? '').trim()
const viteKey = (process.env.VITE_SUPABASE_ANON_KEY ?? '').trim()
const backofficeKey = (
  process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? ''
).trim()
const url = hasValidUrl(viteUrl) ? viteUrl : backofficeUrl
const anonKey = hasValidPublicKey(viteKey) ? viteKey : backofficeKey
if (!hasValidUrl(url) || !hasValidPublicKey(anonKey)) {
  throw new Error(
    'Supabase public configuration is invalid. Configure pwa/.env or backoffice/.env.local; placeholder values are rejected.',
  )
}

const draftNo = process.env.G4_TEST_DRAFT_NO
const concurrency = Math.max(
  2,
  Math.min(20, Number(process.env.G4_TEST_CONCURRENCY ?? 20)),
)

function assert(condition, message) {
  if (!condition) throw new Error(message)
}

function failOnError(result, label) {
  if (result.error) {
    throw new Error(`${label}: ${result.error.message}`)
  }
  return result.data
}

async function countRows(client, table, configure, label) {
  let query = client.from(table).select('*', {
    count: 'exact',
    head: true,
  })
  query = configure(query)
  const result = await query
  if (result.error) throw new Error(`${label}: ${result.error.message}`)
  return result.count ?? 0
}

const authClient = createClient(url, anonKey, {
  auth: { persistSession: false, autoRefreshToken: false },
})

const login = await authClient.auth.signInWithPassword({
  email: process.env.G4_TEST_EMAIL,
  password: process.env.G4_TEST_PASSWORD,
})
if (login.error || !login.data.session) {
  throw new Error(`Authentication failed: ${login.error?.message ?? 'no session'}`)
}

let companyId = process.env.G4_TEST_COMPANY_ID
if (!companyId) {
  const activeContext = failOnError(
    await authClient
      .from('user_active_company_contexts')
      .select('company_id')
      .eq('user_id', login.data.session.user.id)
      .maybeSingle(),
    'Load active Company context',
  )
  companyId = activeContext?.company_id
}
assert(
  companyId,
  'No active Company context. Select the staging Company in PWA first or set G4_TEST_COMPANY_ID.',
)

const accessToken = login.data.session.access_token
const makeWorker = () =>
  createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: {
      headers: { Authorization: `Bearer ${accessToken}` },
    },
  })

const control = makeWorker()
failOnError(
  await control.rpc('set_active_company_context', {
    p_company_id: companyId,
    p_selection_source: 'G4_PHASE10_CONCURRENT_STRESS',
  }),
  'Set active Company',
)

const draftResult = await control
  .from('sales_headers')
  .select(
    'id,draft_no,master_version,session_id,store_id,sales_warehouse_id,document_status,grand_total_after_rounding,payload_snapshot',
  )
  .eq('company_id', companyId)
  .eq('draft_no', draftNo)
  .single()
let draft = failOnError(draftResult, 'Load disposable Draft')

assert(draft.document_status === 'DRAFT', `${draftNo} is not a Draft`)
assert(
  !draft.payload_snapshot?.isTempo,
  'Tempo Draft is outside this stress boundary',
)

failOnError(
  await control.rpc('acquire_pos_sale_draft_lock', {
    p_sales_id: draft.id,
    p_cashier_session_id: draft.session_id,
    p_confirm_takeover: false,
  }),
  'Acquire Draft lock',
)

let paymentIntent = Array.isArray(draft.payload_snapshot?.payments)
  ? draft.payload_snapshot.payments
  : []
if (paymentIntent.length === 0) {
  const [methodsResult, assignmentsResult] = await Promise.all([
    control
      .from('payment_methods')
      .select(
        'id,method_type,proof_mode,is_default,available_all_stores,is_active',
      )
      .eq('company_id', companyId)
      .eq('is_active', true),
    control
      .from('payment_method_store_assignments')
      .select('payment_method_id')
      .eq('company_id', companyId)
      .eq('store_id', draft.store_id),
  ])
  const methods = failOnError(methodsResult, 'Load eligible Payment Methods')
  const assignedIds = new Set(
    failOnError(assignmentsResult, 'Load Payment Method assignments').map(
      (row) => row.payment_method_id,
    ),
  )
  const eligibleMethods = methods
    .filter(
      (method) =>
        (method.available_all_stores || assignedIds.has(method.id)) &&
        !['CUSTOMER_BALANCE', 'KETUL_OFFSET', 'TEMPO'].includes(
          method.method_type,
        ) &&
        method.proof_mode !== 'REQUIRED',
    )
    .sort(
      (a, b) =>
        Number(b.method_type === 'CASH') -
          Number(a.method_type === 'CASH') ||
        Number(b.is_default) - Number(a.is_default),
    )
  const paymentMethod = eligibleMethods[0]
  assert(
    paymentMethod,
    'No eligible non-proof Payment Method is available for this Store.',
  )
  const amount = Number(draft.grand_total_after_rounding)
  assert(amount > 0, 'Draft total must be positive')
  paymentIntent = [
    {
      clientPaymentKey: randomUUID(),
      paymentMethodId: paymentMethod.id,
      amount,
      tenderedAmount: amount,
    },
  ]
  const preparedDraft = failOnError(
    await control.rpc('save_pos_sale_draft_with_pricelist', {
      p_payload: {
        ...draft.payload_snapshot,
        saleId: draft.id,
        masterVersion: draft.master_version,
        payments: paymentIntent,
      },
    }),
    'Prepare Draft payment intent',
  )
  draft = {
    ...draft,
    master_version: Number(preparedDraft.masterVersion),
    grand_total_after_rounding: Number(
      preparedDraft.grandTotalAfterRounding,
    ),
    payload_snapshot: {
      ...draft.payload_snapshot,
      payments: paymentIntent,
    },
  }
}

draft = failOnError(
  await control
    .from('sales_headers')
    .select(
      'id,draft_no,master_version,session_id,store_id,sales_warehouse_id,document_status,grand_total_after_rounding,payload_snapshot',
    )
    .eq('company_id', companyId)
    .eq('id', draft.id)
    .single(),
  'Reload authoritative Draft after payment preparation',
)
paymentIntent = Array.isArray(draft.payload_snapshot?.payments)
  ? draft.payload_snapshot.payments
  : []
assert(
  paymentIntent.length > 0,
  'Payment preparation did not persist on the Draft',
)

const requirementsResult = await control
  .from('sale_stock_requirements')
  .select('stock_product_id')
  .eq('company_id', companyId)
  .eq('sales_id', draft.id)
const requirements = failOnError(
  requirementsResult,
  'Load stock requirements',
)
const requiredByProduct = new Map()
for (const requirement of requirements) {
  requiredByProduct.set(
    requirement.stock_product_id,
    (requiredByProduct.get(requirement.stock_product_id) ?? 0) +
      Number(requirement.quantity_base),
  )
}
const stockProductIds = [...requiredByProduct.keys()]
const stockResult =
  stockProductIds.length === 0
    ? { data: [], error: null }
    : await control
        .from('product_stocks')
        .select('product_id,stock_qty')
        .eq('company_id', companyId)
        .eq('warehouse_id', draft.sales_warehouse_id)
        .in('product_id', stockProductIds)
const stockRows = failOnError(stockResult, 'Load current stock')
const availableByProduct = new Map(
  stockRows.map((row) => [row.product_id, Number(row.stock_qty)]),
)
const stockShortages = [...requiredByProduct.entries()]
  .map(([productId, required], index) => {
    const available = availableByProduct.get(productId) ?? 0
    return {
      item: index + 1,
      required,
      available,
      shortage: Math.max(required - available, 0),
    }
  })
  .filter((item) => item.shortage > 0)
assert(
  stockShortages.length === 0,
  `Stress fixture has insufficient stock: ${JSON.stringify(stockShortages)}`,
)

const expectedMovementCount = new Set(
  requirements.map((row) => row.stock_product_id),
).size
const expectedPaymentCount = paymentIntent.length

const before = {
  movements: await countRows(
    control,
    'stock_movements',
    (query) =>
      query
        .eq('company_id', companyId)
        .eq('reference_table', 'sales_headers')
        .eq('reference_id', draft.id),
    'Count Movement before',
  ),
  payments: await countRows(
    control,
    'sales_payments',
    (query) =>
      query.eq('company_id', companyId).eq('sales_id', draft.id),
    'Count Payment before',
  ),
}

assert(
  before.movements === 0 && before.payments === 0,
  'Draft already has final effects; refusing stress run',
)

const postingIdempotencyKey = randomUUID()
const workers = Array.from({ length: concurrency }, makeWorker)
const startedAt = performance.now()
const responses = await Promise.all(
  workers.map((client) =>
    client.rpc('post_pos_sale_with_pricelist', {
      p_sales_id: draft.id,
      p_master_version: draft.master_version,
      p_posting_idempotency_key: postingIdempotencyKey,
    }),
  ),
)
const elapsedMs = Math.round(performance.now() - startedAt)

const results = responses.map((response) => response.data).filter(Boolean)
const shortageResult = results.find(
  (result) => result?.documentStatus === 'DRAFT',
)
assert(
  !shortageResult,
  `Server kept the Sale as Draft because stock/FIFO was insufficient: ${JSON.stringify(shortageResult?.shortages ?? [])}`,
)
const errors = responses
  .map((response) => response.error?.message)
  .filter(Boolean)
assert(errors.length === 0, `Concurrent RPC errors: ${errors.join(' | ')}`)

const firstPosts = results.filter(
  (result) => result?.idempotentReplay === false,
).length
const replays = results.filter(
  (result) => result?.idempotentReplay === true,
).length
assert(firstPosts === 1, `Expected one first Post, received ${firstPosts}`)
assert(
  replays === concurrency - 1,
  `Expected ${concurrency - 1} replays, received ${replays}`,
)
assert(
  results.every((result) => result?.documentStatus === 'POSTED'),
  'Not every concurrent response returned POSTED',
)

const finalSale = failOnError(
  await control
    .from('sales_headers')
    .select('document_status,posting_idempotency_key,invoice_no')
    .eq('company_id', companyId)
    .eq('id', draft.id)
    .single(),
  'Load final Sale',
)
assert(finalSale.document_status === 'POSTED', 'Sale is not POSTED')
assert(
  finalSale.posting_idempotency_key === postingIdempotencyKey,
  'Persisted posting key differs from stress key',
)

const after = {
  movements: await countRows(
    control,
    'stock_movements',
    (query) =>
      query
        .eq('company_id', companyId)
        .eq('reference_table', 'sales_headers')
        .eq('reference_id', draft.id),
    'Count Movement after',
  ),
  payments: await countRows(
    control,
    'sales_payments',
    (query) =>
      query.eq('company_id', companyId).eq('sales_id', draft.id),
    'Count Payment after',
  ),
  postAudits: await countRows(
    control,
    'sale_master_audit',
    (query) =>
      query
        .eq('company_id', companyId)
        .eq('sales_id', draft.id)
        .eq('action', 'POST'),
    'Count POST audit after',
  ),
}

assert(
  after.movements === expectedMovementCount,
  `Movement count ${after.movements}, expected ${expectedMovementCount}`,
)
assert(
  after.payments === expectedPaymentCount,
  `Payment count ${after.payments}, expected ${expectedPaymentCount}`,
)
assert(after.postAudits === 1, `POST audit count ${after.postAudits}, expected 1`)

const paymentKeys = failOnError(
  await control
    .from('sales_payments')
    .select('client_payment_key')
    .eq('company_id', companyId)
    .eq('sales_id', draft.id),
  'Load Payment leg identities',
)
assert(
  new Set(paymentKeys.map((row) => row.client_payment_key)).size ===
    paymentKeys.length,
  'Duplicate Payment leg identity persisted',
)

console.log(
  JSON.stringify(
    {
      status: 'PASS',
      draftNo,
      invoiceNo: finalSale.invoice_no,
      concurrentRequests: concurrency,
      firstPosts,
      idempotentReplays: replays,
      elapsedMs,
      finalEffects: after,
    },
    null,
    2,
  ),
)

await authClient.auth.signOut()
