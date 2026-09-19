'use client'

import { useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import { SalesDocumentView, type InvoiceSummary } from './SalesDocumentView'
import { retailStatusLabel, type RetailHistory } from '@/lib/office-retail-history'
import { netCommercialAmount } from '@/lib/sales-return-commercial'

const money = (value: number) => new Intl.NumberFormat('id-ID', { style: 'currency', currency: 'IDR', maximumFractionDigits: 0 }).format(value)
export function OfficeRetailHistoryDetail({ row, session, companyName, notify, back, openReturn }: {
  row: RetailHistory; session: Session; companyName: string;
  notify: (message: string) => void; back: () => void;
  openReturn?: (retailSalesId: string) => void;
}) {
  const [invoice, setInvoice] = useState<InvoiceSummary | null>(null)
  const returnedLines = new Map((row.returnAdjustment?.lines ?? []).map((line) => [line.sourceLineId, line]))
  const creditedAmount = Number(row.returnAdjustment?.creditedAmount ?? row.creditedAmount ?? 0)
  const netAmount = netCommercialAmount(row.total, creditedAmount)
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
        <tbody>{row.lines.map((line) => {const returned=returnedLines.get(line.id);const returnedQty=Number(returned?.receivedQtyUom??0);const fulfilled=Number(returned?.fulfilledQtyUom??line.quantity);return <tr key={line.id}><td className="p-3">{line.productName ?? '-'}{returnedQty>0&&<span className="block text-xs font-bold text-violet-700">Diretur {returnedQty}{Number(returned?.restockedBaseQty??0)>0?' · Masuk stok':''}{Number(returned?.destroyedBaseQty??0)>0?' · Dihancurkan':''}</span>}</td><td className="p-3 text-right"><span className="block">Awal {line.quantity}</span>{returnedQty>0&&<span className="text-xs font-black text-violet-700">Sisa di Customer {Math.max(0,fulfilled-returnedQty)}</span>}</td><td className="p-3 text-right">{money(line.unitPrice)}</td><td className="p-3 text-right">{money(line.total)}{Number(returned?.creditedAmount??0)>0&&<span className="block text-xs font-bold text-violet-700">Kredit -{money(Number(returned?.creditedAmount))}</span>}</td></tr>})}</tbody>
      </table></div>
      <div className="ml-auto mt-4 max-w-md space-y-2 rounded-xl bg-slate-50 p-4 text-sm"><div className="flex justify-between"><span>Total order awal</span><strong>{money(row.total)}</strong></div>{row.returnAdjustment&&<><div className="flex justify-between text-violet-700"><span>Credit Note posted</span><strong>-{money(creditedAmount)}</strong></div><div className="flex justify-between border-t pt-3 text-lg font-black"><span>Nilai bersih</span><span>{money(netAmount)}</span></div>{Number(row.returnAdjustment.receivedBaseQty)>0&&creditedAmount===0&&<p className="text-xs text-amber-700">Barang retur sudah diterima. Nilai bersih menunggu Credit Note diposting Finance.</p>}</>}</div>
      {row.notes && <p className="mt-4 text-slate-600">{row.notes}</p>}
      <div className="mt-4 flex flex-wrap gap-3">{row.invoiceSnapshotId && <button onClick={() => setInvoice({ salesId: row.id,
        invoiceSnapshotId: row.invoiceSnapshotId!, invoiceNo: row.invoiceNo ?? row.documentNo,
        snapshotProvenance: row.snapshotProvenance ?? '', postedAt: row.createdAt,
        invoiceDate: row.orderDate, total: row.total, fulfillmentMode: row.fulfillmentMode,
        sourceChannel: row.sourceChannel, customerName: row.customerName ?? '-', storeName: row.storeName ?? '-',
        invoiceStatus: row.documentStatus === 'CANCELED' ? 'CANCELED' : 'ACTIVE',
        orderRuntimeStatus: row.status, commercialStatus: row.commercialStatus,
        creditedAmount, returnNo: row.returnNo, creditNoteNo: row.creditNoteNo,
        masterVersion: row.masterVersion, canCancel: false,
      })} className="rounded-xl border border-slate-200 px-4 py-3 font-bold">Buka Invoice asli</button>}
      {openReturn && row.documentStatus !== 'CANCELED' && ['DELIVERED','LEGACY_POSTED'].includes(row.status) && <button onClick={() => openReturn(row.id)} className="rounded-xl bg-amber-600 px-4 py-3 font-bold text-white">Buat Retur</button>}</div>
      <p className="mt-4 text-sm text-slate-500">Pencatatan tetap pada dokumen asal. Tidak dibuat ulang sebagai SO atau Invoice baru.</p>
    </section>
  </div>
}
