import type { Session, User } from '@supabase/supabase-js'
import { supabase } from './supabase'

export type CompanyOption = {
  id: string
  name: string
  roleCode: string
}

export type TerminalOption = {
  id: string
  storeId: string
  code: string
  name: string
  storeName: string
}

export type WarehouseOption = {
  id: string
  storeId: string | null
  name: string
}

export type CashierSession = {
  id: string
  code: string
  terminalId: string
  warehouseId: string
  storeId: string
  openingCash: number
  expectedCash: number
  masterVersion: number
}

export type ProductOption = {
  productId: string
  productUomId: string
  sku: string
  name: string
  categoryName: string
  uomName: string
  factorToBase: number
  fallbackPrice: number
  availableQuantity: number | null
  allowDecimal: boolean
  decimalPrecision: number
  barcode: string | null
  isBundle: boolean
}

export type CustomerOption = {
  id: string
  name: string
  isWalkIn: boolean
  defaultPricelistId: string | null
}

export type PricelistOption = {
  id: string
  name: string
  scope: 'GLOBAL' | 'CUSTOMER'
  isDefault: boolean
}

export type PaymentMethodOption = {
  id: string
  name: string
  methodType: string
  proofRequired: boolean
  isDefault: boolean
  feeBearer: string | null
  feeEnabled: boolean
  feeType: 'PERCENT' | 'FIXED' | 'PERCENT_PLUS_FIXED' | null
  feePercent: number
  feeFixedAmount: number
}

export type DraftLine = {
  lineKey: string
  productUomId: string
  quantity: number
  lineDiscountType?: 'AMOUNT' | 'PERCENT'
  lineDiscountInput?: number
}

export type SaleDraft = {
  salesId: string
  draftNo: string
  clientTransactionId: string
  masterVersion: number
  grandTotalBeforeRounding: number
  roundingAdjustment: number
  grandTotalAfterRounding: number
}

export type SaleDraftListItem = {
  salesId: string
  draftNo: string
  draftLabel: string | null
  draftNotes: string | null
  draftReason: string | null
  customerId: string
  customerName: string
  storeId: string
  storeName: string
  createdBy: string
  createdByName: string
  createdAt: string
  updatedAt: string
  masterVersion: number
  grandTotal: number
  lineCount: number
  isStale: boolean
  lockOwnerId: string | null
  lockOwnerName: string | null
  lockSessionId: string | null
  lockHeartbeatAt: string | null
  lockExpired: boolean
  payloadSnapshot: DbRow
}

export type ResolvedSaleLine = {
  lineKey: string
  productUomId: string
  productName: string
  productSku: string
  uomName: string
  quantity: number
  unitPrice: number
  discount: number
  taxAmount: number
  lineTotal: number
}

export type SaleReceipt = {
  invoiceNo: string
  postedAt: string
  subtotal: number
  itemDiscount: number
  orderDiscount: number
  totalBeforeRounding: number
  roundingAdjustment: number
  grandTotal: number
  customerSurcharge: number
  amountPaid: number
  lines: Array<{
    productName: string
    sku: string
    uomName: string
    quantity: number
    unitPrice: number
    discount: number
    taxAmount: number
    lineTotal: number
  }>
  payments: Array<{
    paymentMethodName: string
    amount: number
    configuredFee: number
    customerSurcharge: number
    tenderedAmount: number
    changeAmount: number
    proofUrl?: string | null
  }>
}

export type BootstrapData = {
  terminals: TerminalOption[]
  warehouses: WarehouseOption[]
  openSession: CashierSession | null
}

export type CatalogData = {
  products: ProductOption[]
  customers: CustomerOption[]
  pricelists: PricelistOption[]
  paymentMethods: PaymentMethodOption[]
}

type DbRow = Record<string, unknown>

function numberValue(value: unknown): number {
  const parsed = Number(value)
  return Number.isFinite(parsed) ? parsed : 0
}

function message(error: unknown): string {
  if (error && typeof error === 'object' && 'message' in error) {
    return String(error.message)
  }
  return 'UNKNOWN_ERROR'
}

function throwIfError(error: unknown) {
  if (error) throw new Error(message(error))
}

