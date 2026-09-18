"use client";

import { useCallback, useEffect, useState, type ReactNode } from "react";
import type { Session } from "@supabase/supabase-js";
import { ClipboardCheck, Loader2, PackageCheck, RefreshCw, RotateCcw, X } from "lucide-react";
import { userFacingError } from "@/lib/user-facing-error";

type Line = { id:string; productCode:string; productName:string; uomName:string; requestedQtyUom:number; baseQtyPerUom:number; receivedBaseQty:number };
type ReturnDocument = { id:string; returnNo:string; salesOrderNo:string; customerSnapshot:{name?:string}; status:string; masterVersion:number; totalRequestedBaseQty:number; totalReceivedBaseQty:number; lines:Line[] };
type WarehouseOption = { id:string; code:string; name:string };
type Workspace = { data:ReturnDocument[]; warehouses:WarehouseOption[]; effectiveCapabilities:string[] };
type FormLine = { key:string; returnLineId:string; quantityUom:string; warehouseId:string; disposition:"RESTOCK"|"DESTROY"; notes:string };

const auth = (session:Session,json=false) => ({ Authorization:`Bearer ${session.access_token}`,...(json?{"Content-Type":"application/json"}:{}) });
const friendly = (value?:string) => userFacingError(value,{
  CUSTOM_PERMISSION_DENIED:"Anda tidak memiliki akses posting Penerimaan Retur Customer.",
  BACKOFFICE_SALES_RETURN_RECEIPT_STATE_INVALID:"Retur belum disetujui atau statusnya sudah berubah.",
  BACKOFFICE_SALES_RETURN_RECEIPT_QUANTITY_EXCEEDS_APPROVED:"Qty diterima melebihi sisa Retur yang disetujui.",
  BACKOFFICE_SALES_RETURN_RECEIPT_WAREHOUSE_INVALID:"Pilih Gudang aktif untuk setiap barang.",
  BACKOFFICE_SALES_RETURN_SOURCE_FIFO_EXHAUSTED:"Jejak biaya barang yang sebelumnya diterima Customer tidak cukup. Dokumen tidak diposting.",
  MASTER_VERSION_CONFLICT:"Dokumen berubah di tab lain. Muat ulang.",
},"Penerimaan Retur Customer belum berhasil.");
async function json(response:Response){const result=await response.json().catch(()=>({}));if(!response.ok)throw new Error(friendly(result.error));return result}
const number = (value:number) => Number(value||0).toLocaleString("id-ID",{maximumFractionDigits:6});
const today = () => new Date().toLocaleDateString("en-CA");

