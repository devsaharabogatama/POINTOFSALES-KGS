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
  hiddenFeatureKeys: string[]
  allowPriceOverride: boolean
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

export type PurchaseProductUomOption = {
  productId: string
  uomId: string
  sku: string
  productName: string
  uomName: string
  factorToBase: number
  allowDecimal: boolean
  decimalPrecision: number
}

export type StockRequestSummary = {
  id: string
  requestNo: string
  neededDate: string | null
  notes: string | null
  status: string
  lineCount: number
  requestedTotalBaseQty: number
  masterVersion: number
  requestedAt: string
}

export type StockRequestLineInput = {
  clientLineKey: string
  productId: string
  uomId: string
  quantity: number
  notes: string | null
}

export type GoodsReceiptUomOption = {
  uomId: string
  uomName: string
  factorToBase: number
  allowDecimal: boolean
  decimalPrecision: number
}

export type GoodsReceiptOrderLine = {
  id: string
  productId: string
  productName: string
  orderedUomId: string
  orderedUomName: string
  orderedQuantity: number
  orderedBaseQuantity: number
  remainingBaseQuantity: number
  options: GoodsReceiptUomOption[]
}

export type GoodsReceiptOrder = {
  id: string
  orderNo: string
  supplierName: string
  warehouseName: string
  status: string
  expectedDate: string | null
  lines: GoodsReceiptOrderLine[]
}

export type GoodsReceiptDraftLine = {
  clientLineKey: string
  supplierOrderLineId: string
  receivedUomId: string
  receivedQuantity: number
  acceptedGoodQuantity: number
  damagedQuantity: number
  rejectedQuantity: number
}

export type GoodsReceiptDraft = {
  id: string
  receiptNo: string
  supplierOrderId: string
  supplierDeliveryNo: string | null
  notes: string | null
  masterVersion: number
  lines: GoodsReceiptDraftLine[]
}

export type GoodsReceiptLineInput = {
  clientLineKey: string
  supplierOrderLineId: string
  receivedUomId: string
  receivedQty: number
  acceptedGoodQty: number
  damagedQty: number
  rejectedQty: number
}

export type PurchaseReturnUomOption = GoodsReceiptUomOption

export type PurchaseReturnAllocation = {
  id: string
  receiptLineId: string
  productId: string
  productName: string
  condition: 'GOOD' | 'DAMAGED'
  warehouseId: string
  baseUomName: string
  availableBaseQuantity: number
  options: PurchaseReturnUomOption[]
}

export type PurchaseReturnSource = {
  key: string
  receiptId: string
  receiptNo: string
  orderNo: string
  supplierName: string
  warehouseId: string
  warehouseName: string
  receivedAt: string
  allocations: PurchaseReturnAllocation[]
}

export type PurchaseReturnDraftLine = {
  clientLineKey: string
  sourceConditionAllocationId: string
  returnUomId: string
  returnQuantity: number
}

export type PurchaseReturnDraft = {
  id: string
  returnNo: string
  sourceReceiptId: string
  sourceWarehouseId: string
  returnDate: string
  returnReason: string
  supplierDocumentNo: string | null
  notes: string | null
  reviewStatus: 'PENDING' | 'APPROVED'
  masterVersion: number
  lines: PurchaseReturnDraftLine[]
}

export type CustomerOption = {
  id: string
  name: string
  phone: string
  address: string
  isWalkIn: boolean
  defaultPricelistId: string | null
  currentBalance: number
  creditLimit: number
  creditTermDays: number | null
}