export async function getCurrentSession(): Promise<Session | null> {
  const { data, error } = await supabase.auth.getSession()
  throwIfError(error)
  return data.session
}

export async function signIn(email: string, password: string) {
  const { data, error } = await supabase.auth.signInWithPassword({
    email: email.trim(),
    password,
  })
  throwIfError(error)
  return data.session
}

export async function signOut() {
  const { error } = await supabase.auth.signOut()
  throwIfError(error)
}

export async function loadCompanies(user: User): Promise<{
  companies: CompanyOption[]
  activeCompanyId: string | null
}> {
  const [{ data: profile, error: profileError }, { data: activeContext, error: contextError }] =
    await Promise.all([
      supabase.from('profiles').select('role').eq('id', user.id).maybeSingle(),
      supabase
        .from('user_active_company_contexts')
        .select('company_id')
        .eq('user_id', user.id)
        .maybeSingle(),
    ])
  throwIfError(profileError)
  throwIfError(contextError)

  let companies: CompanyOption[] = []
  if (profile?.role === 'super_admin') {
    const { data, error } = await supabase
      .from('companies')
      .select('id,company_name')
      .eq('status', 'ACTIVE')
      .order('company_name')
    throwIfError(error)
    companies = (data ?? []).map((row) => ({
      id: row.id,
      name: row.company_name,
      roleCode: 'SUPER_ADMIN',
    }))
  } else {
    const { data: memberships, error: membershipError } = await supabase
      .from('company_memberships')
      .select('company_id,role_code')
      .eq('user_id', user.id)
      .eq('status', 'ACTIVE')
    throwIfError(membershipError)
    const roleByCompany = new Map(
      (memberships ?? []).map((row) => [row.company_id, row.role_code]),
    )
    const ids = [...roleByCompany.keys()]
    if (ids.length > 0) {
      const { data, error } = await supabase
        .from('companies')
        .select('id,company_name')
        .in('id', ids)
        .eq('status', 'ACTIVE')
        .order('company_name')
      throwIfError(error)
      companies = (data ?? []).map((row) => ({
        id: row.id,
        name: row.company_name,
        roleCode: roleByCompany.get(row.id) ?? 'CASHIER',
      }))
    }
  }

  return {
    companies,
    activeCompanyId: activeContext?.company_id ?? null,
  }
}

export async function setActiveCompany(companyId: string) {
  const { data, error } = await supabase.rpc('set_active_company_context', {
    p_company_id: companyId,
    p_selection_source: 'POS_PWA_ONLINE',
  })
  throwIfError(error)
  return data
}

export async function loadBootstrap(
  companyId: string,
  userId: string,
  companyRoleCode: string,
): Promise<BootstrapData> {
  const [
    membershipsResult,
    storesResult,
    terminalsResult,
    warehousesResult,
    sessionResult,
  ] = await Promise.all([
    supabase
      .from('store_memberships')
      .select('store_id,role_code')
      .eq('company_id', companyId)
      .eq('user_id', userId)
      .eq('status', 'ACTIVE'),
    supabase
      .from('stores')
      .select('id,store_name')
      .eq('company_id', companyId)
      .eq('status', 'ACTIVE'),
    supabase
      .from('pos_terminals')
      .select('id,store_id,pos_code,pos_name')
      .eq('company_id', companyId)
      .eq('status', 'ACTIVE'),
    supabase
      .from('warehouses')
      .select('id,store_id,name')
      .eq('company_id', companyId)
      .eq('is_active', true)
      .eq('is_sale_source', true)
      .order('name'),
    supabase
      .from('cashier_sessions')
      .select(
        'id,session_code,pos_id,sales_warehouse_id,store_id,opening_cash_actual,expected_cash,master_version',
      )
      .eq('company_id', companyId)
      .eq('cashier_id', userId)
      .eq('status', 'OPEN')
      .maybeSingle(),
  ])
  for (const result of [
    membershipsResult,
    storesResult,
    terminalsResult,
    warehousesResult,
    sessionResult,
  ]) {
    throwIfError(result.error)
  }

  const posOperatorStoreIds = new Set(
    (membershipsResult.data ?? [])
      .filter((row) =>
        ['CASHIER', 'STORE_MANAGER'].includes(row.role_code),
      )
      .map((row) => row.store_id),
  )
  const inheritsCashierAccess = [
    'SUPER_ADMIN',
    'COMPANY_OWNER',
    'COMPANY_ADMIN',
  ].includes(companyRoleCode)
  const storeNames = new Map(
    (storesResult.data ?? []).map((row) => [row.id, row.store_name]),
  )
  const terminals = (terminalsResult.data ?? [])
    .filter(
      (row) => inheritsCashierAccess || posOperatorStoreIds.has(row.store_id),
    )
    .map((row) => ({
      id: row.id,
      storeId: row.store_id,
      code: row.pos_code,
      name: row.pos_name,
      storeName: storeNames.get(row.store_id) ?? 'Store',
    }))
  const warehouses = (warehousesResult.data ?? []).map((row) => ({
    id: row.id,
    storeId: row.store_id,
    name: row.name,
  }))
  const open = sessionResult.data

  return {
    terminals,
    warehouses,
    openSession: open
      ? {
          id: open.id,
          code: open.session_code,
          terminalId: open.pos_id,
          warehouseId: open.sales_warehouse_id,
          storeId: open.store_id,
          openingCash: numberValue(open.opening_cash_actual),
          expectedCash: numberValue(open.expected_cash),
          masterVersion: numberValue(open.master_version),
        }
      : null,
  }
}

