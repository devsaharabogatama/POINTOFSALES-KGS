export type SalesReturnCommercialLine = {
  sourceLineId: string
  productCode?: string | null
  productName?: string | null
  uomCode?: string | null
  uomName?: string | null
  baseQtyPerUom: number
  fulfilledBaseQty: number
  fulfilledQtyUom: number
  receivedBaseQty: number
  receivedQtyUom: number
  restockedBaseQty: number
  destroyedBaseQty: number
  creditedBaseQty: number
  creditedAmount: number
}

export type SalesReturnCommercialAdjustment = {
  sourceKind: 'BACKOFFICE' | 'RETAINED_RETAIL'
  sourceId: string
  receivedBaseQty: number
  restockedBaseQty: number
  destroyedBaseQty: number
  creditedAmount: number
  lines: SalesReturnCommercialLine[]
}

type JsonRecord = Record<string, unknown>

export function salesReturnAdjustmentMap(data: unknown) {
  const payload = data as { data?: unknown[] } | null
  const rows = Array.isArray(payload?.data) ? payload.data as JsonRecord[] : []
  return new Map(rows.filter((row) => typeof row.sourceKind === 'string'
      && typeof row.sourceId === 'string')
    .map((row) => [`${row.sourceKind}:${row.sourceId}`,
      row as SalesReturnCommercialAdjustment]))
}

export function netCommercialAmount(originalAmount: number, creditedAmount?: number | null) {
  return Math.max(0, Number(originalAmount || 0) - Number(creditedAmount || 0))
}
