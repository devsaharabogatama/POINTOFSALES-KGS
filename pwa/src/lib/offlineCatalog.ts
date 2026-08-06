import {
  db,
  type OfflineCatalogSnapshotRecord,
  type OfflineSaleQueueRecord,
} from './db'
import { jsonbCanonicalText, sha256Hex, type JsonValue } from './offline'
import { supabase } from './supabase'

export type OfflineCatalogCustomer = {
  id: string
  name: string
  isWalkIn: boolean
  defaultPricelistId?: string | null
  masterVersion: number
}

export type OfflineCatalogPricelist = {
  id: string
  name: string
  scope: string
  isDefault: boolean
  priority: number
  validFrom?: string | null
  validUntil?: string | null
  masterVersion: number
}

export type OfflineCatalogPricelistRule = {
  id: string
  pricelistId: string
  productId: string
  productUomId: string
  minQty: number
  tierQtyBasis: string
  pricingMethod: string
  fixedUnitPrice?: number
  discountAmountPerUnit?: number
  discountPercent?: number
  validFrom?: string
  validUntil?: string
  ruleVersion: number
  masterVersion: number
}

export type OfflineCatalogProductUom = {
  productId: string
  productUomId: string
  sku: string
  name: string
  categoryName: string
  uomId: string
  uomName: string
  factorToBase: number
  baseUnitPrice: number
  barcode?: string | null
  allowDecimal: boolean
  decimalPrecision: number
  isBundle: boolean
  offlineEligible: boolean
  stockBaseQty: number
  productMasterVersion: number
  uomMasterVersion: number
  productUomMasterVersion: number
  tax: Record<string, unknown>
}

export type OfflineCatalogPaymentMethod = {
  id: string
  name: string
  methodType: string
  proofMode: string
  isDefault: boolean
  feeEnabled: boolean
  feeBearer?: string | null
  feeType?: string | null
  feePercent?: number | null
  feeFixedAmount?: number | null
  masterVersion: number
}

export type OfflineCatalogAllowance = {
  id: string
  productId: string
  baseUomId: string
  allocatedBaseQty: number
  consumedBaseQty: number
  remainingBaseQty: number
  masterVersion: number
  createdAt: string
}

export type OfflineCatalogSnapshot = {
  payloadVersion: number
  catalogVersion: number
  snapshotAt: string
  companyId: string
  storeId: string
  terminalId: string
  warehouseId: string
  cashierSessionId: string
  cashierId: string
  customers: OfflineCatalogCustomer[]
  pricelists: OfflineCatalogPricelist[]
  pricelistRules: OfflineCatalogPricelistRule[]
  productUoms: OfflineCatalogProductUom[]
  paymentMethods: OfflineCatalogPaymentMethod[]
  allowances: OfflineCatalogAllowance[]
}

export type OfflineCatalogScope = {
  companyId: string
  storeId: string
  terminalId: string
  warehouseId: string
  cashierSessionId: string
  cashierId: string
}

export type OfflineCatalogReadResult = {
  record: OfflineCatalogSnapshotRecord
  snapshot: OfflineCatalogSnapshot
  ageMs: number
  isStale: boolean
}

export type OfflineAllowanceAvailability = {
  allowanceId: string
  productId: string
  baseUomId: string
  serverRemainingBaseQty: number
  locallyQueuedBaseQty: number
  locallyAvailableBaseQty: number
}

export type OfflineAllowanceMutationResult = {
  allowanceId: string
  masterVersion: number
  replayed: boolean
  status?: string
}

function isObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function requiredString(
  source: Record<string, unknown>,
  key: string,
): string {
  const value = source[key]
  if (typeof value !== 'string' || value === '') {
    throw new Error(`OFFLINE_CATALOG_${key.toUpperCase()}_INVALID`)
  }
  return value
}

function requiredNumber(
  source: Record<string, unknown>,
  key: string,
): number {
  const value = Number(source[key])
  if (!Number.isFinite(value)) {
    throw new Error(`OFFLINE_CATALOG_${key.toUpperCase()}_INVALID`)
  }
  return value
}