export async function openCashierSession(
  terminalId: string,
  warehouseId: string,
  openingCash: number,
): Promise<CashierSession> {
  const { data, error } = await supabase.rpc('open_cashier_session', {
    p_pos_terminal_id: terminalId,
    p_sales_warehouse_id: warehouseId,
    p_opening_cash_actual: openingCash,
  })
  throwIfError(error)
  const result = data as DbRow
  return {
    id: String(result.cashierSessionId),
    code: String(result.sessionCode),
    terminalId,
    warehouseId,
    storeId: '',
    openingCash,
    expectedCash: openingCash,
    masterVersion: numberValue(result.masterVersion),
  }
}

export async function closeCashierSession(
  sessionId: string,
  masterVersion: number,
  closingCash: number,
) {
  const { data, error } = await supabase.rpc('close_cashier_session', {
    p_cashier_session_id: sessionId,
    p_master_version: masterVersion,
    p_closing_cash_actual: closingCash,
  })
  throwIfError(error)
  return data as DbRow
}

export async function loadCatalog(
  companyId: string,
  storeId: string,
  warehouseId: string,
): Promise<CatalogData> {
  const [
    productsResult,
    productUomsResult,
    uomsResult,
    categoriesResult,
    stocksResult,
    customersResult,
    pricelistsResult,
    pricelistAssignmentsResult,
    methodsResult,
    assignmentsResult,
  ] = await Promise.all([
    supabase
      .from('products')
      .select('id,sku,name,category_id,is_bundle')
      .eq('company_id', companyId)
      .eq('is_active', true),
    supabase
      .from('product_uoms')
      .select(
        'id,product_id,uom_id,factor_to_base,sale_price,barcode,is_active,sales_allowed',
      )
      .eq('company_id', companyId)
      .eq('is_active', true)
      .eq('sales_allowed', true),
    supabase
      .from('uoms')
      .select('id,name,allow_decimal,decimal_precision')
      .eq('company_id', companyId)
      .eq('is_active', true),
    supabase
      .from('product_categories')
      .select('id,category_name')
      .eq('company_id', companyId),
    supabase
      .from('product_stocks')
      .select('product_id,stock_qty')
      .eq('company_id', companyId)
      .eq('warehouse_id', warehouseId),
    supabase
      .from('customers')
      .select('id,name,is_system_customer,is_active,default_pricelist_id')
      .eq('company_id', companyId)
      .eq('is_active', true)
      .order('is_system_customer', { ascending: false })
      .order('name'),
    supabase
      .from('pricelists')
      .select(
        'id,name,scope,is_default,applies_all_stores,valid_from,valid_until',
      )
      .eq('company_id', companyId)
      .eq('is_active', true),
    supabase
      .from('pricelist_store_assignments')
      .select('pricelist_id,store_id')
      .eq('company_id', companyId)
      .eq('store_id', storeId),
    supabase
      .from('payment_methods')
      .select(
        'id,payment_method_name,method_type,proof_mode,is_default,available_all_stores,fee_bearer,fee_enabled,fee_type,fee_percent,fee_fixed_amount,is_active',
      )
      .eq('company_id', companyId)
      .eq('is_active', true),
    supabase
      .from('payment_method_store_assignments')
      .select('payment_method_id,store_id')
      .eq('company_id', companyId)
      .eq('store_id', storeId),
  ])
  for (const result of [
    productsResult,
    productUomsResult,
    uomsResult,
    categoriesResult,
    stocksResult,
    customersResult,
    pricelistsResult,
    pricelistAssignmentsResult,
    methodsResult,
    assignmentsResult,
  ]) {
    throwIfError(result.error)
  }

  const productsById = new Map(
    (productsResult.data ?? []).map((row) => [row.id, row]),
  )
  const uomsById = new Map((uomsResult.data ?? []).map((row) => [row.id, row]))
  const categoriesById = new Map(
    (categoriesResult.data ?? []).map((row) => [row.id, row.category_name]),
  )
  const stockByProduct = new Map(
    (stocksResult.data ?? []).map((row) => [
      row.product_id,
      numberValue(row.stock_qty),
    ]),
  )
  const products: ProductOption[] = []
  for (const row of productUomsResult.data ?? []) {
    const product = productsById.get(row.product_id)
    const uom = uomsById.get(row.uom_id)
    if (!product || !uom) continue
    const factor = numberValue(row.factor_to_base)
    products.push({
      productId: product.id,
      productUomId: row.id,
      sku: product.sku,
      name: product.name,
      categoryName: categoriesById.get(product.category_id) ?? 'Tanpa kategori',
      uomName: uom.name,
      factorToBase: factor,
      fallbackPrice: numberValue(row.sale_price),
      availableQuantity: product.is_bundle
        ? null
        : factor > 0
          ? Math.floor((stockByProduct.get(product.id) ?? 0) / factor)
          : 0,
      allowDecimal: Boolean(uom.allow_decimal),
      decimalPrecision: numberValue(uom.decimal_precision),
      barcode: row.barcode,
      isBundle: Boolean(product.is_bundle),
    })
  }

  const assignedMethodIds = new Set(
    (assignmentsResult.data ?? []).map((row) => row.payment_method_id),
  )
  const assignedPricelistIds = new Set(
    (pricelistAssignmentsResult.data ?? []).map((row) => row.pricelist_id),
  )
  const now = Date.now()
  const pricelists = (pricelistsResult.data ?? [])
    .filter((row) => {
      const validFrom = row.valid_from ? Date.parse(row.valid_from) : null
      const validUntil = row.valid_until ? Date.parse(row.valid_until) : null
      return (
        (row.applies_all_stores || assignedPricelistIds.has(row.id)) &&
        (validFrom === null || validFrom <= now) &&
        (validUntil === null || validUntil >= now)
      )
    })
    .map((row) => ({
      id: row.id,
      name: row.name,
      scope: row.scope as 'GLOBAL' | 'CUSTOMER',
      isDefault: Boolean(row.is_default),
    }))
    .sort(
      (a, b) =>
        Number(b.isDefault) - Number(a.isDefault) ||
        a.name.localeCompare(b.name),
    )
  const paymentMethods = (methodsResult.data ?? [])
    .filter(
      (row) =>
        (row.available_all_stores || assignedMethodIds.has(row.id)) &&
        !['CUSTOMER_BALANCE', 'KETUL_OFFSET', 'TEMPO'].includes(row.method_type),
    )
    .map((row) => ({
      id: row.id,
      name: row.payment_method_name,
      methodType: row.method_type,
      proofRequired: row.proof_mode === 'REQUIRED',
      isDefault: Boolean(row.is_default),
      feeBearer: row.fee_bearer,
      feeEnabled: Boolean(row.fee_enabled),
      feeType: row.fee_type as PaymentMethodOption['feeType'],
      feePercent: numberValue(row.fee_percent),
      feeFixedAmount: numberValue(row.fee_fixed_amount),
    }))
    .sort((a, b) => Number(b.isDefault) - Number(a.isDefault) || a.name.localeCompare(b.name))

  return {
    products: products.sort(
      (a, b) => a.name.localeCompare(b.name) || a.uomName.localeCompare(b.uomName),
    ),
    customers: (customersResult.data ?? []).map((row) => ({
      id: row.id,
      name: row.name,
      isWalkIn: Boolean(row.is_system_customer),
      defaultPricelistId: row.default_pricelist_id,
    })),
    pricelists,
    paymentMethods,
  }
}

