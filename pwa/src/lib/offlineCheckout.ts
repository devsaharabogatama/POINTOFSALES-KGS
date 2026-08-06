import type {
  OfflineAllowanceAvailability,
  OfflineCatalogSnapshot,
} from './offlineCatalog'
import type { OfflineSalePayload } from './offline'

type OfflineCartLine = {
  lineKey: string
  productUomId: string
  quantity: number
  discountType: '' | 'AMOUNT' | 'PERCENT'
  discountInput: number
}

type OfflinePaymentInput = {
  clientPaymentKey: string
  paymentMethodId: string
  amount: string
  tenderedAmount: string
  proofUrl: string
}

export type OfflineCheckoutLine = {
  lineKey: string
  productId: string
  productUomId: string
  productName: string
  uomName: string
  quantity: number
  unitPrice: number
  lineDiscount: number
  lineTotal: number
  requiredBaseQty: number
}

export type OfflineCheckoutPreview = {
  customerId: string
  customerName: string
  selectedPricelistId: string | null
  selectedPricelistName: string
  pricingSelectionSource: 'AUTO' | 'CASHIER_OVERRIDE'
  lines: OfflineCheckoutLine[]
  subtotal: number
  itemDiscount: number
  globalDiscount: number
  totalBeforeRounding: number
  roundingAdjustment: number
  grandTotal: number
}

function round4(value: number) {
  return Math.round((value + Number.EPSILON) * 10_000) / 10_000
}

function round6(value: number) {
  return Math.round((value + Number.EPSILON) * 1_000_000) / 1_000_000
}

function finiteNonnegative(value: number, code: string) {
  if (!Number.isFinite(value) || value < 0) throw new Error(code)
  return value
}

function validAt(
  row: { validFrom?: string | null; validUntil?: string | null },
  timestamp: number,
) {
  const validFrom = row.validFrom ? Date.parse(row.validFrom) : null
  const validUntil = row.validUntil ? Date.parse(row.validUntil) : null
  return (
    (validFrom === null || validFrom <= timestamp) &&
    (validUntil === null || validUntil >= timestamp)
  )
}

function resolvePricelist(
  snapshot: OfflineCatalogSnapshot,
  customerId: string,
  selectedPricelistId: string,
) {
  const customer = snapshot.customers.find((item) => item.id === customerId)
  if (!customer) throw new Error('OFFLINE_CUSTOMER_NOT_IN_SNAPSHOT')
  const timestamp = Date.parse(snapshot.snapshotAt)
  const eligible = snapshot.pricelists.filter(
    (item) =>
      validAt(item, timestamp) &&
      (item.scope === 'GLOBAL' || item.id === customer.defaultPricelistId),
  )
  if (selectedPricelistId) {
    const selected = eligible.find((item) => item.id === selectedPricelistId)
    if (!selected) throw new Error('OFFLINE_PRICELIST_NOT_ELIGIBLE')
    return {
      customer,
      pricelists: [selected],
      selectedPricelist: selected,
      source: 'CASHIER_OVERRIDE' as const,
    }
  }
  return {
    customer,
    pricelists: eligible.filter(
      (item) =>
        item.id === customer.defaultPricelistId ||
        (item.scope === 'GLOBAL' && item.isDefault),
    ),
    selectedPricelist: null,
    source: 'AUTO' as const,
  }
}

