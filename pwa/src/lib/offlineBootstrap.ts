import {
  db,
  type OfflineOperationalScopeRecord,
} from './db'
import {
  readOfflineCatalogSnapshot,
  type OfflineCatalogReadResult,
  type OfflineCatalogSnapshot,
} from './offlineCatalog'
import type {
  BootstrapData,
  CatalogData,
  CashierSession,
  CompanyOption,
  PaymentMethodOption,
} from './pos'

export type OfflineOperationalScopeInput = {
  company: CompanyOption
  terminal: {
    id: string
    storeId: string
    code: string
    name: string
    storeName: string
    hiddenFeatureKeys: string[]
  }
  warehouse: {
    id: string
    storeId: string | null
    name: string
  }
  cashierSession: CashierSession
  cashierId: string
  catalogVersion: number
}

export type OfflineColdStartRestore = {
  company: CompanyOption
  bootstrap: BootstrapData
  cashierSession: CashierSession
  catalog: CatalogData
  cache: OfflineCatalogReadResult
}

function catalogFromSnapshot(snapshot: OfflineCatalogSnapshot): CatalogData {
  return {
    products: snapshot.productUoms
      .map((item) => ({
        productId: item.productId,
        productUomId: item.productUomId,
        sku: item.sku,
        name: item.name,
        categoryName: item.categoryName,
        uomName: item.uomName,
        factorToBase: item.factorToBase,
        fallbackPrice: item.baseUnitPrice,
        availableQuantity: item.isBundle
          ? null
          : item.factorToBase > 0
            ? Math.floor(item.stockBaseQty / item.factorToBase)
            : 0,
        allowDecimal: item.allowDecimal,
        decimalPrecision: item.decimalPrecision,
        barcode: item.barcode ?? null,
        isBundle: item.isBundle,
      }))
      .sort(
        (left, right) =>
          left.name.localeCompare(right.name, 'id') ||
          left.uomName.localeCompare(right.uomName, 'id'),
      ),
    customers: snapshot.customers.map((item) => ({
      id: item.id,
      name: item.name,
      phone: '',
      address: '',
      isWalkIn: item.isWalkIn,
      defaultPricelistId: item.defaultPricelistId ?? null,
      currentBalance: 0,
      creditLimit: 0,
      creditTermDays: null,
    })),
    pricelists: snapshot.pricelists
      .map((item) => ({
        id: item.id,
        name: item.name,
        scope: item.scope as 'GLOBAL' | 'CUSTOMER',
        isDefault: item.isDefault,
      }))
      .sort(
        (left, right) =>
          Number(right.isDefault) - Number(left.isDefault) ||
          left.name.localeCompare(right.name, 'id'),
      ),
    paymentMethods: snapshot.paymentMethods
      .filter((item) => item.methodType !== 'CUSTOMER_BALANCE')
      .map((item) => ({
        id: item.id,
        name: item.name,
        methodType: item.methodType,
        proofRequired: item.proofMode === 'REQUIRED',
        isDefault: item.isDefault,
        feeBearer: item.feeBearer ?? null,
        feeEnabled: item.feeEnabled,
        feeType: (item.feeType ??
          null) as PaymentMethodOption['feeType'],
        feePercent: Number(item.feePercent ?? 0),
        feeFixedAmount: Number(item.feeFixedAmount ?? 0),
      }))
      .sort(
        (left, right) =>
          Number(right.isDefault) - Number(left.isDefault) ||
          left.name.localeCompare(right.name, 'id'),
      ),
    // Expense request remains online-only in G4 Phase 31. Do not expose it
    // from a retained offline catalog until the dedicated offline contract opens.
    expenseCategories: [],
    expenseEnabled: false,
    // Customer Balance credit is intentionally online-only. The retained
    // catalog must never make the offline checkout advertise this path.
    customerBalanceCreditEnabled: false,
    customerBalanceTenderEnabled: false,
  }
}