export function CustomerReturnReceiptView({session,companyId,notify}:{session:Session;companyId:string;notify:(value:string)=>void}){
  const [workspace,setWorkspace]=useState<Workspace>({data:[],warehouses:[],effectiveCapabilities:[]});
  const [selected,setSelected]=useState<ReturnDocument|null>(null);
  const [lines,setLines]=useState<FormLine[]>([]);
  const [receiptDate,setReceiptDate]=useState(today());
  const [notes,setNotes]=useState("");
  const [loading,setLoading]=useState(true);
  const [busy,setBusy]=useState(false);
  const [error,setError]=useState("");

  const load=useCallback(async()=>{setLoading(true);setError("");try{setWorkspace(await fetch("/api/inventory/customer-return-receipts",{headers:auth(session),cache:"no-store"}).then(json))}catch(cause){setError(cause instanceof Error?cause.message:"Penerimaan retur gagal dimuat.")}finally{setLoading(false)}},[session]);
  useEffect(()=>{
    // eslint-disable-next-line react-hooks/set-state-in-effect -- remote workspace follows the active Company
    void load()
  },[companyId,load]);

  function open(row:ReturnDocument){
    const warehouseId=workspace.warehouses[0]?.id??"";
    setSelected(row);setReceiptDate(today());setNotes("");
    setLines(row.lines.filter(line=>line.requestedQtyUom-line.receivedBaseQty/line.baseQtyPerUom>0).map(line=>({key:crypto.randomUUID(),returnLineId:line.id,quantityUom:String(line.requestedQtyUom-line.receivedBaseQty/line.baseQtyPerUom),warehouseId,disposition:"RESTOCK",notes:""})));
    setError("");
  }

  async function post(){
    if(!selected)return;
    setBusy(true);setError("");
    try{
      const result=await fetch(`/api/inventory/customer-return-receipts/${selected.id}/post`,{method:"POST",headers:auth(session,true),body:JSON.stringify({masterVersion:selected.masterVersion,operationId:crypto.randomUUID(),receiptDate,notes,lines:lines.filter(line=>Number(line.quantityUom)>0)})}).then(json);
      notify(`${result.receiptNo} berhasil diposting. Disposition stok tercatat.`);setSelected(null);await load();
    }catch(cause){setError(cause instanceof Error?cause.message:"Penerimaan retur gagal diposting.")}finally{setBusy(false)}
  }

  const canPost=workspace.effectiveCapabilities.includes("POST");
  const pendingQuantity=(row:ReturnDocument)=>Math.max(Number(row.totalRequestedBaseQty)-Number(row.totalReceivedBaseQty),0);
  const invalidLines=lines.some(line=>Number(line.quantityUom)>0&&(!line.warehouseId||(line.disposition==="DESTROY"&&!line.notes.trim())));
  const canSubmit=lines.some(line=>Number(line.quantityUom)>0)&&!invalidLines;

  return <div className="space-y-6">
    <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm sm:p-7"><div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between"><div><p className="text-xs font-black uppercase tracking-[.2em] text-blue-700">Inventory · Retur Customer</p><h1 className="mt-2 text-3xl font-black text-slate-950">Penerimaan Retur Customer</h1><p className="mt-1 text-sm text-slate-500">Periksa barang yang kembali, pilih Gudang tujuan, lalu tentukan masuk stok atau dihancurkan.</p></div><button onClick={()=>void load()} disabled={loading} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-xl border border-slate-200 bg-white px-4 font-bold text-slate-700 hover:bg-slate-50 disabled:opacity-60"><RefreshCw className={`h-4 w-4 ${loading?"animate-spin":""}`}/> Muat ulang</button></div></section>
    {error&&!selected&&<ErrorBanner message={error}/>}
    <section className="overflow-hidden rounded-3xl border border-slate-200 bg-white shadow-sm"><div className="border-b border-slate-200 px-6 py-5"><h2 className="text-lg font-black text-slate-950">Dokumen menunggu penerimaan</h2><p className="mt-1 text-sm text-slate-500">Setiap dokumen berasal dari Retur Customer yang sudah disetujui.</p></div><div className="overflow-x-auto"><table className="w-full min-w-[880px] text-left text-sm"><thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500"><tr><th className="px-6 py-4">Nomor retur</th><th className="px-4 py-4">Sales Order</th><th className="px-4 py-4">Customer</th><th className="px-4 py-4 text-right">Diajukan</th><th className="px-4 py-4 text-right">Sisa diterima</th><th className="px-6 py-4 text-right">Aksi</th></tr></thead><tbody className="divide-y divide-slate-100">{workspace.data.map(row=><tr key={row.id} className="hover:bg-slate-50"><td className="px-6 py-5"><b className="block text-base text-slate-950">{row.returnNo}</b><span className="mt-1 inline-flex rounded-full bg-amber-100 px-2.5 py-1 text-[11px] font-black text-amber-900">Menunggu Gudang</span></td><td className="px-4 py-5 font-bold text-slate-800">{row.salesOrderNo}</td><td className="px-4 py-5 font-semibold">{row.customerSnapshot.name??"Customer"}</td><td className="px-4 py-5 text-right font-semibold">{number(row.totalRequestedBaseQty)}</td><td className="px-4 py-5 text-right"><b className="text-blue-700">{number(pendingQuantity(row))}</b><small className="block text-slate-500">diterima {number(row.totalReceivedBaseQty)}</small></td><td className="px-6 py-5 text-right"><button disabled={!canPost} onClick={()=>open(row)} className="inline-flex min-h-10 items-center gap-2 rounded-xl bg-slate-950 px-4 font-black text-white hover:bg-slate-800 disabled:cursor-not-allowed disabled:bg-slate-300"><ClipboardCheck className="h-4 w-4"/> Proses terima</button></td></tr>)}</tbody></table></div>{!loading&&!workspace.data.length&&<Empty/>}{loading&&!workspace.data.length&&<div className="flex items-center justify-center gap-2 p-12 text-sm font-semibold text-slate-500"><Loader2 className="h-5 w-5 animate-spin"/> Memuat dokumen retur…</div>}</section>

    {selected&&<div className="fixed inset-0 z-[90] overflow-y-auto bg-slate-950/65 p-3 sm:p-6" onMouseDown={event=>{if(event.target===event.currentTarget&&!busy)setSelected(null)}}><section role="dialog" aria-modal="true" className="mx-auto flex min-h-full max-w-6xl items-center justify-center"><div className="w-full overflow-hidden rounded-3xl bg-white shadow-2xl">
      <header className="flex items-start justify-between gap-4 border-b border-slate-200 p-5 sm:p-6"><div><p className="text-xs font-black uppercase tracking-[.18em] text-blue-700">Inventory · Penerimaan Retur</p><h2 className="mt-2 text-2xl font-black text-slate-950 sm:text-3xl">{selected.returnNo}</h2><p className="mt-1 text-sm text-slate-500">{selected.salesOrderNo} · {selected.customerSnapshot.name??"Customer"}</p></div><button disabled={busy} onClick={()=>setSelected(null)} aria-label="Tutup" className="rounded-xl border border-slate-200 p-2.5 text-slate-600 hover:bg-slate-50"><X className="h-5 w-5"/></button></header>
      <div className="max-h-[75vh] space-y-5 overflow-y-auto p-5 sm:p-6">{error&&<ErrorBanner message={error}/>}<div className="grid overflow-hidden rounded-2xl border border-slate-200 sm:grid-cols-3"><Metric label="Qty diajukan" value={number(selected.totalRequestedBaseQty)}/><Metric label="Sudah diterima" value={number(selected.totalReceivedBaseQty)}/><Metric label="Sisa diterima" value={number(pendingQuantity(selected))}/></div>
        <section className="rounded-2xl border border-slate-200 p-4 sm:p-5"><div className="mb-4 flex items-center gap-3"><span className="grid h-10 w-10 place-items-center rounded-xl bg-blue-50 text-blue-700"><ClipboardCheck className="h-5 w-5"/></span><div><h3 className="font-black text-slate-950">Informasi penerimaan</h3><p className="text-sm text-slate-500">Tanggal aktual dan catatan dokumen Gudang.</p></div></div><div className="grid gap-4 sm:grid-cols-2"><Field label="Tanggal penerimaan"><input type="date" max={today()} value={receiptDate} onChange={event=>setReceiptDate(event.target.value)} className="input"/></Field><Field label="Catatan dokumen (opsional)"><input value={notes} onChange={event=>setNotes(event.target.value)} maxLength={2000} className="input" placeholder="Tambahkan informasi penerimaan"/></Field></div></section>
        <section className="overflow-hidden rounded-2xl border border-slate-200"><div className="border-b border-slate-200 px-5 py-4"><h3 className="font-black text-slate-950">Barang yang diterima</h3><p className="mt-1 text-sm text-slate-500">Qty otomatis mengikuti sisa Retur dan masih dapat disesuaikan.</p></div><div className="divide-y divide-slate-200">{lines.map(line=>{const source=selected.lines.find(item=>item.id===line.returnLineId);const remaining=(source?.requestedQtyUom??0)-(source?.receivedBaseQty??0)/(source?.baseQtyPerUom||1);return <article key={line.key} className="p-4 sm:p-5"><div className="mb-4 flex flex-wrap items-start justify-between gap-2"><div><b className="text-base text-slate-950">{source?.productName}</b><span className="mt-1 block text-xs text-slate-500">{source?.productCode} · maksimal {number(remaining)} {source?.uomName}</span></div><span className={`rounded-full px-3 py-1 text-xs font-black ${line.disposition==="RESTOCK"?"bg-emerald-100 text-emerald-800":"bg-rose-100 text-rose-800"}`}>{line.disposition==="RESTOCK"?"Masuk stok":"Dihancurkan"}</span></div><div className="grid gap-4 md:grid-cols-[180px_1fr_220px]"><Field label={`Qty diterima (${source?.uomName??"UOM"})`}><input type="number" min="0" step="any" max={remaining} value={line.quantityUom} onChange={event=>setLines(current=>current.map(item=>item.key===line.key?{...item,quantityUom:event.target.value}:item))} className="input"/></Field><Field label="Gudang tujuan"><select value={line.warehouseId} onChange={event=>setLines(current=>current.map(item=>item.key===line.key?{...item,warehouseId:event.target.value}:item))} className="input"><option value="">Pilih Gudang</option>{workspace.warehouses.map(warehouse=><option key={warehouse.id} value={warehouse.id}>{warehouse.code} · {warehouse.name}</option>)}</select></Field><Field label="Tindakan barang"><select value={line.disposition} onChange={event=>setLines(current=>current.map(item=>item.key===line.key?{...item,disposition:event.target.value as FormLine["disposition"]}:item))} className="input"><option value="RESTOCK">Masuk stok</option><option value="DESTROY">Dihancurkan</option></select></Field></div>{line.disposition==="DESTROY"&&<div className="mt-4"><Field label="Catatan pemusnahan (wajib)"><input value={line.notes} onChange={event=>setLines(current=>current.map(item=>item.key===line.key?{...item,notes:event.target.value}:item))} className="input" placeholder="Jelaskan alasan barang dihancurkan"/></Field></div>}</article>})}</div></section>
      </div>
      <footer className="flex flex-wrap items-center justify-between gap-3 border-t border-slate-200 bg-slate-50 px-5 py-4 sm:px-6"><p className="text-xs text-slate-500">Posting mencatat disposition dan pergerakan stok secara bersamaan.</p><div className="flex gap-3"><button disabled={busy} onClick={()=>setSelected(null)} className="min-h-11 rounded-xl border border-slate-300 bg-white px-5 font-bold text-slate-700 hover:bg-slate-50">Batal</button><button disabled={busy||!canSubmit} onClick={()=>void post()} className="inline-flex min-h-11 items-center gap-2 rounded-xl bg-blue-700 px-5 font-black text-white hover:bg-blue-800 disabled:cursor-not-allowed disabled:bg-slate-300">{busy?<Loader2 className="h-4 w-4 animate-spin"/>:<PackageCheck className="h-4 w-4"/>} Post Penerimaan</button></div></footer>
    </div></section></div>}
  </div>;
}