export async function saveSaleDraft(input: {
  draft: SaleDraft | null
  clientTransactionId: string
  cashierSessionId: string
  customerId: string
  draftLabel: string
  draftNotes: string
  selectedPricelistId: string | null
  lines: DraftLine[]
  globalDiscount: number
  roundingDirection: 'NONE' | 'DOWN' | 'UP'
  isTempo: boolean
  dueDate: string | null
  payments: Array<{
    clientPaymentKey: string
    paymentMethodId: string
    amount: number
    tenderedAmount: number
    proofUrl?: string
  }>
}): Promise<SaleDraft> {
  const payload = {
    clientTransactionId: input.clientTransactionId,
    cashierSessionId: input.cashierSessionId,
    customerId: input.customerId,
    draftLabel: input.draftLabel.trim() || null,
    draftNotes: input.draftNotes.trim() || null,
    selectedPricelistId: input.selectedPricelistId,
    pricingSelectionSource: input.selectedPricelistId
      ? 'CASHIER_OVERRIDE'
      : 'AUTO',
    lines: input.lines,
    globalDiscount: input.globalDiscount,
    roundingDirection: input.roundingDirection,
    roundingIncrement: 100,
    isTempo: input.isTempo,
    dueDate: input.dueDate,
    payments: input.payments,
    ...(input.draft
      ? {
          saleId: input.draft.salesId,
          masterVersion: input.draft.masterVersion,
        }
      : {}),
  }
  const { data, error } = await supabase.rpc(
    'save_pos_sale_draft_with_pricelist',
    {
    p_payload: payload,
    },
  )
  throwIfError(error)
  const row = data as DbRow
  return {
    salesId: String(row.salesId),
    draftNo: String(row.draftNo ?? input.draft?.draftNo ?? ''),
    clientTransactionId: input.clientTransactionId,
    masterVersion: numberValue(row.masterVersion),
    grandTotalBeforeRounding: numberValue(row.grandTotalBeforeRounding),
    roundingAdjustment: numberValue(row.roundingAdjustment),
    grandTotalAfterRounding: numberValue(row.grandTotalAfterRounding),
  }
}