export function priceOfflineCheckout(input: {
  snapshot: OfflineCatalogSnapshot
  allowances: OfflineAllowanceAvailability[]
  customerId: string
  selectedPricelistId: string
  lines: OfflineCartLine[]
  globalDiscount: number
  roundingDirection: 'NONE' | 'DOWN' | 'UP'
  roundingIncrement?: number
}): OfflineCheckoutPreview {
  const {
    snapshot,
    allowances,
    customerId,
    selectedPricelistId,
    lines,
    roundingDirection,
  } = input
  if (lines.length === 0) throw new Error('OFFLINE_CART_REQUIRED')
  const globalDiscount = round4(
    finiteNonnegative(
      Number(input.globalDiscount),
      'GLOBAL_DISCOUNT_INVALID',
    ),
  )
  const roundingIncrement = finiteNonnegative(
    Number(input.roundingIncrement ?? 100),
    'ROUNDING_CONTRACT_INVALID',
  )
  if (roundingIncrement <= 0) throw new Error('ROUNDING_CONTRACT_INVALID')

  const { customer, pricelists, selectedPricelist, source } = resolvePricelist(
    snapshot,
    customerId,
    selectedPricelistId,
  )
  const snapshotAt = Date.parse(snapshot.snapshotAt)
  const productUoms = new Map(
    snapshot.productUoms.map((item) => [item.productUomId, item]),
  )
  const requirements = new Map<string, number>()
  const pricedLines = lines.map((line) => {
    const productUom = productUoms.get(line.productUomId)
    if (!productUom || !productUom.offlineEligible || productUom.isBundle) {
      throw new Error('OFFLINE_PRODUCT_UOM_NOT_ELIGIBLE')
    }
    const quantity = Number(line.quantity)
    if (!Number.isFinite(quantity) || quantity <= 0) {
      throw new Error('OFFLINE_LINE_QUANTITY_INVALID')
    }
    const precisionFactor = 10 ** productUom.decimalPrecision
    if (
      (!productUom.allowDecimal && !Number.isInteger(quantity)) ||
      Math.abs(quantity * precisionFactor - Math.round(quantity * precisionFactor)) >
        0.000001
    ) {
      throw new Error('OFFLINE_LINE_QUANTITY_PRECISION_INVALID')
    }

    const pricelistMap = new Map(
      pricelists.map((pricelist) => [pricelist.id, pricelist]),
    )
    const eligibleRules = snapshot.pricelistRules
      .filter((rule) => {
        if (
          !pricelistMap.has(rule.pricelistId) ||
          rule.productId !== productUom.productId ||
          rule.productUomId !== productUom.productUomId ||
          !validAt(rule, snapshotAt)
        ) {
          return false
        }
        const tierQuantity =
          rule.tierQtyBasis === 'BASE_UOM_EQUIVALENT'
            ? quantity * productUom.factorToBase
            : quantity
        return rule.minQty <= tierQuantity
      })
      .sort(
        (left, right) => {
          const leftPricelist = pricelistMap.get(left.pricelistId)
          const rightPricelist = pricelistMap.get(right.pricelistId)
          const leftRank = leftPricelist?.scope === 'CUSTOMER' ? 1 : 2
          const rightRank = rightPricelist?.scope === 'CUSTOMER' ? 1 : 2
          return (
            leftRank - rightRank ||
            Number(rightPricelist?.priority ?? 0) -
              Number(leftPricelist?.priority ?? 0) ||
            right.minQty - left.minQty ||
            left.id.localeCompare(right.id)
          )
        },
      )
    const rule = eligibleRules[0]
    let unitPrice = productUom.baseUnitPrice
    if (rule?.pricingMethod === 'FIXED_PRICE') {
      unitPrice = Number(rule.fixedUnitPrice)
    } else if (rule?.pricingMethod === 'DISCOUNT_AMOUNT') {
      unitPrice = Math.max(
        productUom.baseUnitPrice - Number(rule.discountAmountPerUnit),
        0,
      )
    } else if (rule?.pricingMethod === 'DISCOUNT_PERCENT') {
      unitPrice = round4(
        productUom.baseUnitPrice *
          (100 - Number(rule.discountPercent)) /
          100,
      )
    }
    unitPrice = round4(
      finiteNonnegative(unitPrice, 'OFFLINE_SNAPSHOT_PRICE_INVALID'),
    )
    const gross = round4(unitPrice * quantity)
    const discountInput = finiteNonnegative(
      Number(line.discountInput || 0),
      'LINE_DISCOUNT_INVALID',
    )
    const lineDiscount =
      line.discountType === 'AMOUNT'
        ? round4(discountInput)
        : line.discountType === 'PERCENT'
          ? round4(gross * discountInput / 100)
          : 0
    if (
      (line.discountType === 'PERCENT' && discountInput > 100) ||
      lineDiscount > gross
    ) {
      throw new Error('LINE_DISCOUNT_EXCEEDS_LINE_TOTAL')
    }
    const requiredBaseQty = round6(quantity * productUom.factorToBase)
    requirements.set(
      productUom.productId,
      round6(
        (requirements.get(productUom.productId) ?? 0) + requiredBaseQty,
      ),
    )
    return {
      lineKey: line.lineKey,
      productId: productUom.productId,
      productUomId: productUom.productUomId,
      productName: productUom.name,
      uomName: productUom.uomName,
      quantity,
      unitPrice,
      lineDiscount,
      lineTotal: round4(gross - lineDiscount),
      requiredBaseQty,
    }
  })

  for (const [productId, requiredBaseQty] of requirements) {
    const allowance = allowances.find((item) => item.productId === productId)
    if (!allowance) throw new Error('OFFLINE_ALLOWANCE_REQUIRED')
    if (allowance.locallyAvailableBaseQty + 0.000001 < requiredBaseQty) {
      throw new Error('OFFLINE_ALLOWANCE_INSUFFICIENT')
    }
  }

  const subtotal = round4(
    pricedLines.reduce(
      (total, line) => total + line.unitPrice * line.quantity,
      0,
    ),
  )
  const itemDiscount = round4(
    pricedLines.reduce((total, line) => total + line.lineDiscount, 0),
  )
  const preGlobalTotal = round4(
    pricedLines.reduce((total, line) => total + line.lineTotal, 0),
  )
  if (globalDiscount > preGlobalTotal) {
    throw new Error('GLOBAL_DISCOUNT_EXCEEDS_SALE_TOTAL')
  }
  const totalBeforeRounding = round4(preGlobalTotal - globalDiscount)
  const grandTotal =
    roundingDirection === 'DOWN'
      ? round4(
          Math.floor(totalBeforeRounding / roundingIncrement) *
            roundingIncrement,
        )
      : roundingDirection === 'UP'
        ? round4(
            Math.ceil(totalBeforeRounding / roundingIncrement) *
              roundingIncrement,
          )
        : totalBeforeRounding

  return {
    customerId: customer.id,
    customerName: customer.name,
    selectedPricelistId: selectedPricelist?.id ?? null,
    selectedPricelistName:
      selectedPricelist?.name ?? 'Otomatis (Customer / Global)',
    pricingSelectionSource: source,
    lines: pricedLines,
    subtotal,
    itemDiscount,
    globalDiscount,
    totalBeforeRounding,
    roundingAdjustment: round4(grandTotal - totalBeforeRounding),
    grandTotal,
  }
}