function requiredArray(source: Record<string, unknown>, key: string) {
  const value = source[key]
  if (!Array.isArray(value)) {
    throw new Error(`OFFLINE_CATALOG_${key.toUpperCase()}_INVALID`)
  }
  return value
}

function validateSnapshot(
  value: unknown,
  scope: OfflineCatalogScope,
): OfflineCatalogSnapshot {
  if (!isObject(value)) throw new Error('OFFLINE_CATALOG_SNAPSHOT_INVALID')
  const snapshotAt = requiredString(value, 'snapshotAt')
  const parsedSnapshotAt = Date.parse(snapshotAt)
  if (!Number.isFinite(parsedSnapshotAt)) {
    throw new Error('OFFLINE_CATALOG_SNAPSHOT_AT_INVALID')
  }
  const identities: Array<[keyof OfflineCatalogScope, string]> = [
    ['companyId', requiredString(value, 'companyId')],
    ['storeId', requiredString(value, 'storeId')],
    ['terminalId', requiredString(value, 'terminalId')],
    ['warehouseId', requiredString(value, 'warehouseId')],
    ['cashierSessionId', requiredString(value, 'cashierSessionId')],
    ['cashierId', requiredString(value, 'cashierId')],
  ]
  for (const [key, actual] of identities) {
    if (actual !== scope[key]) {
      throw new Error(`OFFLINE_CATALOG_${key.toUpperCase()}_MISMATCH`)
    }
  }
  const payloadVersion = requiredNumber(value, 'payloadVersion')
  const catalogVersion = requiredNumber(value, 'catalogVersion')
  if (
    !Number.isInteger(payloadVersion) ||
    payloadVersion !== 1 ||
    !Number.isSafeInteger(catalogVersion) ||
    catalogVersion <= 0
  ) {
    throw new Error('OFFLINE_CATALOG_VERSION_INVALID')
  }
  const productUoms = requiredArray(value, 'productUoms')
  const customers = requiredArray(value, 'customers')
  const paymentMethods = requiredArray(value, 'paymentMethods')
  const pricelists = requiredArray(value, 'pricelists')
  const pricelistRules = requiredArray(value, 'pricelistRules')
  const allowances = requiredArray(value, 'allowances')
  for (const row of productUoms) {
    if (
      !isObject(row) ||
      !requiredString(row, 'productId') ||
      !requiredString(row, 'productUomId') ||
      requiredNumber(row, 'factorToBase') <= 0 ||
      requiredNumber(row, 'baseUnitPrice') < 0 ||
      !isObject(row.tax)
    ) {
      throw new Error('OFFLINE_CATALOG_PRODUCT_UOM_INVALID')
    }
  }
  for (const row of allowances) {
    if (
      !isObject(row) ||
      !requiredString(row, 'id') ||
      !requiredString(row, 'productId') ||
      requiredNumber(row, 'remainingBaseQty') < 0
    ) {
      throw new Error('OFFLINE_CATALOG_ALLOWANCE_INVALID')
    }
  }
  return {
    ...(value as unknown as OfflineCatalogSnapshot),
    payloadVersion,
    catalogVersion,
    snapshotAt,
    productUoms: productUoms as OfflineCatalogProductUom[],
    customers: customers as OfflineCatalogCustomer[],
    paymentMethods: paymentMethods as OfflineCatalogPaymentMethod[],
    pricelists: pricelists as OfflineCatalogPricelist[],
    pricelistRules: pricelistRules as OfflineCatalogPricelistRule[],
    allowances: allowances as OfflineCatalogAllowance[],
  }
}

function snapshotScope(snapshot: OfflineCatalogSnapshot): OfflineCatalogScope {
  return {
    companyId: snapshot.companyId,
    storeId: snapshot.storeId,
    terminalId: snapshot.terminalId,
    warehouseId: snapshot.warehouseId,
    cashierSessionId: snapshot.cashierSessionId,
    cashierId: snapshot.cashierId,
  }
}

async function snapshotHash(snapshot: OfflineCatalogSnapshot) {
  return sha256Hex(
    jsonbCanonicalText(snapshot as unknown as JsonValue),
  )
}

