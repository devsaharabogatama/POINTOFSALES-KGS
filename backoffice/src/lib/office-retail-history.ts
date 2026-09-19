import type { SalesReturnCommercialAdjustment } from './sales-return-commercial'

export type RetailHistory = {
  id: string; companyId: string; documentNo: string; invoiceNo: string | null;
  invoiceSnapshotId: string | null; status: string; documentStatus: string;
  masterVersion: number; fulfillmentMode: 'PICKUP' | 'DELIVERY'; sourceChannel: string;
  createdAt: string; snapshotProvenance: string | null;
  kind: 'QUOTATION' | 'SALES_ORDER'; orderDate: string | null;
  deliveryDate: string | null; dueDate: string | null; customerName: string | null;
  storeName: string | null; total: number; notes: string | null;
  targetId: string | null; targetNo: string | null;
  commercialStatus?: 'ACTIVE' | 'RETURN_IN_PROGRESS' | 'PARTIALLY_RETURNED' | 'RETURNED' | 'CANCELED';
  creditedAmount?: number; returnNo?: string | null; creditNoteNo?: string | null;
  returnAdjustment?: SalesReturnCommercialAdjustment | null;
  lines: { id: string; productName: string | null; quantity: number; unitPrice: number; total: number }[];
}
export function retailStatusLabel(row: RetailHistory) {
  if (row.documentStatus === 'CANCELED') return 'Dibatalkan'
  return ({ DRAFT_INPUT: 'Draft', SCHEDULED: 'Terjadwal', CONFIRMED: 'Dikonfirmasi',
    RESERVED: 'Stok dicadangkan', PARTIALLY_DISPATCHED: 'Dikirim sebagian',
    DISPATCHED: 'Dalam perjalanan', DELIVERED: 'Selesai', LEGACY_POSTED: 'Posted',
    CANCELED: 'Dibatalkan' } as Record<string, string>)[row.status] ?? row.status
}
export function filterRetailHistory(rows: RetailHistory[], filters: {
  companyId: string; kind: string; search: string; fulfillment: string;
  invoice: string; dateBasis: string; dateFrom: string; dateTo: string;
}) {
  const keyword = filters.search.trim().toLowerCase()
  return rows.filter((row) => {
    const date = filters.dateBasis === 'DUE_DATE' ? row.dueDate
      : filters.dateBasis === 'DELIVERY_DATE' ? row.deliveryDate : row.orderDate
    const fulfillment = row.documentStatus === 'CANCELED' ? 'CANCELED' :
      ({ CONFIRMED: 'CONFIRMED', RESERVED: 'CONFIRMED', PARTIALLY_DISPATCHED: 'PARTIALLY_SHIPPED',
        DISPATCHED: 'IN_TRANSIT', DELIVERED: 'COMPLETED', CANCELED: 'CANCELED' } as Record<string, string>)[row.status]
    return row.companyId === filters.companyId && !row.targetId && row.kind === filters.kind
      && (!filters.fulfillment || fulfillment === filters.fulfillment)
      && (!filters.invoice || (row.invoiceSnapshotId ? 'INVOICED' : 'NOT_READY') === filters.invoice)
      && (!filters.dateFrom || Boolean(date && date >= filters.dateFrom))
      && (!filters.dateTo || Boolean(date && date <= filters.dateTo))
      && (!keyword || [row.documentNo, row.invoiceNo, row.customerName, row.storeName].some((value) => value?.toLowerCase().includes(keyword)))
  })
}