export function buildOfflineSalePayload(input: {
  preview: OfflineCheckoutPreview
  clientTransactionId: string
  cashierSessionId: string
  lines: OfflineCartLine[]
  payments: OfflinePaymentInput[]
  snapshot: OfflineCatalogSnapshot
  roundingDirection: 'NONE' | 'DOWN' | 'UP'
}): OfflineSalePayload {
  const { preview, snapshot } = input
  if (input.payments.length === 0) throw new Error('PAYMENT_LEGS_REQUIRED')
  const usedMethods = new Set<string>()
  const payments = input.payments.map((payment) => {
    const method = snapshot.paymentMethods.find(
      (item) => item.id === payment.paymentMethodId,
    )
    if (!method) throw new Error('OFFLINE_PAYMENT_METHOD_NOT_ELIGIBLE')
    if (usedMethods.has(method.id)) throw new Error('DUPLICATE_PAYMENT_METHOD')
    usedMethods.add(method.id)
    const amount =
      input.payments.length === 1 && payment.amount.trim() === ''
        ? preview.grandTotal
        : Number(payment.amount)
    if (!Number.isFinite(amount) || amount <= 0) {
      throw new Error('PAYMENT_LEG_AMOUNT_REQUIRED')
    }
    const tenderedAmount =
      method.methodType === 'CASH'
        ? Number(payment.tenderedAmount || amount)
        : amount
    if (!Number.isFinite(tenderedAmount) || tenderedAmount < amount) {
      throw new Error('PAYMENT_TENDER_INSUFFICIENT')
    }
    return {
      clientPaymentKey: payment.clientPaymentKey,
      paymentMethodId: method.id,
      amount: round4(amount),
      tenderedAmount: round4(tenderedAmount),
      ...(payment.proofUrl.trim()
        ? { proofUrl: payment.proofUrl.trim() }
        : {}),
    }
  })
  const paymentTotal = round4(
    payments.reduce((total, payment) => total + payment.amount, 0),
  )
  if (Math.abs(paymentTotal - preview.grandTotal) > 0.0001) {
    throw new Error('PAYMENT_LEG_TOTAL_MISMATCH')
  }
  const snapshotPrices = new Map(
    preview.lines.map((line) => [line.lineKey, line.unitPrice]),
  )
  return {
    clientTransactionId: input.clientTransactionId,
    cashierSessionId: input.cashierSessionId,
    customerId: preview.customerId,
    selectedPricelistId: preview.selectedPricelistId,
    pricingSelectionSource: preview.pricingSelectionSource,
    isTempo: false,
    globalDiscount: preview.globalDiscount,
    roundingDirection: input.roundingDirection,
    roundingIncrement: 100,
    lines: input.lines.map((line) => ({
      lineKey: line.lineKey,
      productUomId: line.productUomId,
      quantity: line.quantity,
      snapshotUnitPrice:
        snapshotPrices.get(line.lineKey) ??
        (() => {
          throw new Error('OFFLINE_SNAPSHOT_PRICE_MISSING')
        })(),
      ...(line.discountType
        ? {
            lineDiscountType: line.discountType,
            lineDiscountInput: line.discountInput,
          }
        : {}),
    })),
    payments,
  }
}