export async function refreshOfflineCatalogSnapshot(
  scope: OfflineCatalogScope,
) {
  const { data, error } = await supabase.rpc(
    'get_pos_offline_catalog_snapshot',
    { p_cashier_session_id: scope.cashierSessionId },
  )
  if (error) throw error
  const snapshot = validateSnapshot(data, scope)
  const payloadHash = await snapshotHash(snapshot)
  const record: OfflineCatalogSnapshotRecord = {
    ...scope,
    payloadVersion: snapshot.payloadVersion,
    catalogVersion: snapshot.catalogVersion,
    snapshotAt: snapshot.snapshotAt,
    cachedAt: new Date().toISOString(),
    payloadHash,
    payload: JSON.stringify(snapshot),
  }
  await db.transaction('rw', db.offline_catalog_snapshots, async () => {
    await db.offline_catalog_snapshots.put(record)
  })
  return { record, snapshot }
}

export async function issueOwnOfflineStockAllowance(
  cashierSessionId: string,
  productId: string,
): Promise<OfflineAllowanceMutationResult> {
  if (!cashierSessionId || !productId) {
    throw new Error('OFFLINE_ALLOWANCE_PRODUCT_REQUIRED')
  }
  const { data, error } = await supabase.rpc(
    'issue_pos_offline_stock_allowance',
    {
      p_cashier_session_id: cashierSessionId,
      p_product_id: productId,
    },
  )
  if (error) throw error
  if (!isObject(data)) {
    throw new Error('OFFLINE_ALLOWANCE_RESPONSE_INVALID')
  }
  return {
    allowanceId: requiredString(data, 'allowanceId'),
    masterVersion: requiredNumber(data, 'masterVersion'),
    replayed: data.replayed === true,
  }
}

export async function releaseOwnOfflineStockAllowance(
  allowanceId: string,
  masterVersion: number,
): Promise<OfflineAllowanceMutationResult> {
  if (
    !allowanceId ||
    !Number.isSafeInteger(masterVersion) ||
    masterVersion <= 0
  ) {
    throw new Error('OFFLINE_ALLOWANCE_RELEASE_INPUT_INVALID')
  }
  const { data, error } = await supabase.rpc(
    'release_pos_offline_stock_allowance',
    {
      p_allowance_id: allowanceId,
      p_master_version: masterVersion,
      p_force: false,
      p_reason: null,
    },
  )
  if (error) throw error
  if (!isObject(data)) {
    throw new Error('OFFLINE_ALLOWANCE_RESPONSE_INVALID')
  }
  return {
    allowanceId: requiredString(data, 'allowanceId'),
    masterVersion: requiredNumber(data, 'masterVersion'),
    replayed: data.replayed === true,
    status: typeof data.status === 'string' ? data.status : undefined,
  }
}

export async function readOfflineCatalogSnapshot(
  cashierSessionId: string,
  maxAgeMs?: number,
): Promise<OfflineCatalogReadResult | undefined> {
  const record = await db.offline_catalog_snapshots.get(cashierSessionId)
  if (!record || record.invalidatedAt) return undefined
  const parsed = JSON.parse(record.payload) as unknown
  const snapshot = validateSnapshot(parsed, {
    companyId: record.companyId,
    storeId: record.storeId,
    terminalId: record.terminalId,
    warehouseId: record.warehouseId,
    cashierSessionId: record.cashierSessionId,
    cashierId: record.cashierId,
  })
  if (
    snapshot.catalogVersion !== record.catalogVersion ||
    (await snapshotHash(snapshot)) !== record.payloadHash
  ) {
    await invalidateOfflineCatalogSnapshot(
      cashierSessionId,
      'CACHE_INTEGRITY_MISMATCH',
    )
    throw new Error('OFFLINE_CATALOG_CACHE_INTEGRITY_INVALID')
  }
  const ageMs = Math.max(0, Date.now() - Date.parse(record.snapshotAt))
  const isStale =
    maxAgeMs !== undefined &&
    (!Number.isFinite(maxAgeMs) || maxAgeMs < 0 || ageMs > maxAgeMs)
  return { record, snapshot, ageMs, isStale }
}