export async function listSaleDrafts(
  storeId: string,
): Promise<SaleDraftListItem[]> {
  const { data, error } = await supabase.rpc('list_pos_sale_drafts', {
    p_store_id: storeId,
  })
  throwIfError(error)
  const rows = Array.isArray(data) ? (data as DbRow[]) : []
  return rows.map((row) => ({
    salesId: String(row.salesId),
    draftNo: String(row.draftNo ?? ''),
    draftLabel: row.draftLabel ? String(row.draftLabel) : null,
    draftNotes: row.draftNotes ? String(row.draftNotes) : null,
    draftReason: row.draftReason ? String(row.draftReason) : null,
    customerId: String(row.customerId),
    customerName: String(row.customerName),
    storeId: String(row.storeId),
    storeName: String(row.storeName),
    createdBy: String(row.createdBy),
    createdByName: String(row.createdByName),
    createdAt: String(row.createdAt),
    updatedAt: String(row.updatedAt),
    masterVersion: numberValue(row.masterVersion),
    grandTotal: numberValue(row.grandTotal),
    lineCount: numberValue(row.lineCount),
    isStale: Boolean(row.isStale),
    lockOwnerId: row.lockOwnerId ? String(row.lockOwnerId) : null,
    lockOwnerName: row.lockOwnerName ? String(row.lockOwnerName) : null,
    lockSessionId: row.lockSessionId ? String(row.lockSessionId) : null,
    lockHeartbeatAt: row.lockHeartbeatAt
      ? String(row.lockHeartbeatAt)
      : null,
    lockExpired: Boolean(row.lockExpired),
    payloadSnapshot:
      row.payloadSnapshot && typeof row.payloadSnapshot === 'object'
        ? (row.payloadSnapshot as DbRow)
        : {},
  }))
}

