import { useCallback, useEffect, useMemo, useState } from 'react'
import { AlertTriangle, CheckCircle2, Loader2, Package, RefreshCw, Save, Send, X } from 'lucide-react'
import {
  cancelGoodsReceipt,
  loadGoodsReceiptWorkspace,
  postGoodsReceipt,
  saveGoodsReceipt,
  type CashierSession,
  type GoodsReceiptDraft,
  type GoodsReceiptOrder,
} from './lib/pos'

type FormLine={
  key:string
  sourceLineId:string
  uomId:string
  received:string
  detailed:boolean
  good:string
  damaged:string
  rejected:string
}

function friendly(message:string){
  const known:Record<string,string>={
    OPEN_CASHIER_SESSION_REQUIRED:'Sesi Kasir aktif tidak ditemukan.',
    RECEIVABLE_SUPPLIER_ORDER_NOT_FOUND:'Supplier Order sudah selesai, dibatalkan, atau tidak dapat diterima.',
    GOODS_RECEIPT_STORE_SCOPE_INVALID:'Supplier Order bukan untuk toko pada sesi ini.',
    GOODS_RECEIPT_LINES_REQUIRED:'Isi jumlah diterima minimal pada satu barang.',
    GOODS_RECEIPT_CONDITION_TOTAL_INVALID:'Jumlah baik, rusak, dan ditolak harus sama dengan jumlah diterima.',
    ACTIVE_DAMAGED_WAREHOUSE_NOT_FOUND:'Belum ada Gudang Rusak aktif untuk toko ini.',
    ACTIVE_PURCHASE_PRODUCT_UOM_NOT_FOUND:'Satuan pembelian sudah tidak aktif.',
    PURCHASE_UOM_REQUIRES_INTEGER:'Satuan ini hanya menerima jumlah bilangan bulat.',
    MASTER_VERSION_CONFLICT:'Draft berubah di perangkat lain. Muat ulang sebelum melanjutkan.',
    FINAL_GOODS_RECEIPT_IMMUTABLE:'Penerimaan yang sudah final tidak dapat diubah.',
    GOODS_RECEIPT_IDEMPOTENCY_CONFLICT:'Posting pernah diproses dengan identitas transaksi berbeda.',
  }
  return Object.entries(known).find(([code])=>message.includes(code))?.[1] ?? message
}

function numberText(value:number){return value.toLocaleString('id-ID',{maximumFractionDigits:6})}

function buildLines(order:GoodsReceiptOrder,draft?:GoodsReceiptDraft):FormLine[]{
  const draftBySource=new Map((draft?.lines ?? []).map((line)=>[line.supplierOrderLineId,line]))
  return order.lines.map((line)=>{
    const saved=draftBySource.get(line.id)
    const detailed=Boolean(saved && (saved.damagedQuantity>0 || saved.rejectedQuantity>0 || saved.acceptedGoodQuantity!==saved.receivedQuantity))
    return {
      key:saved?.clientLineKey ?? crypto.randomUUID(),sourceLineId:line.id,
      uomId:saved?.receivedUomId ?? line.orderedUomId,
      received:saved ? String(saved.receivedQuantity) : '',detailed,
      good:saved ? String(saved.acceptedGoodQuantity) : '',
      damaged:saved ? String(saved.damagedQuantity) : '0',
      rejected:saved ? String(saved.rejectedQuantity) : '0',
    }
  })
}