export async function requireOfflineCatalogSnapshot(
  scope: OfflineCatalogScope,
  maxAgeMs: number,
) {
  if (!Number.isFinite(maxAgeMs) || maxAgeMs < 0) {
    throw new Error('OFFLINE_CATALOG_MAX_AGE_INVALID')
  }
  const cached = await readOfflineCatalogSnapshot(
    scope.cashierSessionId,
    maxAgeMs,
  )
  if (!cached) throw new Error('OFFLINE_CATALOG_CACHE_MISSING')
  const cachedScope = snapshotScope(cached.snapshot)
  for (const key of Object.keys(scope) as Array<keyof OfflineCatalogScope>) {
    if (cachedScope[key] !== scope[key]) {
      await invalidateOfflineCatalogSnapshot(
        scope.cashierSessionId,
        `SCOPE_MISMATCH_${key}`,
      )
      throw new Error(`OFFLINE_CATALOG_${key.toUpperCase()}_MISMATCH`)
    }
  }
  if (cached.isStale) throw new Error('OFFLINE_CATALOG_CACHE_STALE')
  return cached
}

export async function invalidateOfflineCatalogSnapshot(
  cashierSessionId: string,
  reason: string,
) {
  const normalizedReason = reason.trim()
  if (normalizedReason === '') {
    throw new Error('OFFLINE_CATALOG_INVALIDATION_REASON_REQUIRED')
  }
  await db.offline_catalog_snapshots.update(cashierSessionId, {
    invalidatedAt: new Date().toISOString(),
    invalidationReason: normalizedReason,
  })
}

function queuedBaseQuantity(
  record: OfflineSaleQueueRecord,
  productUoms: Map<string, OfflineCatalogProductUom>,
) {
  if (record.status === 'POSTED' || record.status === 'INVALIDATED') {
    return new Map<string, number>()
  }
  const payload = JSON.parse(record.salePayload) as {
    lines?: Array<{ productUomId?: string; quantity?: number }>
  }
  const totals = new Map<string, number>()
  for (const line of payload.lines ?? []) {
    const productUom = productUoms.get(String(line.productUomId ?? ''))
    const quantity = Number(line.quantity)
    if (!productUom || !Number.isFinite(quantity) || quantity <= 0) {
      throw new Error('OFFLINE_QUEUE_LINE_CATALOG_REFERENCE_INVALID')
    }
    const baseQuantity = quantity * productUom.factorToBase
    totals.set(
      productUom.productId,
      (totals.get(productUom.productId) ?? 0) + baseQuantity,
    )
  }
  return totals
}

function baseQuantity(value: number) {
  return Math.round((value + Number.EPSILON) * 1_000_000) / 1_000_000
}

export async function getOfflineAllowanceAvailability(
  cashierSessionId: string,
  existingCache?: OfflineCatalogReadResult,
): Promise<OfflineAllowanceAvailability[]> {
  const cached =
    existingCache ?? (await readOfflineCatalogSnapshot(cashierSessionId))
  if (!cached) throw new Error('OFFLINE_CATALOG_CACHE_MISSING')
  const productUoms = new Map(
    cached.snapshot.productUoms.map((row) => [row.productUomId, row]),
  )
  const queued = await db.offline_sale_queue
    .where('cashierSessionId')
    .equals(cashierSessionId)
    .toArray()
  const locallyQueuedByProduct = new Map<string, number>()
  for (const record of queued) {
    if (record.localMasterVersion !== cached.snapshot.catalogVersion) continue
    for (const [productId, quantity] of queuedBaseQuantity(
      record,
      productUoms,
    )) {
      locallyQueuedByProduct.set(
        productId,
        (locallyQueuedByProduct.get(productId) ?? 0) + quantity,
      )
    }
  }
  return cached.snapshot.allowances.map((allowance) => {
    const queuedQuantity = baseQuantity(
      locallyQueuedByProduct.get(allowance.productId) ?? 0,
    )
    const serverRemaining = baseQuantity(allowance.remainingBaseQty)
    return {
      allowanceId: allowance.id,
      productId: allowance.productId,
      baseUomId: allowance.baseUomId,
      serverRemainingBaseQty: serverRemaining,
      locallyQueuedBaseQty: queuedQuantity,
      locallyAvailableBaseQty: baseQuantity(
        Math.max(0, serverRemaining - queuedQuantity),
      ),
    }
  })
}