export async function acquireSaleDraftLock(
  salesId: string,
  cashierSessionId: string,
  confirmTakeover = false,
) {
  const { data, error } = await supabase.rpc('acquire_pos_sale_draft_lock', {
    p_sales_id: salesId,
    p_cashier_session_id: cashierSessionId,
    p_confirm_takeover: confirmTakeover,
  })
  throwIfError(error)
  return data as DbRow
}

export async function heartbeatSaleDraftLock(
  salesId: string,
  cashierSessionId: string,
) {
  const { data, error } = await supabase.rpc(
    'heartbeat_pos_sale_draft_lock',
    {
      p_sales_id: salesId,
      p_cashier_session_id: cashierSessionId,
    },
  )
  throwIfError(error)
  return data as DbRow
}

export async function releaseSaleDraftLock(
  salesId: string,
  cashierSessionId: string,
  force = false,
  reason: string | null = null,
) {
  const { data, error } = await supabase.rpc('release_pos_sale_draft_lock', {
    p_sales_id: salesId,
    p_cashier_session_id: cashierSessionId,
    p_force: force,
    p_reason: reason,
  })
  throwIfError(error)
  return data as DbRow
}

export async function cancelSaleDraft(
  salesId: string,
  masterVersion: number,
  cashierSessionId: string,
  reason: string | null,
) {
  const { data, error } = await supabase.rpc('cancel_pos_sale_draft', {
    p_sales_id: salesId,
    p_master_version: masterVersion,
    p_cashier_session_id: cashierSessionId,
    p_reason: reason,
  })
  throwIfError(error)
  return data as DbRow
}

export async function loadResolvedSaleLines(
  companyId: string,
  salesId: string,
): Promise<ResolvedSaleLine[]> {
  const { data, error } = await supabase
    .from('sales_details')
    .select(
      'client_line_key,product_uom_id,product_name_snapshot,product_sku_snapshot,sale_uom_name_snapshot,qty,resolved_unit_price,line_discount_amount,allocated_order_discount_amount,tax_amount,line_total',
    )
    .eq('company_id', companyId)
    .eq('sales_id', salesId)
    .order('id')
  throwIfError(error)
  return (data ?? []).map((row) => ({
    lineKey: row.client_line_key,
    productUomId: row.product_uom_id,
    productName: row.product_name_snapshot,
    productSku: row.product_sku_snapshot,
    uomName: row.sale_uom_name_snapshot,
    quantity: numberValue(row.qty),
    unitPrice: numberValue(row.resolved_unit_price),
    discount:
      numberValue(row.line_discount_amount) +
      numberValue(row.allocated_order_discount_amount),
    taxAmount: numberValue(row.tax_amount),
    lineTotal: numberValue(row.line_total),
  }))
}

export async function postSale(
  salesId: string,
  masterVersion: number,
  idempotencyKey: string,
) {
  const { data, error } = await supabase.rpc(
    'post_pos_sale_with_pricelist',
    {
    p_sales_id: salesId,
    p_master_version: masterVersion,
    p_posting_idempotency_key: idempotencyKey,
    },
  )
  throwIfError(error)
  return data as DbRow
}

export async function loadReceipt(
  companyId: string,
  salesId: string,
): Promise<SaleReceipt> {
  const { data, error } = await supabase
    .from('sales_headers')
    .select('receipt_snapshot')
    .eq('company_id', companyId)
    .eq('id', salesId)
    .single()
  throwIfError(error)
  if (!data?.receipt_snapshot) throw new Error('RECEIPT_SNAPSHOT_NOT_FOUND')
  return data.receipt_snapshot as SaleReceipt
}