export function GoodsReceiptModal({companyId,cashierSession,close,completed}:{
  companyId:string
  cashierSession:CashierSession
  close:()=>void
  completed:(message:string)=>void
}){
  const [orders,setOrders]=useState<GoodsReceiptOrder[]>([])
  const [drafts,setDrafts]=useState<GoodsReceiptDraft[]>([])
  const [activeOrder,setActiveOrder]=useState<GoodsReceiptOrder|null>(null)
  const [activeDraft,setActiveDraft]=useState<GoodsReceiptDraft|null>(null)
  const [lines,setLines]=useState<FormLine[]>([])
  const [deliveryNo,setDeliveryNo]=useState('')
  const [notes,setNotes]=useState('')
  const [busy,setBusy]=useState(true)
  const [error,setError]=useState('')
  const [notice,setNotice]=useState('')
  const sourceById=useMemo(()=>new Map(activeOrder?.lines.map((line)=>[line.id,line]) ?? []),[activeOrder])

  const load=useCallback(async()=>{
    setBusy(true);setError('')
    try{
      const result=await loadGoodsReceiptWorkspace(companyId,cashierSession.storeId,cashierSession.id)
      setOrders(result.orders);setDrafts(result.drafts)
    }catch(reason){setError(friendly(reason instanceof Error?reason.message:'Gagal memuat penerimaan barang.'))}
    finally{setBusy(false)}
  },[cashierSession.id,cashierSession.storeId,companyId])
  useEffect(()=>{void load()},[load])
  useEffect(()=>{
    const handler=(event:KeyboardEvent)=>{if(event.key==='Escape'&&!busy)close()}
    window.addEventListener('keydown',handler);return()=>window.removeEventListener('keydown',handler)
  },[busy,close])

  function chooseOrder(order:GoodsReceiptOrder,draft?:GoodsReceiptDraft){
    setActiveOrder(order);setActiveDraft(draft ?? null);setLines(buildLines(order,draft))
    setDeliveryNo(draft?.supplierDeliveryNo ?? '');setNotes(draft?.notes ?? '')
    setError('');setNotice('')
  }

  function back(){setActiveOrder(null);setActiveDraft(null);setLines([]);setError('');setNotice('')}

  function update(key:string,change:Partial<FormLine>){
    setLines((all)=>all.map((line)=>line.key===key?{...line,...change}:line))
  }

  function payload(){
    const selected=lines.filter((line)=>Number(line.received)>0)
    if(selected.length===0)throw new Error('Isi jumlah diterima minimal pada satu barang.')
    return selected.map((line)=>{
      const source=sourceById.get(line.sourceLineId)
      const uom=source?.options.find((item)=>item.uomId===line.uomId)
      const received=Number(line.received)
      if(!source||!uom)throw new Error('Pilih satuan pembelian yang valid.')
      if(!uom.allowDecimal&&received!==Math.trunc(received))throw new Error(`${source.productName} harus diisi dalam bilangan bulat.`)
      if(uom.allowDecimal&&Number(received.toFixed(uom.decimalPrecision))!==received)throw new Error(`${source.productName} maksimal ${uom.decimalPrecision} angka desimal.`)
      const good=line.detailed?Number(line.good||0):received
      const damaged=line.detailed?Number(line.damaged||0):0
      const rejected=line.detailed?Number(line.rejected||0):0
      if([good,damaged,rejected].some((value)=>value<0)||Math.abs(good+damaged+rejected-received)>0.000001)throw new Error(`${source.productName}: total baik, rusak, dan ditolak harus sama dengan jumlah diterima.`)
      return {clientLineKey:line.key,supplierOrderLineId:line.sourceLineId,receivedUomId:line.uomId,receivedQty:received,acceptedGoodQty:good,damagedQty:damaged,rejectedQty:rejected}
    })
  }

  async function save(post:boolean){
    if(!activeOrder)return
    setBusy(true);setError('');setNotice('')
    try{
      const saved=await saveGoodsReceipt({
        documentId:activeDraft?.id ?? null,masterVersion:activeDraft?.masterVersion ?? null,
        cashierSessionId:cashierSession.id,supplierOrderId:activeOrder.id,
        supplierDeliveryNo:deliveryNo.trim()||null,notes:notes.trim()||null,lines:payload(),
      })
      if(post){
        const posted=await postGoodsReceipt(saved.documentId,Number(saved.masterVersion),crypto.randomUUID())
        completed(`Penerimaan ${posted.receiptNo} berhasil diposting. Stok sudah diperbarui.`)
        return
      }
      setNotice(`Draft ${saved.receiptNo} berhasil disimpan tanpa mengubah stok.`)
      setActiveDraft({id:saved.documentId,receiptNo:saved.receiptNo,supplierOrderId:activeOrder.id,supplierDeliveryNo:deliveryNo.trim()||null,notes:notes.trim()||null,masterVersion:Number(saved.masterVersion),lines:payload().map((line)=>({clientLineKey:line.clientLineKey,supplierOrderLineId:line.supplierOrderLineId,receivedUomId:line.receivedUomId,receivedQuantity:line.receivedQty,acceptedGoodQuantity:line.acceptedGoodQty,damagedQuantity:line.damagedQty,rejectedQuantity:line.rejectedQty}))})
    }catch(reason){setError(friendly(reason instanceof Error?reason.message:'Penerimaan barang gagal diproses.'))}
    finally{setBusy(false)}
  }

  async function cancelDraft(draft:GoodsReceiptDraft){
    setBusy(true);setError('');setNotice('')
    try{await cancelGoodsReceipt(draft.id,draft.masterVersion);back();await load();setNotice(`Draft ${draft.receiptNo} dibatalkan.`)}
    catch(reason){setError(friendly(reason instanceof Error?reason.message:'Draft gagal dibatalkan.'))}
    finally{setBusy(false)}
  }

  return <div className="fixed inset-0 z-[70] bg-black/65 p-2 sm:p-5" onMouseDown={(event)=>{if(event.target===event.currentTarget&&!busy)close()}}>
    <section role="dialog" aria-modal="true" className="mx-auto flex h-full max-w-6xl flex-col overflow-hidden rounded-2xl bg-white text-slate-950 shadow-2xl">
      <header className="flex items-start gap-3 border-b border-slate-200 p-4 sm:p-5">
        {activeOrder&&<button type="button" onClick={back} disabled={busy} className="rounded-xl border border-slate-300 px-3 py-2 text-sm font-bold">Kembali</button>}
        <div className="min-w-0 flex-1"><p className="text-xs font-bold uppercase tracking-wider text-emerald-700">Purchase · online</p><h2 className="mt-1 text-xl font-black">{activeOrder?'Catat Barang Diterima':'Penerimaan Barang'}</h2><p className="mt-1 text-sm text-slate-500">{activeOrder?`${activeOrder.orderNo} · ${activeOrder.supplierName} · ${activeOrder.warehouseName}`:'Pilih Supplier Order yang barangnya sudah tiba.'}</p></div>
        <button type="button" onClick={close} disabled={busy} className="pos-modal-close" aria-label="Tutup"><X className="h-5 w-5"/></button>
      </header>
      <div className="flex-1 overflow-y-auto p-4 sm:p-5">
        {error&&<div className="mb-4 rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-700">{error}</div>}
        {notice&&<div className="mb-4 flex items-center gap-2 rounded-xl border border-emerald-200 bg-emerald-50 p-3 text-sm font-semibold text-emerald-800"><CheckCircle2 className="h-4 w-4"/>{notice}</div>}
        {busy&&!activeOrder?<div className="grid min-h-48 place-items-center"><Loader2 className="h-7 w-7 animate-spin text-emerald-600"/></div>:!activeOrder?<div className="grid gap-5 lg:grid-cols-2">
          <section><div className="mb-3 flex items-center justify-between"><h3 className="font-black">Order menunggu penerimaan</h3><button type="button" onClick={()=>void load()} className="inline-flex items-center gap-2 text-sm font-bold"><RefreshCw className="h-4 w-4"/>Muat ulang</button></div>
            {orders.length===0?<p className="rounded-xl border border-dashed p-5 text-sm text-slate-500">Tidak ada Supplier Order yang masih menunggu penerimaan.</p>:<div className="space-y-3">{orders.map((order)=><article key={order.id} className="rounded-xl border border-slate-200 p-4"><div className="flex gap-3"><Package className="mt-0.5 h-5 w-5 text-emerald-700"/><div className="min-w-0 flex-1"><p className="font-black">{order.orderNo}</p><p className="mt-1 text-sm text-slate-600">{order.supplierName} · {order.warehouseName}</p><p className="mt-1 text-xs text-slate-500">{order.lines.filter((line)=>line.remainingBaseQuantity>0).length} barang tersisa · perkiraan tiba {order.expectedDate??'belum ditentukan'}</p></div><button type="button" onClick={()=>chooseOrder(order)} className="self-center rounded-xl bg-emerald-600 px-4 py-2.5 text-sm font-black text-white">Terima</button></div></article>)}</div>}
          </section>
          <section><h3 className="mb-3 font-black">Draft sesi ini</h3>{drafts.length===0?<p className="rounded-xl border border-dashed p-5 text-sm text-slate-500">Belum ada draft penerimaan.</p>:<div className="space-y-3">{drafts.map((draft)=>{const order=orders.find((item)=>item.id===draft.supplierOrderId);return <article key={draft.id} className="rounded-xl border border-amber-200 bg-amber-50 p-4"><p className="font-black">{draft.receiptNo}</p><p className="mt-1 text-sm text-slate-600">{order?.orderNo??'Order sudah tidak dapat diterima'} · {draft.lines.length} barang</p><div className="mt-3 flex gap-2"><button type="button" disabled={!order||busy} onClick={()=>order&&chooseOrder(order,draft)} className="rounded-xl bg-slate-900 px-4 py-2 text-sm font-bold text-white disabled:opacity-40">Lanjutkan</button><button type="button" disabled={busy} onClick={()=>void cancelDraft(draft)} className="rounded-xl border border-rose-300 px-4 py-2 text-sm font-bold text-rose-700">Batalkan</button></div></article>})}</div>}</section>
        </div>:<>
          <div className="grid gap-4 sm:grid-cols-2"><label className="text-sm font-bold">Nomor surat jalan (opsional)<input value={deliveryNo} onChange={(event)=>setDeliveryNo(event.target.value)} className="mt-2 w-full rounded-xl border border-slate-300 p-3 font-normal" placeholder="Nomor dari supplier"/></label><label className="text-sm font-bold">Catatan (opsional)<input value={notes} onChange={(event)=>setNotes(event.target.value)} className="mt-2 w-full rounded-xl border border-slate-300 p-3 font-normal" placeholder="Catatan penerimaan"/></label></div>
          <div className="mt-5 space-y-4">{lines.map((form)=>{const source=sourceById.get(form.sourceLineId);if(!source)return null;const uom=source.options.find((item)=>item.uomId===form.uomId);const receivedBase=Number(form.received||0)*(uom?.factorToBase??0);const over=receivedBase>source.remainingBaseQuantity+0.000001;return <article key={form.key} className="rounded-2xl border border-slate-200 bg-slate-50 p-4"><div className="flex flex-wrap items-start justify-between gap-3"><div><h3 className="font-black">{source.productName}</h3><p className="mt-1 text-xs text-slate-500">Order {numberText(source.orderedQuantity)} {source.orderedUomName} · sisa {numberText(source.remainingBaseQuantity)} satuan dasar</p></div>{over&&<span className="inline-flex items-center gap-1 rounded-full bg-amber-100 px-3 py-1 text-xs font-bold text-amber-800"><AlertTriangle className="h-3.5 w-3.5"/>Lebih dari sisa order</span>}</div><div className="mt-4 grid gap-3 sm:grid-cols-2"><label className="text-sm font-bold">Satuan diterima<select value={form.uomId} onChange={(event)=>update(form.key,{uomId:event.target.value})} className="mt-2 w-full rounded-xl border border-slate-300 bg-white p-3 font-normal">{source.options.map((option)=><option key={option.uomId} value={option.uomId}>{option.uomName} · isi {numberText(option.factorToBase)} satuan dasar</option>)}</select></label><label className="text-sm font-bold">Jumlah aktual diterima<input type="number" min="0" step={uom?.allowDecimal?`0.${'0'.repeat(Math.max(0,uom.decimalPrecision-1))}1`:'1'} value={form.received} onChange={(event)=>update(form.key,{received:event.target.value,...(!form.detailed?{good:event.target.value}:{})})} className="mt-2 w-full rounded-xl border border-slate-300 bg-white p-3 font-normal" placeholder="Kosongkan jika belum datang"/></label></div><label className="mt-4 flex items-center gap-3 text-sm font-bold"><input type="checkbox" checked={form.detailed} onChange={(event)=>update(form.key,{detailed:event.target.checked,good:event.target.checked?form.good||form.received:form.received,damaged:event.target.checked?form.damaged:'0',rejected:event.target.checked?form.rejected:'0'})} className="h-4 w-4 accent-emerald-600"/>Ada barang rusak atau ditolak</label>{form.detailed&&<div className="mt-3 grid gap-3 sm:grid-cols-3"><label className="text-xs font-bold text-slate-600">Baik<input type="number" min="0" step="any" value={form.good} onChange={(event)=>update(form.key,{good:event.target.value})} className="mt-1 w-full rounded-xl border border-slate-300 bg-white p-3 text-sm font-normal text-slate-950"/></label><label className="text-xs font-bold text-slate-600">Rusak, tetap diterima<input type="number" min="0" step="any" value={form.damaged} onChange={(event)=>update(form.key,{damaged:event.target.value})} className="mt-1 w-full rounded-xl border border-slate-300 bg-white p-3 text-sm font-normal text-slate-950"/></label><label className="text-xs font-bold text-slate-600">Ditolak<input type="number" min="0" step="any" value={form.rejected} onChange={(event)=>update(form.key,{rejected:event.target.value})} className="mt-1 w-full rounded-xl border border-slate-300 bg-white p-3 text-sm font-normal text-slate-950"/></label></div>}<p className="mt-3 text-xs leading-5 text-slate-500">Barang baik masuk {activeOrder.warehouseName}. Barang rusak masuk Gudang Rusak. Barang ditolak tidak menambah stok atau tagihan sementara.</p></article>})}</div>
        </>}
      </div>
      {activeOrder&&<footer className="flex flex-wrap justify-end gap-3 border-t border-slate-200 p-4"><button type="button" onClick={back} disabled={busy} className="rounded-xl border border-slate-300 px-4 py-3 font-bold">Batal</button><button type="button" onClick={()=>void save(false)} disabled={busy} className="inline-flex items-center gap-2 rounded-xl border border-emerald-700 px-4 py-3 font-black text-emerald-800 disabled:opacity-50">{busy?<Loader2 className="h-4 w-4 animate-spin"/>:<Save className="h-4 w-4"/>}Simpan Draft</button><button type="button" onClick={()=>void save(true)} disabled={busy} className="inline-flex items-center gap-2 rounded-xl bg-emerald-600 px-5 py-3 font-black text-white disabled:opacity-50">{busy?<Loader2 className="h-4 w-4 animate-spin"/>:<Send className="h-4 w-4"/>}Post & Tambah Stok</button></footer>}
    </section>
  </div>
}