export type QuickCustomerInput = {
  name: string
  type: 'INDIVIDUAL' | 'BUSINESS'
  phone: string
  email: string
  address: string
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

export type ExpenseCategoryOption = {
  id: string
  name: string
  evidenceRequired: boolean
  defaultPaymentMethodId: string | null
}

export type ExpenseRequestResult = {
  documentId: string
  documentNo: string
  status: 'DRAFT' | 'SUBMITTED' | 'APPROVED'
  masterVersion: number
}

export type ApprovedCashExpense = {
  documentId: string
  documentNo: string
  categoryName: string
  responsiblePartyName: string
  requestedAmount: number
  paymentMethodId: string
  paymentMethodName: string
  description: string
  recipient: string | null
  evidenceUrl: string | null
  expectedSettlementDate: string | null
  masterVersion: number
  approvedAt: string
}

export type ExpenseDisbursementResult = {
  documentId: string
  disbursementId: string
  status: 'DISBURSED'
  masterVersion: number
  amount: number
  paymentMethodType: string
  expectedCashAfter: number | null
  idempotentReplay: boolean
}

export type OutstandingExpense = {
  documentId: string
  documentNo: string
  categoryName: string
  responsiblePartyName: string
  paymentMethodId: string
  paymentMethodName: string
  paymentMethodType: string
  disbursedAmount: number
  actualExpenseAmount: number
  returnedAmount: number
  outstandingAmount: number
  evidenceRequired: boolean
  settlementPending: boolean
  masterVersion: number
  status: 'DISBURSED' | 'PARTIALLY_SETTLED'
}

export type ApprovedAdditionalCashExpense = {
  requestId: string
  requestMasterVersion: number
  documentId: string
  documentNo: string
  documentMasterVersion: number
  categoryName: string
  responsiblePartyName: string
  amount: number
  paymentMethodId: string
  paymentMethodName: string
  evidenceUrl: string | null
  requestedAt: string
  approvedAt: string
}

export type CashDepositEligibleSession = {
  sessionId: string
  sessionCode: string
  cashierId: string
  cashierName: string
  closedAt: string
  closingCashActual: number
  postedDepositAllocations: number
  availableDepositAmount: number
}

export type CashDepositDraftResult = {
  depositDocumentId: string
  depositNo: string | null
  status: 'DRAFT' | 'SUBMITTED'
  masterVersion: number
  totalExpectedDeposit: number
  actualDepositAmount: number
  depositVariance: number
  varianceType: 'MATCHED' | 'UNDER_DEPOSIT' | 'OVER_DEPOSIT'
  idempotentReplay: boolean
}

export type DraftLine = {
  lineKey: string
  productUomId: string
  quantity: number
  lineDiscountType?: 'AMOUNT' | 'PERCENT'
  lineDiscountInput?: number
  overrideUnitPrice?: number
}

export type SaleDraft = {
  salesId: string
  draftNo: string
  clientTransactionId: string
  transactionAt: string
  transactionDateSource: 'SERVER_CREATED' | 'CASHIER_SELECTED'
  orderTimingMode: 'IMMEDIATE' | 'BACKORDER' | 'SCHEDULED'
  plannedOrderDate: string | null
  operationalStatus: 'ACTIVE' | 'SCHEDULED'
  masterVersion: number
  grandTotalBeforeRounding: number
  roundingAdjustment: number
  grandTotalAfterRounding: number
  deliveryFeeAmount: number
  deliveryFeeInvoiceDisplayMode: 'SHOW_SEPARATE' | 'HIDE_BREAKDOWN'
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
  transactionAt: string
  transactionDateSource: 'SERVER_CREATED' | 'CASHIER_SELECTED'
  orderTimingMode: 'IMMEDIATE' | 'BACKORDER' | 'SCHEDULED'
  plannedOrderDate: string | null
  operationalStatus: 'ACTIVE' | 'SCHEDULED'
  canPost: boolean
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

export type SalesOrderReservationLine = {
  id: string
  salesId: string
  productSku: string
  productName: string
  warehouseName: string
  requestedBaseQuantity: number
  reservedBaseQuantity: number
  releasedBaseQuantity: number
  dispatchedBaseQuantity: number
  availableBaseQuantitySnapshot: number
  shortageBaseQuantity: number
}

export type SalesOrderListItem = {
  salesId: string
  orderNo: string
  storeId: string
  storeName: string
  customerId: string
  customerName: string
  orderTimingMode: 'IMMEDIATE' | 'BACKORDER' | 'SCHEDULED'
  plannedOrderDate: string | null
  orderRuntimeStatus:
    | 'CONFIRMED'
    | 'RESERVED'
    | 'PARTIALLY_DISPATCHED'
    | 'DISPATCHED'
    | 'DELIVERED'
  grandTotal: number
  masterVersion: number
  reservationVersion: number
  reservationId: string
  reservationStatus: string
  totalReservedBaseQuantity: number
  totalReleasedBaseQuantity: number
  totalDispatchedBaseQuantity: number
  confirmedAt: string
  updatedAt: string
  lines: SalesOrderReservationLine[]
}

export type SalesOrderWorkspace = {
  orders: SalesOrderListItem[]
}

export type ResolvedSaleLine = {
  lineKey: string
  productUomId: string
  productName: string
  productSku: string
  uomName: string
  quantity: number
  unitPrice: number
  canonicalUnitPrice: number
  priceOverrideApplied: boolean
  discount: number
  taxAmount: number
  lineTotal: number
}

export type PosPricePreviewLine = {
  lineKey: string
  productUomId: string
  productName: string
  productSku: string
  uomName: string
  quantity: number
  baseUnitPrice: number
  unitPrice: number
  pricelistId: string | null
  pricelistRuleId: string | null
  pricelistName: string | null
  pricingSelectionSource: 'AUTO' | 'CASHIER_OVERRIDE'
}

export type SaleReceipt = {
  saleId: string
  invoiceNo: string
  postedAt: string
  subtotal: number
  itemDiscount: number
  orderDiscount: number
  totalBeforeRounding: number
  roundingAdjustment: number
  grandTotal: number
  deliveryFeeAmount?: number
  deliveryFeeInvoiceDisplayMode?: 'SHOW_SEPARATE' | 'HIDE_BREAKDOWN'
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
    overpaymentDisposition?: 'NONE' | 'RETURNED' | 'CUSTOMER_BALANCE' | null
    customerBalanceCreditAmount?: number
    customerBalanceLedgerEntryId?: string | null
    customerBalanceUsageAmount?: number
    customerBalanceUsageLedgerEntryId?: string | null
    proofUrl?: string | null
  }>
}

export type SalesInvoiceDocument = {
  invoiceSnapshotId: string
  invoiceNo: string
  snapshotVersion: number
  snapshotProvenance: 'LIVE_POST' | 'LEGACY_CUTOVER'
  snapshot: Record<string, unknown>
}

export type SalesDeliveryDocument = {
  deliveryDocumentId: string
  deliveryNo: string
  status: 'READY' | 'DISPATCHED' | 'DELIVERED' | 'CANCELED'
  masterVersion: number
  snapshot: Record<string, unknown>
  lines: Array<Record<string, unknown>>
}

export type ReturnableSaleLine = {
  sourceSalesDetailId: string
  productId: string
  productName: string
  uomName: string
  soldQuantity: number
  returnedQuantity: number
  remainingQuantity: number
  refundableLineAmount: number
}

export type ReturnableSale = {
  salesId: string
  invoiceNo: string
  transactionDate: string
  storeId: string
  customerId: string
  grandTotal: number
  priorRefundTotal: number
  deliveryFeeAmount: number
  deliveryFeeRefunded: number
  lines: ReturnableSaleLine[]
}

export type DamagedWarehouseOption = {
  id: string
  name: string
}

export type SalesReturnDraftResult = {
  documentId: string
  returnNo: string
  status: 'DRAFT'
  masterVersion: number
  refundTotal: number
}

export type BootstrapData = {
  terminals: TerminalOption[]
  warehouses: WarehouseOption[]
  openSession: CashierSession | null
  deliveryDocumentCreationPolicy: 'DELIVERY_ONLY' | 'ALL_POSTED_SALES'
}

export type CatalogData = {
  products: ProductOption[]
  customers: CustomerOption[]
  pricelists: PricelistOption[]
  paymentMethods: PaymentMethodOption[]
  expenseCategories: ExpenseCategoryOption[]
  expenseEnabled: boolean
  customerBalanceCreditEnabled: boolean
  customerBalanceTenderEnabled: boolean
}

export type NegativeStockReadiness = {
  enabled: boolean
  blockerCode: string | null
  onlineOnly: boolean
  bundleSupported: boolean
  requireReason: boolean
  companyLimitBaseQty: number | null
  userLimitBaseQty: number | null
  warehouseId: string
  permissionValidUntil: string | null
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
  // Backoffice and PWA commonly run side-by-side with the same Supabase user.
  // A global sign-out revokes every refresh token for that user and makes the
  // other application appear to log out by itself on its next token refresh.
  const { error } = await supabase.auth.signOut({ scope: 'local' })
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
    brandingResult,
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
      .select('id,store_id,pos_code,pos_name,hidden_feature_keys,allow_price_override')
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
    supabase.rpc('get_company_branding'),
  ])
  for (const result of [
    membershipsResult,
    storesResult,
    terminalsResult,
    warehousesResult,
    sessionResult,
    brandingResult,
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
      hiddenFeatureKeys: Array.isArray(row.hidden_feature_keys)
        ? row.hidden_feature_keys.map(String)
        : [],
      allowPriceOverride: Boolean(row.allow_price_override),
    }))
  const warehouses = (warehousesResult.data ?? []).map((row) => ({
    id: row.id,
    storeId: row.store_id,
    name: row.name,
  }))
  const open = sessionResult.data
  const branding = (brandingResult.data ?? {}) as Record<string, unknown>

  return {
    terminals,
    warehouses,
    deliveryDocumentCreationPolicy:
      branding.deliveryDocumentCreationPolicy === 'ALL_POSTED_SALES'
        ? 'ALL_POSTED_SALES'
        : 'DELIVERY_ONLY',
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

export async function loadNegativeStockReadiness(): Promise<NegativeStockReadiness> {
  const { data, error } = await supabase.rpc('get_pos_negative_stock_readiness')
  throwIfError(error)
  const row = (data ?? {}) as DbRow
  return {
    enabled: Boolean(row.enabled),
    blockerCode: row.blockerCode ? String(row.blockerCode) : null,
    onlineOnly: Boolean(row.onlineOnly),
    bundleSupported: Boolean(row.bundleSupported),
    requireReason: Boolean(row.requireReason),
    companyLimitBaseQty: row.companyLimitBaseQty === null ||
      row.companyLimitBaseQty === undefined
      ? null
      : numberValue(row.companyLimitBaseQty),
    userLimitBaseQty: row.userLimitBaseQty === null ||
      row.userLimitBaseQty === undefined
      ? null
      : numberValue(row.userLimitBaseQty),
    warehouseId: String(row.warehouseId ?? ''),
    permissionValidUntil: row.permissionValidUntil
      ? String(row.permissionValidUntil)
      : null,
  }
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
    stockAvailabilityResult,
    customersResult,
    pricelistsResult,
    methodsResult,
    expenseCategoriesResult,
    expenseFeatureResult,
    customerBalanceFeatureResult,
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
    supabase.rpc('get_pos_stock_availability', {
      p_store_id: storeId,
      p_warehouse_id: warehouseId,
    }),
    supabase.rpc('get_pos_customer_references'),
    supabase.rpc('get_pos_pricelist_references', { p_store_id: storeId }),
    supabase.rpc('get_pos_payment_method_references', { p_store_id: storeId }),
    supabase.rpc('get_pos_expense_categories', { p_store_id: storeId }),
    supabase
      .from('company_features')
      .select('is_enabled')
      .eq('company_id', companyId)
      .eq('feature_code', 'expense_enabled')
      .maybeSingle(),
    supabase
      .from('company_features')
      .select('is_enabled')
      .eq('company_id', companyId)
      .eq('feature_code', 'customer_balance_enabled')
      .maybeSingle(),
  ])
  for (const result of [
    productsResult,
    productUomsResult,
    uomsResult,
    categoriesResult,
    stockAvailabilityResult,
    customersResult,
    pricelistsResult,
    methodsResult,
    expenseCategoriesResult,
    expenseFeatureResult,
    customerBalanceFeatureResult,
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
  const reservationAvailabilityPayload = (stockAvailabilityResult.data ?? {}) as DbRow
  if (numberValue(reservationAvailabilityPayload.reservationReadModelVersion) !== 1) {
    throw new Error('POS_STOCK_AVAILABILITY_CONTRACT_MISMATCH')
  }
  const availableByProduct = new Map(
    (Array.isArray(reservationAvailabilityPayload.availability)
      ? reservationAvailabilityPayload.availability as DbRow[]
      : [])
      .map((row) => [
        String(row.stock_product_id ?? ''),
        numberValue(row.available_to_sell_base_qty),
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
          ? Math.floor((availableByProduct.get(product.id) ??
              0) / factor)
          : 0,
      allowDecimal: Boolean(uom.allow_decimal),
      decimalPrecision: numberValue(uom.decimal_precision),
      barcode: row.barcode,
      isBundle: Boolean(product.is_bundle),
    })
  }

  const now = Date.now()
  const pricelistRows = (pricelistsResult.data ?? []) as Array<{
    id: string
    name: string
    scope: 'GLOBAL' | 'CUSTOMER'
    is_default: boolean
    applies_all_stores: boolean
    valid_from: string | null
    valid_until: string | null
  }>
  const pricelists = pricelistRows
    .filter((row) => {
      const validFrom = row.valid_from ? Date.parse(row.valid_from) : null
      const validUntil = row.valid_until ? Date.parse(row.valid_until) : null
      return (
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
  const rawPaymentMethods = (methodsResult.data ?? []) as Array<{
    id: string; payment_method_name: string; method_type: string
    proof_mode: string; is_default: boolean; fee_bearer: string | null
    fee_enabled: boolean; fee_type: string | null
    fee_percent: number | string | null; fee_fixed_amount: number | string | null
  }>
  // ACP-6D closes direct browser reads of the Customer Balance policy table.
  // The open-session reference RPC only returns the internal Balance method
  // while server policy permits ACTIVE or WIND_DOWN tender usage.
  const customerBalanceTenderEnabled = rawPaymentMethods.some(
    (row) => row.method_type === 'CUSTOMER_BALANCE',
  )
  const paymentMethods = rawPaymentMethods
    .filter(
      (row) =>
        !['KETUL_OFFSET', 'TEMPO'].includes(row.method_type) &&
        (row.method_type !== 'CUSTOMER_BALANCE' ||
          customerBalanceTenderEnabled),
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

  const customerRows = (customersResult.data ?? []) as Array<{
    id: string
    name: string
    phone: string | null
    address: string | null
    is_system_customer: boolean
    default_pricelist_id: string | null
    current_balance: number | string
    credit_limit: number | string
    credit_term_days: number | string | null
  }>

  return {
    products: products.sort(
      (a, b) => a.name.localeCompare(b.name) || a.uomName.localeCompare(b.uomName),
    ),
    customers: customerRows.map((row) => ({
      id: row.id,
      name: row.name,
      phone: row.phone ?? '',
      address: row.address ?? '',
      isWalkIn: Boolean(row.is_system_customer),
      defaultPricelistId: row.default_pricelist_id,
      currentBalance: numberValue(row.current_balance),
      creditLimit: numberValue(row.credit_limit),
      creditTermDays: row.credit_term_days === null || row.credit_term_days === undefined
        ? null
        : numberValue(row.credit_term_days),
    })),
    pricelists,
    paymentMethods,
    expenseCategories: (((expenseCategoriesResult.data ?? {}) as DbRow)
      .categories as DbRow[] ?? []).map((row) => ({
      id: String(row.id),
      name: String(row.category_name),
      evidenceRequired: row.evidence_policy === 'REQUIRED',
      defaultPaymentMethodId: row.default_payment_method_id
        ? String(row.default_payment_method_id)
        : null,
    })),
    expenseEnabled: Boolean(expenseFeatureResult.data?.is_enabled),
    customerBalanceCreditEnabled:
      Boolean(customerBalanceFeatureResult.data?.is_enabled) &&
      customerBalanceTenderEnabled,
    customerBalanceTenderEnabled,
  }
}

export async function loadStockRequestWorkspace(
  companyId: string,
  cashierSessionId: string,
) {
  const { data, error } = await supabase.rpc('get_pos_stock_request_workspace', {
    p_cashier_session_id: cashierSessionId,
  })
  throwIfError(error)
  const workspace = (data ?? {}) as {
    options?: Array<{
      product_id: string
      uom_id: string
      sku: string
      product_name: string
      uom_name: string
      factor_to_base: number | string
      allow_decimal: boolean
      decimal_precision: number | string
    }>
    documents?: Array<{
      id: string
      request_no: string
      needed_date: string | null
      notes: string | null
      status: string
      line_count: number | string
      requested_total_base_qty: number | string
      master_version: number | string
      requested_at: string
    }>
  }
  const options: PurchaseProductUomOption[] = (workspace.options ?? []).map(
    (row) => ({
      productId: row.product_id,
      uomId: row.uom_id,
      sku: row.sku,
      productName: row.product_name,
      uomName: row.uom_name,
      factorToBase: numberValue(row.factor_to_base),
      allowDecimal: Boolean(row.allow_decimal),
      decimalPrecision: numberValue(row.decimal_precision),
    }),
  )
  options.sort((a, b) =>
    `${a.productName} ${a.uomName}`.localeCompare(`${b.productName} ${b.uomName}`),
  )
  const documents: StockRequestSummary[] = (workspace.documents ?? []).map(
    (row) => ({
      id: row.id,
      requestNo: row.request_no,
      neededDate: row.needed_date,
      notes: row.notes,
      status: row.status,
      lineCount: numberValue(row.line_count),
      requestedTotalBaseQty: numberValue(row.requested_total_base_qty),
      masterVersion: numberValue(row.master_version),
      requestedAt: row.requested_at,
    }),
  )
  return { companyId, options, documents }
}

export async function createStockRequest(input: {
  cashierSessionId: string
  neededDate: string | null
  notes: string | null
  lines: StockRequestLineInput[]
}) {
  const { data, error } = await supabase.rpc('save_stock_request', {
    p_document_id: null,
    p_master_version: null,
    p_cashier_session_id: input.cashierSessionId,
    p_needed_date: input.neededDate,
    p_notes: input.notes,
    p_lines: input.lines,
  })
  throwIfError(error)
  return data as { documentId: string; requestNo: string; masterVersion: number }
}

export async function submitStockRequest(documentId: string, masterVersion: number) {
  const { data, error } = await supabase.rpc('submit_stock_request', {
    p_document_id: documentId,
    p_master_version: masterVersion,
  })
  throwIfError(error)
  return data as { documentId: string; requestNo: string; status: string }
}

export async function loadGoodsReceiptWorkspace(
  companyId: string,
  storeId: string,
  cashierSessionId: string,
) {
  const [ordersResult, draftsResult] = await Promise.all([
    supabase.rpc('get_pos_goods_receipt_supplier_orders', {
      p_cashier_session_id: cashierSessionId,
    }),
    supabase
      .from('goods_receipt_documents')
      .select('id,receipt_no,supplier_order_id,supplier_delivery_no,notes,master_version')
      .eq('company_id', companyId)
      .eq('store_id', storeId)
      .eq('receiving_session_id', cashierSessionId)
      .eq('status', 'DRAFT')
      .order('created_at', { ascending: false }),
  ])
  throwIfError(ordersResult.error)
  throwIfError(draftsResult.error)

  const orderWorkspace = (ordersResult.data ?? {}) as {
    orders?: Array<{
      id:string;order_no:string;supplier_id:string;supplier_name:string
      destination_warehouse_id:string;warehouse_name:string;status:string
      expected_date:string|null
    }>
    lines?: Array<{
      id:string;document_id:string;product_id:string;ordered_uom_id:string
      ordered_qty:number|string;ordered_base_qty:number|string
      product_name_snapshot:string;ordered_uom_name_snapshot:string
    }>
  }
  const orderRows = orderWorkspace.orders ?? []
  const draftRows = draftsResult.data ?? []
  const orderIds = [...new Set([
    ...orderRows.map((row) => row.id),
    ...draftRows.map((row) => row.supplier_order_id),
  ])]
  if (orderIds.length === 0) return { orders: [], drafts: [] }

  const [orderLinesResult, postedDocumentsResult, draftLinesResult] =
    await Promise.all([
      Promise.resolve({ data: orderWorkspace.lines ?? [], error: null }),
      supabase
        .from('goods_receipt_documents')
        .select('id,supplier_order_id')
        .eq('company_id', companyId)
        .in('supplier_order_id', orderIds)
        .eq('status', 'POSTED'),
      draftRows.length === 0
        ? Promise.resolve({ data: [], error: null })
        : supabase
            .from('goods_receipt_lines')
            .select('document_id,client_line_key,supplier_order_line_id,received_uom_id,received_qty,accepted_good_qty,damaged_qty,rejected_qty')
            .eq('company_id', companyId)
            .in('document_id', draftRows.map((row) => row.id))
            .order('line_no'),
    ])
  throwIfError(orderLinesResult.error)
  throwIfError(postedDocumentsResult.error)
  throwIfError(draftLinesResult.error)

  const postedDocumentIds=(postedDocumentsResult.data ?? []).map((row) => row.id)
  const postedLinesResult = postedDocumentIds.length === 0
    ? { data: [], error: null }
    : await supabase
        .from('goods_receipt_lines')
        .select('supplier_order_line_id,received_base_qty')
        .eq('company_id', companyId)
        .in('document_id', postedDocumentIds)
  throwIfError(postedLinesResult.error)

  const productIds=[...new Set((orderLinesResult.data ?? []).map((row) => row.product_id))]
  const [productUomsResult] = await Promise.all([
    productIds.length === 0
      ? Promise.resolve({ data: [], error: null })
      : supabase
          .from('product_uoms')
          .select('product_id,uom_id,factor_to_base')
          .eq('company_id', companyId)
          .eq('is_active', true)
          .eq('purchase_allowed', true)
          .in('product_id', productIds),
  ])
  throwIfError(productUomsResult.error)

  const uomIds=[...new Set((productUomsResult.data ?? []).map((row) => row.uom_id))]
  const uomsResult = uomIds.length === 0
    ? { data: [], error: null }
    : await supabase
        .from('uoms')
        .select('id,name,allow_decimal,decimal_precision')
        .eq('company_id', companyId)
        .in('id', uomIds)
  throwIfError(uomsResult.error)

  const supplierNames=new Map(orderRows.map((row) => [row.supplier_id,row.supplier_name]))
  const warehouseNames=new Map(orderRows.map((row) => [row.destination_warehouse_id,row.warehouse_name]))
  const uoms=new Map((uomsResult.data ?? []).map((row) => [row.id,row]))
  const optionsByProduct=new Map<string,GoodsReceiptUomOption[]>()
  for (const row of productUomsResult.data ?? []) {
    const uom=uoms.get(row.uom_id)
    if (!uom) continue
    const options=optionsByProduct.get(row.product_id) ?? []
    options.push({
      uomId:row.uom_id,uomName:uom.name,
      factorToBase:numberValue(row.factor_to_base),
      allowDecimal:Boolean(uom.allow_decimal),
      decimalPrecision:numberValue(uom.decimal_precision),
    })
    optionsByProduct.set(row.product_id,options)
  }
  for (const options of optionsByProduct.values()) {
    options.sort((a,b) => b.factorToBase-a.factorToBase || a.uomName.localeCompare(b.uomName))
  }
  const receivedByLine=new Map<string,number>()
  for (const row of postedLinesResult.data ?? []) {
    receivedByLine.set(row.supplier_order_line_id,
      (receivedByLine.get(row.supplier_order_line_id) ?? 0)+numberValue(row.received_base_qty))
  }
  const linesByOrder=new Map<string,GoodsReceiptOrderLine[]>()
  for (const row of orderLinesResult.data ?? []) {
    const lines=linesByOrder.get(row.document_id) ?? []
    lines.push({
      id:row.id,productId:row.product_id,productName:row.product_name_snapshot,
      orderedUomId:row.ordered_uom_id,orderedUomName:row.ordered_uom_name_snapshot,
      orderedQuantity:numberValue(row.ordered_qty),
      orderedBaseQuantity:numberValue(row.ordered_base_qty),
      remainingBaseQuantity:Math.max(0,numberValue(row.ordered_base_qty)-(receivedByLine.get(row.id) ?? 0)),
      options:optionsByProduct.get(row.product_id) ?? [],
    })
    linesByOrder.set(row.document_id,lines)
  }
  const eligibleOrderIds=new Set(orderRows.map((row) => row.id))
  const orders:GoodsReceiptOrder[]=orderRows.map((row) => ({
    id:row.id,orderNo:row.order_no,
    supplierName:supplierNames.get(row.supplier_id) ?? 'Supplier',
    warehouseName:warehouseNames.get(row.destination_warehouse_id) ?? 'Gudang tujuan',
    status:row.status,expectedDate:row.expected_date,
    lines:(linesByOrder.get(row.id) ?? []).filter((line) => line.options.length>0),
  })).filter((order) => order.lines.some((line) => line.remainingBaseQuantity>0))
  const draftLinesByDocument=new Map<string,GoodsReceiptDraftLine[]>()
  for (const row of draftLinesResult.data ?? []) {
    const lines=draftLinesByDocument.get(row.document_id) ?? []
    lines.push({
      clientLineKey:row.client_line_key,supplierOrderLineId:row.supplier_order_line_id,
      receivedUomId:row.received_uom_id,receivedQuantity:numberValue(row.received_qty),
      acceptedGoodQuantity:numberValue(row.accepted_good_qty),
      damagedQuantity:numberValue(row.damaged_qty),rejectedQuantity:numberValue(row.rejected_qty),
    })
    draftLinesByDocument.set(row.document_id,lines)
  }
  const drafts:GoodsReceiptDraft[]=draftRows.map((row) => ({
    id:row.id,receiptNo:row.receipt_no,supplierOrderId:row.supplier_order_id,
    supplierDeliveryNo:row.supplier_delivery_no,notes:row.notes,
    masterVersion:numberValue(row.master_version),
    lines:draftLinesByDocument.get(row.id) ?? [],
  })).filter((draft) => eligibleOrderIds.has(draft.supplierOrderId))
  return { orders, drafts }
}

export async function saveGoodsReceipt(input:{
  documentId:string|null
  masterVersion:number|null
  cashierSessionId:string
  supplierOrderId:string
  supplierDeliveryNo:string|null
  notes:string|null
  lines:GoodsReceiptLineInput[]
}) {
  const { data,error }=await supabase.rpc('save_goods_receipt',{
    p_document_id:input.documentId,p_master_version:input.masterVersion,
    p_cashier_session_id:input.cashierSessionId,
    p_supplier_order_id:input.supplierOrderId,
    p_supplier_delivery_no:input.supplierDeliveryNo,
    p_notes:input.notes,p_lines:input.lines,
  })
  throwIfError(error)
  return data as {documentId:string;receiptNo:string;status:string;masterVersion:number}
}

export async function postGoodsReceipt(documentId:string,masterVersion:number,idempotencyKey:string) {
  const { data,error }=await supabase.rpc('post_goods_receipt',{
    p_document_id:documentId,p_master_version:masterVersion,
    p_idempotency_key:idempotencyKey,
  })
  throwIfError(error)
  return data as {documentId:string;receiptNo:string;status:string;masterVersion:number;idempotentReplay:boolean}
}

export async function cancelGoodsReceipt(documentId:string,masterVersion:number) {
  const { data,error }=await supabase.rpc('cancel_goods_receipt',{
    p_document_id:documentId,p_master_version:masterVersion,
  })
  throwIfError(error)
  return data as {documentId:string;status:string;masterVersion:number}
}

export async function loadPurchaseReturnWorkspace(
  _companyId:string,_storeId:string,cashierSessionId:string,
) {
  const {data,error}=await supabase.rpc('get_pos_purchase_return_workspace',{
    p_cashier_session_id:cashierSessionId,
  })
  throwIfError(error)
  const payload=data as {
    receipts:Array<{id:string;receipt_no:string;supplier_order_id:string;received_at:string}>
    drafts:Array<{id:string;return_no:string;source_receipt_id:string;source_warehouse_id:string;return_date:string;return_reason:string;supplier_document_no:string|null;notes:string|null;review_status:string;master_version:number|string}>
    receiptLines:Array<{id:string;document_id:string;product_id:string;product_name_snapshot:string;base_uom_name_snapshot:string}>
    allocations:Array<{id:string;receipt_line_id:string;condition_type:string;warehouse_id:string;quantity_base:number|string;product_batch_id:string}>
    batches:Array<{id:string;qty_remaining:number|string}>
    returnLines:Array<{document_id:string;source_condition_allocation_id:string;return_base_qty:number|string;client_line_key:string;return_uom_id:string;return_qty:number|string;document_status:string}>
    productUoms:Array<{product_id:string;uom_id:string;factor_to_base:number|string;uom_name:string;allow_decimal:boolean;decimal_precision:number|string}>
    orders:Array<{id:string;order_no:string;supplier_id:string}>
    suppliers:Array<{id:string;supplier_name:string}>
    warehouses:Array<{id:string;name:string}>
  }
  const receipts=payload.receipts??[];const drafts=payload.drafts??[]
  const receiptLines=payload.receiptLines??[];const allocations=payload.allocations??[]
  const postedReturnLines=(payload.returnLines??[]).filter((row)=>row.document_status==='POSTED')
  const returnedByAllocation=new Map<string,number>()
  for(const row of postedReturnLines)returnedByAllocation.set(row.source_condition_allocation_id,(returnedByAllocation.get(row.source_condition_allocation_id)??0)+numberValue(row.return_base_qty))
  const lineById=new Map(receiptLines.map((row)=>[row.id,row]));const batchById=new Map((payload.batches??[]).map((row)=>[row.id,row]))
  const optionsByProduct=new Map<string,PurchaseReturnUomOption[]>()
  for(const row of payload.productUoms??[]){const list=optionsByProduct.get(row.product_id)??[];list.push({uomId:row.uom_id,uomName:row.uom_name,factorToBase:numberValue(row.factor_to_base),allowDecimal:Boolean(row.allow_decimal),decimalPrecision:numberValue(row.decimal_precision)});optionsByProduct.set(row.product_id,list)}
  for(const list of optionsByProduct.values())list.sort((a,b)=>b.factorToBase-a.factorToBase||a.uomName.localeCompare(b.uomName))
  const orderById=new Map((payload.orders??[]).map((row)=>[row.id,row]));const supplierById=new Map((payload.suppliers??[]).map((row)=>[row.id,row.supplier_name]));const warehouseById=new Map((payload.warehouses??[]).map((row)=>[row.id,row.name]));const receiptById=new Map(receipts.map((row)=>[row.id,row]))
  const grouped=new Map<string,PurchaseReturnAllocation[]>()
  for(const allocation of allocations){const line=lineById.get(allocation.receipt_line_id);const batch=batchById.get(allocation.product_batch_id);if(!line||!batch||!allocation.warehouse_id)continue;const remaining=Math.max(0,Math.min(numberValue(batch.qty_remaining),numberValue(allocation.quantity_base)-(returnedByAllocation.get(allocation.id)??0)));if(remaining<=0)continue;const key=`${line.document_id}:${allocation.warehouse_id}`;const list=grouped.get(key)??[];list.push({id:allocation.id,receiptLineId:line.id,productId:line.product_id,productName:line.product_name_snapshot,condition:allocation.condition_type as 'GOOD'|'DAMAGED',warehouseId:allocation.warehouse_id,baseUomName:line.base_uom_name_snapshot,availableBaseQuantity:remaining,options:optionsByProduct.get(line.product_id)??[]});grouped.set(key,list)}
  const sources:PurchaseReturnSource[]=[]
  for(const [key,items] of grouped){const [receiptId,warehouseId]=key.split(':');const receipt=receiptById.get(receiptId);if(!receipt)continue;const order=orderById.get(receipt.supplier_order_id);sources.push({key,receiptId,receiptNo:receipt.receipt_no,orderNo:order?.order_no??'Supplier Order',supplierName:supplierById.get(order?.supplier_id??'')??'Supplier',warehouseId,warehouseName:warehouseById.get(warehouseId)??'Gudang',receivedAt:receipt.received_at,allocations:items.filter((item)=>item.options.length>0)})}
  const draftLinesByDocument=new Map<string,PurchaseReturnDraftLine[]>()
  for(const row of (payload.returnLines??[]).filter((item)=>item.document_status==='DRAFT')){const list=draftLinesByDocument.get(row.document_id)??[];list.push({clientLineKey:row.client_line_key,sourceConditionAllocationId:row.source_condition_allocation_id,returnUomId:row.return_uom_id,returnQuantity:numberValue(row.return_qty)});draftLinesByDocument.set(row.document_id,list)}
  return {sources:sources.filter((source)=>source.allocations.length>0).sort((a,b)=>b.receivedAt.localeCompare(a.receivedAt)),drafts:drafts.map((row)=>({id:row.id,returnNo:row.return_no,sourceReceiptId:row.source_receipt_id,sourceWarehouseId:row.source_warehouse_id,returnDate:row.return_date,returnReason:row.return_reason,supplierDocumentNo:row.supplier_document_no,notes:row.notes,reviewStatus:row.review_status as 'PENDING'|'APPROVED',masterVersion:numberValue(row.master_version),lines:draftLinesByDocument.get(row.id)??[]}))}
}

export async function savePurchaseReturnDraft(input:{documentId:string|null;masterVersion:number|null;cashierSessionId:string;sourceReceiptId:string;sourceWarehouseId:string;returnDate:string;returnReason:string;supplierDocumentNo:string|null;notes:string|null;lines:PurchaseReturnDraftLine[]}){
  const {data,error}=await supabase.rpc('save_purchase_return_draft',{p_document_id:input.documentId,p_master_version:input.masterVersion,p_cashier_session_id:input.cashierSessionId,p_source_receipt_id:input.sourceReceiptId,p_source_warehouse_id:input.sourceWarehouseId,p_return_date:input.returnDate,p_return_reason:input.returnReason,p_supplier_document_no:input.supplierDocumentNo,p_notes:input.notes,p_lines:input.lines.map((line)=>({clientLineKey:line.clientLineKey,sourceConditionAllocationId:line.sourceConditionAllocationId,returnUomId:line.returnUomId,returnQty:line.returnQuantity}))})
  throwIfError(error);return data as {documentId:string;returnNo:string;status:string;reviewStatus:string;masterVersion:number}
}

export async function cancelPurchaseReturnDraft(documentId:string,masterVersion:number,reason:string){const {data,error}=await supabase.rpc('cancel_purchase_return_draft',{p_document_id:documentId,p_master_version:masterVersion,p_reason:reason});throwIfError(error);return data as {documentId:string;status:string;masterVersion:number}}

export async function saveExpenseDraft(input: {
  storeId: string
  cashierSessionId: string
  categoryId: string
  responsiblePartyType: 'CASHIER' | 'EXTERNAL'
  responsiblePartyId: string | null
  responsiblePartyName: string
  requestedAmount: number
  paymentMethodId: string
  recipient: string
  description: string
  evidenceUrl: string
  expectedSettlementDate: string
  clientExpenseId: string
}): Promise<ExpenseRequestResult> {
  const { data, error } = await supabase.rpc('save_expense_draft', {
    p_document_id: null,
    p_master_version: null,
    p_store_id: input.storeId,
    p_cashier_session_id: input.cashierSessionId,
    p_category_id: input.categoryId,
    p_responsible_party_type: input.responsiblePartyType,
    p_responsible_party_id: input.responsiblePartyId,
    p_responsible_party_name: input.responsiblePartyName.trim(),
    p_requested_amount: input.requestedAmount,
    p_payment_method_id: input.paymentMethodId,
    p_recipient: input.recipient.trim() || null,
    p_description: input.description.trim(),
    p_evidence_url: input.evidenceUrl.trim() || null,
    p_expected_settlement_date: input.expectedSettlementDate || null,
    p_client_expense_id: input.clientExpenseId,
  })
  throwIfError(error)
  const row = data as DbRow
  return {
    documentId: String(row.documentId),
    documentNo: String(row.documentNo),
    status: String(row.status) as ExpenseRequestResult['status'],
    masterVersion: numberValue(row.masterVersion),
  }
}

export async function submitExpenseRequest(
  documentId: string,
  masterVersion: number,
): Promise<ExpenseRequestResult> {
  const { data, error } = await supabase.rpc('submit_expense_request', {
    p_document_id: documentId,
    p_master_version: masterVersion,
  })
  throwIfError(error)
  const row = data as DbRow
  return {
    documentId: String(row.documentId),
    documentNo: '',
    status: String(row.status) as ExpenseRequestResult['status'],
    masterVersion: numberValue(row.masterVersion),
  }
}

export async function listApprovedCashExpenses(
  cashierSession: CashierSession,
): Promise<ApprovedCashExpense[]> {
  const { data, error } = await supabase.rpc('get_pos_expense_workspace', {
    p_cashier_session_id: cashierSession.id,
  })
  throwIfError(error)
  const rows = (((data ?? {}) as DbRow).approvedCashExpenses ?? []) as DbRow[]
  return rows.map((row) => ({
    documentId: String(row.id),
    documentNo: String(row.document_no),
    categoryName: String(row.category_name_snapshot),
    responsiblePartyName: String(row.responsible_party_name_snapshot),
    requestedAmount: numberValue(row.requested_amount),
    paymentMethodId: String(row.requested_payment_method_id),
    paymentMethodName: String(row.requested_payment_method_name_snapshot),
    description: String(row.description),
    recipient: row.recipient ? String(row.recipient) : null,
    evidenceUrl: row.evidence_url ? String(row.evidence_url) : null,
    expectedSettlementDate: row.expected_settlement_date
      ? String(row.expected_settlement_date)
      : null,
    masterVersion: numberValue(row.master_version),
    approvedAt: String(row.approved_at),
  }))
}

export async function disburseCashExpense(input: {
  documentId: string
  masterVersion: number
  cashierSessionId: string
  evidenceUrl: string
  idempotencyKey: string
}): Promise<ExpenseDisbursementResult> {
  const { data, error } = await supabase.rpc('disburse_expense', {
    p_document_id: input.documentId,
    p_master_version: input.masterVersion,
    p_cashier_session_id: input.cashierSessionId,
    p_evidence_url: input.evidenceUrl.trim() || null,
    p_idempotency_key: input.idempotencyKey,
  })
  throwIfError(error)
  const row = data as DbRow
  return {
    documentId: String(row.documentId),
    disbursementId: String(row.disbursementId),
    status: String(row.status) as 'DISBURSED',
    masterVersion: numberValue(row.masterVersion),
    amount: numberValue(row.amount),
    paymentMethodType: String(row.paymentMethodType),
    expectedCashAfter: row.expectedCashAfter === null
      ? null
      : numberValue(row.expectedCashAfter),
    idempotentReplay: Boolean(row.idempotentReplay),
  }
}

export async function listOutstandingExpenses(
  cashierSession: CashierSession,
): Promise<OutstandingExpense[]> {
  const { data, error } = await supabase.rpc('get_pos_expense_workspace', {
    p_cashier_session_id: cashierSession.id,
  })
  throwIfError(error)
  const rows = (((data ?? {}) as DbRow).outstandingExpenses ?? []) as DbRow[]
  return rows.map((row) => ({
    documentId: String(row.id),
    documentNo: String(row.document_no),
    categoryName: String(row.category_name_snapshot),
    responsiblePartyName: String(row.responsible_party_name_snapshot),
    paymentMethodId: String(row.requested_payment_method_id),
    paymentMethodName: String(row.requested_payment_method_name_snapshot),
    paymentMethodType: String(row.requested_payment_method_type_snapshot),
    disbursedAmount: numberValue(row.disbursed_amount),
    actualExpenseAmount: numberValue(row.actual_expense_amount),
    returnedAmount: numberValue(row.returned_amount),
    outstandingAmount: numberValue(row.outstanding_amount),
    evidenceRequired: row.evidence_policy_snapshot === 'REQUIRED',
    settlementPending: Boolean(row.settlement_pending),
    masterVersion: numberValue(row.master_version),
    status: String(row.status) as OutstandingExpense['status'],
  }))
}

export async function saveExpenseSettlement(input: {
  documentId: string
  masterVersion: number
  actualExpenseAmount: number
  evidenceUrl: string
  idempotencyKey: string
}) {
  const { data, error } = await supabase.rpc('save_expense_settlement', {
    p_document_id: input.documentId,
    p_master_version: input.masterVersion,
    p_actual_expense_amount: input.actualExpenseAmount,
    p_evidence_url: input.evidenceUrl.trim() || null,
    p_idempotency_key: input.idempotencyKey,
  })
  throwIfError(error)
  return data as DbRow
}

export async function returnCashExpenseFunds(input: {
  documentId: string
  masterVersion: number
  amount: number
  paymentMethodId: string
  cashierSessionId: string
  evidenceUrl: string
  idempotencyKey: string
}) {
  const { data, error } = await supabase.rpc('return_expense_funds', {
    p_document_id: input.documentId,
    p_master_version: input.masterVersion,
    p_amount: input.amount,
    p_payment_method_id: input.paymentMethodId,
    p_receiving_session_id: input.cashierSessionId,
    p_evidence_url: input.evidenceUrl.trim() || null,
    p_idempotency_key: input.idempotencyKey,
  })
  throwIfError(error)
  return data as DbRow
}

export async function requestAdditionalExpenseDisbursement(input: {
  documentId: string
  masterVersion: number
  amount: number
  paymentMethodId: string
  evidenceUrl: string
  idempotencyKey: string
}) {
  const { data, error } = await supabase.rpc(
    'request_additional_expense_disbursement',
    {
      p_document_id: input.documentId,
      p_master_version: input.masterVersion,
      p_amount: input.amount,
      p_payment_method_id: input.paymentMethodId,
      p_evidence_url: input.evidenceUrl.trim() || null,
      p_idempotency_key: input.idempotencyKey,
    },
  )
  throwIfError(error)
  return data as DbRow
}

export async function listApprovedAdditionalCashExpenses(
  cashierSession: CashierSession,
): Promise<ApprovedAdditionalCashExpense[]> {
  const { data, error } = await supabase.rpc('get_pos_expense_workspace', {
    p_cashier_session_id: cashierSession.id,
  })
  throwIfError(error)
  const rows = (((data ?? {}) as DbRow).approvedAdditionalCashExpenses ?? []) as DbRow[]
  return rows.map((row) => ({
      requestId: String(row.id),
      requestMasterVersion: numberValue(row.master_version),
      documentId: String(row.document_id),
      documentNo: String(row.document_no),
      documentMasterVersion: numberValue(row.document_master_version),
      categoryName: String(row.category_name_snapshot),
      responsiblePartyName: String(row.responsible_party_name_snapshot),
      amount: numberValue(row.amount),
      paymentMethodId: String(row.payment_method_id),
      paymentMethodName: String(row.payment_method_name_snapshot),
      evidenceUrl: row.evidence_url ? String(row.evidence_url) : null,
      requestedAt: String(row.requested_at),
      approvedAt: String(row.approved_at),
    }))
}

export async function disburseAdditionalCashExpense(input: {
  requestId: string
  requestMasterVersion: number
  documentMasterVersion: number
  cashierSessionId: string
  evidenceUrl: string
  idempotencyKey: string
}) {
  const { data, error } = await supabase.rpc('disburse_additional_expense', {
    p_request_id: input.requestId,
    p_request_master_version: input.requestMasterVersion,
    p_document_master_version: input.documentMasterVersion,
    p_cashier_session_id: input.cashierSessionId,
    p_evidence_url: input.evidenceUrl.trim() || null,
    p_idempotency_key: input.idempotencyKey,
  })
  throwIfError(error)
  return data as DbRow
}

export async function listCashDepositEligibleSessions(
  storeId: string,
): Promise<CashDepositEligibleSession[]> {
  const { data, error } = await supabase.rpc(
    'list_cash_deposit_eligible_sessions',
    { p_store_id: storeId },
  )
  throwIfError(error)
  const rows = Array.isArray(data) ? data as DbRow[] : []
  return rows.map((row) => ({
    sessionId: String(row.sessionId),
    sessionCode: String(row.sessionCode),
    cashierId: String(row.cashierId),
    cashierName: String(row.cashierName),
    closedAt: String(row.closedAt),
    closingCashActual: numberValue(row.closingCashActual),
    postedDepositAllocations: numberValue(row.postedDepositAllocations),
    availableDepositAmount: numberValue(row.availableDepositAmount),
  }))
}

export async function saveCashDepositDraft(input: {
  documentId: string | null
  masterVersion: number | null
  storeId: string
  destinationType: 'BANK' | 'VAULT'
  destinationName: string
  actualDepositAmount: number
  depositAt: string
  evidenceUrl: string
  notes: string
  clientDepositId: string
  sessions: Array<{
    sessionId: string
    nextSessionFloatReserved: number
  }>
}): Promise<CashDepositDraftResult> {
  const { data, error } = await supabase.rpc('save_cash_deposit_draft', {
    p_document_id: input.documentId,
    p_master_version: input.masterVersion,
    p_store_id: input.storeId,
    p_destination_type: input.destinationType,
    p_destination_name: input.destinationName.trim(),
    p_actual_deposit_amount: input.actualDepositAmount,
    p_deposit_at: input.depositAt,
    p_evidence_url: input.evidenceUrl.trim() || null,
    p_notes: input.notes.trim() || null,
    p_client_deposit_id: input.clientDepositId,
    p_sessions: input.sessions.map((session) => ({
      sessionId: session.sessionId,
      nextSessionFloatReserved: session.nextSessionFloatReserved,
    })),
  })
  throwIfError(error)
  const row = data as DbRow
  return {
    depositDocumentId: String(row.depositDocumentId),
    depositNo: row.depositNo ? String(row.depositNo) : null,
    status: String(row.status) as CashDepositDraftResult['status'],
    masterVersion: numberValue(row.masterVersion),
    totalExpectedDeposit: numberValue(row.totalExpectedDeposit),
    actualDepositAmount: numberValue(
      row.actualDepositAmount ?? input.actualDepositAmount,
    ),
    depositVariance: numberValue(row.depositVariance),
    varianceType: String(row.varianceType) as CashDepositDraftResult['varianceType'],
    idempotentReplay: Boolean(row.idempotentReplay),
  }
}

export async function submitCashDeposit(input: {
  documentId: string
  masterVersion: number
  idempotencyKey: string
}) {
  const { data, error } = await supabase.rpc('submit_cash_deposit', {
    p_document_id: input.documentId,
    p_master_version: input.masterVersion,
    p_idempotency_key: input.idempotencyKey,
  })
  throwIfError(error)
  return data as DbRow
}

export async function quickCreatePosCustomer(input: QuickCustomerInput) {
  const { data, error } = await supabase.rpc('quick_create_pos_customer', {
    p_customer_name: input.name.trim(),
    p_phone: input.phone.trim() || null,
    p_email: input.email.trim().toLowerCase() || null,
    p_address: input.address.trim() || null,
    p_customer_type: input.type,
  })
  throwIfError(error)
  const row = data as DbRow
  return {
    customerId: String(row.customerId),
    customerName: String(row.customerName),
    companyId: String(row.companyId),
  }
}

export async function previewPosSalePrices(input: {
  cashierSessionId: string
  customerId: string
  selectedPricelistId: string | null
  lines: Array<{
    lineKey: string
    productUomId: string
    quantity: number
  }>
}): Promise<PosPricePreviewLine[]> {
  const { data, error } = await supabase.rpc('preview_pos_sale_prices', {
    p_cashier_session_id: input.cashierSessionId,
    p_customer_id: input.customerId,
    p_selected_pricelist_id: input.selectedPricelistId,
    p_lines: input.lines,
  })
  throwIfError(error)
  const payload = (data ?? {}) as DbRow
  const rows = Array.isArray(payload.lines)
    ? payload.lines as DbRow[]
    : []
  return rows.map((row) => ({
    lineKey: String(row.lineKey),
    productUomId: String(row.productUomId),
    productName: String(row.productName),
    productSku: String(row.productSku),
    uomName: String(row.uomName),
    quantity: numberValue(row.quantity),
    baseUnitPrice: numberValue(row.baseUnitPrice),
    unitPrice: numberValue(row.unitPrice),
    pricelistId: row.pricelistId ? String(row.pricelistId) : null,
    pricelistRuleId: row.pricelistRuleId
      ? String(row.pricelistRuleId)
      : null,
    pricelistName: row.pricelistName ? String(row.pricelistName) : null,
    pricingSelectionSource:
      row.pricingSelectionSource === 'CASHIER_OVERRIDE'
        ? 'CASHIER_OVERRIDE'
        : 'AUTO',
  }))
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
  transactionAt: string | null
  transactionDateIntent: 'PRESERVE' | 'CASHIER_SELECTED'
  dueDate: string | null
  fulfillmentMode: 'PICKUP' | 'DELIVERY'
  deliveryRecipientName: string
  deliveryRecipientPhone: string
  deliveryAddress: string
  deliveryScheduledAt: string | null
  deliveryNotes: string
  deliveryFeeAmount: number
  deliveryFeeInvoiceDisplayMode: 'SHOW_SEPARATE' | 'HIDE_BREAKDOWN'
  negativeStockReason?: string
  payments: Array<{
    clientPaymentKey: string
    paymentMethodId: string
    amount: number
    tenderedAmount: number
    proofUrl?: string
    overpaymentDisposition?: 'RETURNED' | 'CUSTOMER_BALANCE'
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
    transactionAt: input.isTempo ? input.transactionAt : null,
    transactionDateIntent: input.isTempo
      ? input.transactionDateIntent
      : 'PRESERVE',
    dueDate: input.dueDate,
    fulfillmentMode: input.fulfillmentMode,
    deliveryFeeAmount:
      input.fulfillmentMode === 'DELIVERY' ? input.deliveryFeeAmount : 0,
    deliveryFeeInvoiceDisplayMode: input.deliveryFeeInvoiceDisplayMode,
    ...(input.fulfillmentMode === 'DELIVERY'
      ? {
          deliveryRecipientName: input.deliveryRecipientName.trim(),
          deliveryRecipientPhone: input.deliveryRecipientPhone.trim(),
          deliveryAddress: input.deliveryAddress.trim(),
          deliveryScheduledAt: input.deliveryScheduledAt,
          deliveryNotes: input.deliveryNotes.trim() || null,
        }
      : {}),
    ...(input.negativeStockReason?.trim()
      ? { negativeStockReason: input.negativeStockReason.trim() }
      : {}),
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
    transactionAt: String(
      row.transactionAt ?? input.draft?.transactionAt ?? new Date().toISOString(),
    ),
    transactionDateSource:
      row.transactionDateSource === 'CASHIER_SELECTED'
        ? 'CASHIER_SELECTED'
        : input.draft?.transactionDateSource ?? 'SERVER_CREATED',
    orderTimingMode:
      row.orderTimingMode === 'SCHEDULED'
        ? 'SCHEDULED'
        : row.orderTimingMode === 'BACKORDER'
          ? 'BACKORDER'
          : input.draft?.orderTimingMode ?? 'IMMEDIATE',
    plannedOrderDate: row.plannedOrderDate
      ? String(row.plannedOrderDate)
      : input.draft?.plannedOrderDate ?? null,
    operationalStatus:
      row.operationalStatus === 'SCHEDULED' ? 'SCHEDULED' : 'ACTIVE',
    masterVersion: numberValue(row.masterVersion),
    grandTotalBeforeRounding: numberValue(row.grandTotalBeforeRounding),
    roundingAdjustment: numberValue(row.roundingAdjustment),
    grandTotalAfterRounding: numberValue(row.grandTotalAfterRounding),
    deliveryFeeAmount: numberValue(row.deliveryFeeAmount),
    deliveryFeeInvoiceDisplayMode:
      row.deliveryFeeInvoiceDisplayMode === 'HIDE_BREAKDOWN'
        ? 'HIDE_BREAKDOWN'
        : 'SHOW_SEPARATE',
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
    transactionAt: String(row.transactionAt ?? row.createdAt),
    transactionDateSource:
      row.transactionDateSource === 'CASHIER_SELECTED'
        ? 'CASHIER_SELECTED'
        : 'SERVER_CREATED',
    orderTimingMode:
      row.orderTimingMode === 'SCHEDULED'
        ? 'SCHEDULED'
        : row.orderTimingMode === 'BACKORDER'
          ? 'BACKORDER'
          : 'IMMEDIATE',
    plannedOrderDate: row.plannedOrderDate
      ? String(row.plannedOrderDate)
      : null,
    operationalStatus:
      row.operationalStatus === 'SCHEDULED' ? 'SCHEDULED' : 'ACTIVE',
    canPost: row.canPost !== false,
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

export async function loadSalesOrders(
  storeId: string,
): Promise<SalesOrderWorkspace> {
  const { data, error } = await supabase.rpc('get_pos_sales_orders', {
    p_store_id: storeId,
  })
  throwIfError(error)
  const payload = (data ?? {}) as DbRow
  const rawLines = Array.isArray(payload.reservationLines)
    ? (payload.reservationLines as DbRow[])
    : []
  const linesBySale = new Map<string, SalesOrderReservationLine[]>()
  for (const row of rawLines) {
    const salesId = String(row.sales_id ?? '')
    const line: SalesOrderReservationLine = {
      id: String(row.id ?? ''),
      salesId,
      productSku: String(row.product_sku ?? ''),
      productName: String(row.product_name ?? ''),
      warehouseName: String(row.warehouse_name ?? ''),
      requestedBaseQuantity: numberValue(row.requested_base_qty),
      reservedBaseQuantity: numberValue(row.reserved_base_qty),
      releasedBaseQuantity: numberValue(row.released_base_qty),
      dispatchedBaseQuantity: numberValue(row.dispatched_base_qty),
      availableBaseQuantitySnapshot: numberValue(
        row.available_base_qty_snapshot,
      ),
      shortageBaseQuantity: numberValue(row.shortage_base_qty),
    }
    linesBySale.set(salesId, [...(linesBySale.get(salesId) ?? []), line])
  }
  const rawOrders = Array.isArray(payload.orders)
    ? (payload.orders as DbRow[])
    : []
  return {
    orders: rawOrders.map((row) => {
      const salesId = String(row.id ?? '')
      const timing = String(row.order_timing_mode ?? 'IMMEDIATE')
      const status = String(row.order_runtime_status ?? 'RESERVED')
      return {
        salesId,
        orderNo: String(row.draft_no ?? ''),
        storeId: String(row.store_id ?? ''),
        storeName: String(row.store_name ?? ''),
        customerId: String(row.customer_id ?? ''),
        customerName: String(row.customer_name ?? ''),
        orderTimingMode:
          timing === 'SCHEDULED'
            ? 'SCHEDULED'
            : timing === 'BACKORDER'
              ? 'BACKORDER'
              : 'IMMEDIATE',
        plannedOrderDate: row.planned_order_date
          ? String(row.planned_order_date)
          : null,
        orderRuntimeStatus:
          status === 'PARTIALLY_DISPATCHED'
            ? 'PARTIALLY_DISPATCHED'
            : status === 'DISPATCHED'
              ? 'DISPATCHED'
              : status === 'DELIVERED'
                ? 'DELIVERED'
                : status === 'CONFIRMED'
                  ? 'CONFIRMED'
                  : 'RESERVED',
        grandTotal: numberValue(row.grand_total_after_rounding),
        masterVersion: numberValue(row.master_version),
        reservationVersion: numberValue(row.reservation_version),
        reservationId: String(row.reservation_id ?? ''),
        reservationStatus: String(row.reservation_status ?? ''),
        totalReservedBaseQuantity: numberValue(row.total_reserved_base_qty),
        totalReleasedBaseQuantity: numberValue(row.total_released_base_qty),
        totalDispatchedBaseQuantity: numberValue(row.total_dispatched_base_qty),
        confirmedAt: String(row.confirmed_at ?? ''),
        updatedAt: String(row.updated_at ?? ''),
        lines: linesBySale.get(salesId) ?? [],
      }
    }),
  }
}

export async function confirmSalesOrder(
  salesId: string,
  masterVersion: number,
  idempotencyKey: string,
  negativeStockReason: string | null,
) {
  const { data, error } = await supabase.rpc('confirm_pos_sales_order', {
    p_sales_id: salesId,
    p_master_version: masterVersion,
    p_idempotency_key: idempotencyKey,
    p_negative_stock_reason: negativeStockReason?.trim() || null,
  })
  throwIfError(error)
  return data as DbRow
}

export async function cancelSalesOrder(
  salesId: string,
  masterVersion: number,
  idempotencyKey: string,
  reason: string,
) {
  const { data, error } = await supabase.rpc('cancel_pos_sales_order', {
    p_sales_id: salesId,
    p_master_version: masterVersion,
    p_idempotency_key: idempotencyKey,
    p_reason: reason.trim(),
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
      'client_line_key,product_uom_id,product_name_snapshot,product_sku_snapshot,sale_uom_name_snapshot,qty,resolved_unit_price,canonical_resolved_unit_price,price_override_applied,line_discount_amount,allocated_order_discount_amount,tax_amount,line_total',
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
    canonicalUnitPrice: numberValue(row.canonical_resolved_unit_price),
    priceOverrideApplied: Boolean(row.price_override_applied),
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

export async function loadSalesInvoiceDocument(
  salesId: string,
): Promise<SalesInvoiceDocument> {
  const { data, error } = await supabase.rpc('get_pos_sales_invoice_document', {
    p_sales_id: salesId,
  })
  throwIfError(error)
  const row = data as DbRow | null
  if (!row) throw new Error('SALES_INVOICE_NOT_FOUND')
  return {
    invoiceSnapshotId: String(row.invoiceSnapshotId),
    invoiceNo: String(row.invoiceNo),
    snapshotVersion: numberValue(row.snapshotVersion),
    snapshotProvenance: row.snapshotProvenance as 'LIVE_POST' | 'LEGACY_CUTOVER',
    snapshot: row.snapshot as Record<string, unknown>,
  }
}

export async function loadSalesDeliveryDocument(
  salesId: string,
): Promise<SalesDeliveryDocument | null> {
  const { data, error } = await supabase.rpc('get_pos_sales_delivery_document', {
    p_sales_id: salesId,
  })
  if (error?.message?.includes('SALES_DELIVERY_NOT_FOUND')) return null
  throwIfError(error)
  return data as SalesDeliveryDocument
}

export async function recordSalesDocumentPrint(
  documentType: 'SALES_INVOICE' | 'SALES_DELIVERY',
  documentId: string,
) {
  const { data, error } = await supabase.rpc('record_pos_sales_document_print', {
    p_document_type: documentType,
    p_document_id: documentId,
  })
  throwIfError(error)
  return data as Record<string, unknown>
}

export async function loadSalesReturnWorkspace(
  _companyId: string,
  search = '',
): Promise<{
  sales: ReturnableSale[]
  damagedWarehouses: DamagedWarehouseOption[]
}> {
  const { data, error } = await supabase.rpc('get_pos_returnable_sales', {
    p_search: search.trim() || null,
    p_limit: 50,
  })
  throwIfError(error)
  const payload = (data ?? {}) as DbRow
  const rawSales = Array.isArray(payload.sales)
    ? (payload.sales as DbRow[])
    : []
  const sales = rawSales.map((sale) => ({
    salesId: String(sale.id),
    invoiceNo: String(sale.invoice_no ?? ''),
    transactionDate: String(sale.transaction_date ?? ''),
    storeId: String(sale.store_id ?? ''),
    customerId: String(sale.customer_id ?? ''),
    grandTotal: numberValue(sale.grand_total_after_rounding),
    priorRefundTotal: numberValue(sale.priorRefundTotal),
    deliveryFeeAmount: numberValue(sale.deliveryFeeAmount),
    deliveryFeeRefunded: numberValue(sale.deliveryFeeRefunded),
    lines: (Array.isArray(sale.lines) ? (sale.lines as DbRow[]) : []).map(
      (line) => ({
        sourceSalesDetailId: String(line.sourceSalesDetailId),
        productId: String(line.productId),
        productName: String(line.productName),
        uomName: String(line.uomName),
        soldQuantity: numberValue(line.soldQuantity),
        returnedQuantity: numberValue(line.returnedQuantity),
        remainingQuantity: numberValue(line.remainingQuantity),
        refundableLineAmount: numberValue(line.refundableLineAmount),
      }),
    ),
  }))
  const damagedWarehouses = Array.isArray(payload.damagedWarehouses)
    ? (payload.damagedWarehouses as DbRow[]).map((row) => ({
        id: String(row.id), name: String(row.name),
      })) : []
  return { sales, damagedWarehouses }
}

export async function saveSalesReturnDraft(input: {
  sourceSalesId: string
  executingSessionId: string
  roundingDirection: 'NONE' | 'DOWN' | 'UP'
  notes: string
  refundDeliveryFee: boolean
  lines: Array<{
    sourceSalesDetailId: string
    quantity: number
    condition: 'SALEABLE' | 'DAMAGED' | 'NO_PHYSICAL_RETURN'
    destinationWarehouseId?: string
  }>
  refund: {
    paymentMethodId: string
    amount: number
    transferDestination?: string
    transferReference?: string
    proofUrl?: string
  }
}): Promise<SalesReturnDraftResult> {
  const { data, error } = await supabase.rpc(
    'save_sales_return_draft_with_delivery_fee', {
    p_document_id: null,
    p_master_version: null,
    p_source_sales_id: input.sourceSalesId,
    p_executing_session_id: input.executingSessionId,
    p_rounding_direction: input.roundingDirection,
    p_notes: input.notes.trim() || null,
    p_refund_delivery_fee: input.refundDeliveryFee,
    p_lines: input.lines.map((line) => ({
      sourceSalesDetailId: line.sourceSalesDetailId,
      quantity: line.quantity,
      condition: line.condition,
      destinationWarehouseId: line.destinationWarehouseId || null,
    })),
    p_refunds: [
      {
        clientRefundKey: crypto.randomUUID(),
        paymentMethodId: input.refund.paymentMethodId,
        amount: input.refund.amount,
        transferDestination: input.refund.transferDestination || null,
        transferReference: input.refund.transferReference || null,
        proofUrl: input.refund.proofUrl || null,
      },
    ],
    },
  )
  throwIfError(error)
  const row = data as DbRow
  return {
    documentId: String(row.documentId),
    returnNo: String(row.returnNo),
    status: 'DRAFT',
    masterVersion: numberValue(row.masterVersion),
    refundTotal: numberValue(row.refundTotal),
  }
}