function scopeMatchesSnapshot(
  scope: OfflineOperationalScopeRecord,
  snapshot: OfflineCatalogSnapshot,
) {
  return (
    scope.companyId === snapshot.companyId &&
    scope.storeId === snapshot.storeId &&
    scope.terminalId === snapshot.terminalId &&
    scope.warehouseId === snapshot.warehouseId &&
    scope.cashierSessionId === snapshot.cashierSessionId &&
    scope.cashierId === snapshot.cashierId
  )
}

export async function retainOfflineOperationalScope(
  input: OfflineOperationalScopeInput,
) {
  const session = input.cashierSession
  if (
    input.company.id === '' ||
    input.terminal.id !== session.terminalId ||
    input.terminal.storeId !== session.storeId ||
    input.warehouse.id !== session.warehouseId ||
    input.cashierId === '' ||
    !Number.isSafeInteger(input.catalogVersion) ||
    input.catalogVersion <= 0
  ) {
    throw new Error('OFFLINE_OPERATIONAL_SCOPE_INVALID')
  }
  const record: OfflineOperationalScopeRecord = {
    cashierSessionId: session.id,
    companyId: input.company.id,
    companyName: input.company.name,
    companyRoleCode: input.company.roleCode,
    storeId: session.storeId,
    storeName: input.terminal.storeName,
    terminalId: input.terminal.id,
    terminalCode: input.terminal.code,
    terminalName: input.terminal.name,
    hiddenFeatureKeys: input.terminal.hiddenFeatureKeys,
    warehouseId: input.warehouse.id,
    warehouseName: input.warehouse.name,
    cashierId: input.cashierId,
    sessionCode: session.code,
    openingCash: session.openingCash,
    expectedCash: session.expectedCash,
    sessionMasterVersion: session.masterVersion,
    catalogVersion: input.catalogVersion,
    cachedAt: new Date().toISOString(),
  }
  await db.offline_operational_scopes.put(record)
  return record
}

export async function removeOfflineOperationalScope(cashierSessionId: string) {
  await db.offline_operational_scopes.delete(cashierSessionId)
}

export async function restoreOfflineColdStart(
  cashierId: string,
): Promise<OfflineColdStartRestore | undefined> {
  if (!cashierId) return undefined
  const scopes = await db.offline_operational_scopes
    .where('cashierId')
    .equals(cashierId)
    .toArray()
  scopes.sort((left, right) => right.cachedAt.localeCompare(left.cachedAt))
  const scope = scopes[0]
  if (!scope) return undefined
  const cache = await readOfflineCatalogSnapshot(scope.cashierSessionId)
  if (!cache || !scopeMatchesSnapshot(scope, cache.snapshot)) return undefined
  const cashierSession: CashierSession = {
    id: scope.cashierSessionId,
    code: scope.sessionCode,
    terminalId: scope.terminalId,
    warehouseId: scope.warehouseId,
    storeId: scope.storeId,
    openingCash: scope.openingCash,
    expectedCash: scope.expectedCash,
    masterVersion: scope.sessionMasterVersion,
  }
  const company: CompanyOption = {
    id: scope.companyId,
    name: scope.companyName,
    roleCode: scope.companyRoleCode,
  }
  return {
    company,
    cashierSession,
    bootstrap: {
      terminals: [
        {
          id: scope.terminalId,
          storeId: scope.storeId,
          code: scope.terminalCode,
          name: scope.terminalName,
          storeName: scope.storeName,
          hiddenFeatureKeys: scope.hiddenFeatureKeys ?? [],
          allowPriceOverride: false,
        },
      ],
      warehouses: [
        {
          id: scope.warehouseId,
          storeId: scope.storeId,
          name: scope.warehouseName,
        },
      ],
      openSession: cashierSession,
    },
    catalog: catalogFromSnapshot(cache.snapshot),
    cache,
  }
}
