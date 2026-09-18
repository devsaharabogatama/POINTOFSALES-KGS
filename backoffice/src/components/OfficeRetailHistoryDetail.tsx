'use client'

import { useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import { SalesDocumentView, type InvoiceSummary } from './SalesDocumentView'
import { retailStatusLabel, type RetailHistory } from '@/lib/office-retail-history'

const money = (value: number) => new Intl.NumberFormat('id-ID', { style: 'currency', currency: 'IDR', maximumFractionDigits: 0 }).format(value)
export function OfficeRetailHistoryDetail({ row, session, companyName, notify, back, openReturn }: {
  row: RetailHistory; session: Session; companyName: string;
  notify: (message: string) => void; back: () => void;
  openReturn?: (retailSalesId: string) => void;
}) {
  const [invoice, setInvoice] = useState<InvoiceSummary | null>(null)
  if (invoice) return <div className="space-y-4"><button onClick={() => setInvoice(null)} className="font-bold text-slate-600">← Dokumen asal</button><SalesDocumentView session={session} companyId={row.companyId} companyName={companyName} notify={notify} initialDocument={invoice} /></div>
  return <div className="space-y-5">
    <button onClick={back} className="font-bold text-slate-600">← Quotation & Sales Order</button>
    <section className="rounded-[24px] border border-slate-200 bg-white p-6">
      <div className="flex flex-wrap items-center gap-2"><span className="rounded-full bg-amber-100 px-2.5 py-1 text-xs font-black text-amber-900">Asal Retail</span><span className="text-xs font-bold text-slate-500">Histori sebelum mode Backoffice</span></div>
      <h1 className="mt-2 text-2xl font-black">{row.documentNo}</h1>
      <p className="mt-2 font-bold">{row.customerName ?? '-'} · {retailStatusLabel(row)}</p>
      <p className="text-sm text-slate-500">Tanggal order {row.orderDate ?? '-'} · {row.storeName ?? '-'}</p>
      <div className="mt-5 overflow-x-auto"><table className="w-full text-sm">
        <thead className="bg-slate-50 text-left"><tr><th className="p-3">Produk</th><th className="p-3 text-right">Qty</th><th className="p-3 text-right">Harga satuan</th><th className="p-3 text-right">Jumlah</th></tr></thead>
        <tbody>{row.lines.map((line) => <tr key={line.id}><td className="p-3">{line.productName ?? '-'}</td><td className="p-3 text-right">{line.quantity}</td><td className="p-3 text-right">{money(line.unitPrice)}</td><td className="p-3 text-right">{money(line.total)}</td></tr>)}</tbody>
      </table></div>
      <p className="mt-4 text-right font-black">Total {money(row.total)}</p>
      {row.notes && <p className="mt-4 text-slate-600">{row.notes}</p>}
      <div className="mt-4 flex flex-wrap gap-3">{row.invoiceSnapshotId && <button onClick={() => setInvoice({ salesId: row.id,
        invoiceSnapshotId: row.invoiceSnapshotId!, invoiceNo: row.invoiceNo ?? row.documentNo,
        snapshotProvenance: row.snapshotProvenance ?? '', postedAt: row.createdAt,
        invoiceDate: row.orderDate, total: row.total, fulfillmentMode: row.fulfillmentMode,
        sourceChannel: row.sourceChannel, customerName: row.customerName ?? '-', storeName: row.storeName ?? '-',
        invoiceStatus: row.documentStatus === 'CANCELED' ? 'CANCELED' : 'ACTIVE',
        orderRuntimeStatus: row.status, masterVersion: row.masterVersion, canCancel: false,
      })} className="rounded-xl border border-slate-200 px-4 py-3 font-bold">Buka Invoice asli</button>}
      {openReturn && row.documentStatus !== 'CANCELED' && ['DELIVERED','LEGACY_POSTED'].includes(row.status) && <button onClick={() => openReturn(row.id)} className="rounded-xl bg-amber-600 px-4 py-3 font-bold text-white">Buat Retur</button>}</div>
      <p className="mt-4 text-sm text-slate-500">Pencatatan tetap pada dokumen asal. Tidak dibuat ulang sebagai SO atau Invoice baru.</p>
    </section>
  </div>
}