function Field({label,children}:{label:string;children:ReactNode}){return <label className="block text-sm font-bold text-slate-700">{label}<div className="mt-2 [&_.input]:min-h-11 [&_.input]:w-full [&_.input]:rounded-xl [&_.input]:border [&_.input]:border-slate-300 [&_.input]:bg-white [&_.input]:px-3 [&_.input]:py-2.5 [&_.input]:font-normal [&_.input]:outline-none focus-within:[&_.input]:border-blue-500">{children}</div></label>}
function Metric({label,value}:{label:string;value:string}){return <div className="border-slate-200 p-4 sm:border-l sm:first:border-l-0 sm:p-5"><small className="font-bold uppercase tracking-wide text-slate-500">{label}</small><b className="mt-1 block text-lg text-slate-950">{value}</b></div>}
function ErrorBanner({message}:{message:string}){return <div className="rounded-2xl border border-rose-200 bg-rose-50 px-5 py-3 text-sm font-bold text-rose-800">{message}</div>}
function Empty(){return <div className="grid place-items-center p-12 text-center"><span className="grid h-12 w-12 place-items-center rounded-2xl bg-slate-100 text-slate-500"><RotateCcw className="h-6 w-6"/></span><b className="mt-3 text-slate-800">Belum ada Retur yang menunggu penerimaan</b><p className="mt-1 text-sm text-slate-500">Dokumen akan muncul setelah Retur Customer disetujui.</p></div>}
