"use client";

import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import type { Session } from "@supabase/supabase-js";
import { AlertTriangle, ArrowLeft, CheckCircle2, ChevronDown, ChevronUp, FilePenLine, FileText, History, Loader2, Plus, RefreshCw, RotateCcw, Search, ShoppingCart, Trash2 } from "lucide-react";
import { BackofficeSalesInvoiceView } from "@/components/BackofficeSalesInvoiceView";
import { OfficeRetailHistoryDetail } from '@/components/OfficeRetailHistoryDetail';
import { filterRetailHistory, retailStatusLabel, type RetailHistory } from '@/lib/office-retail-history';
import { userFacingError } from '@/lib/user-facing-error';

type Status = "DRAFT" | "SENT" | "CONFIRMED" | "CANCELED";
type FulfillmentStatus = "QUOTATION" | "CONFIRMED" | "PREPARING" | "PARTIALLY_SHIPPED" | "IN_TRANSIT" | "COMPLETED" | "CANCELED";
type DocumentKind = "QUOTATION" | "SALES_ORDER";
type DateBasis = "ORDER_DATE" | "DELIVERY_DATE" | "DUE_DATE";
type InvoiceStatus = "NOT_READY" | "READY" | "DRAFT" | "PARTIALLY_INVOICED" | "INVOICED";
type ReturnLink = { returnId: string; returnNo: string; status: string; totalRequestedBaseQty: number; totalReceivedBaseQty: number; updatedAt: string };
type Store = { id: string; code: string; name: string };
type Warehouse = { id: string; code: string; name: string; storeId: string | null };
type Customer = { id: string; code: string; name: string; defaultPricelistId: string | null; creditTermDays: number | null; phone?: string | null; email?: string | null; address?: string | null };
type Pricelist = { id: string; name: string; scope: "GLOBAL" | "CUSTOMER"; isDefault: boolean; priority: number; appliesAllStores: boolean; validFrom: string | null; validUntil: string | null; storeIds: string[] };
type ProductUom = { productUomId: string; productId: string; sku: string; productName: string; uomId: string; uomCode: string; uomName: string; factorToBase: number; salePrice: number };
type SalesProcessMode = "RETAIL_CONFIRM_INVOICE" | "BACKOFFICE_DELIVERED_QTY_INVOICE";
type Workspace = { companyId: string; activeSalesProcessMode: SalesProcessMode | null; defaultWarehouseId: string | null; stores: Store[]; warehouses: Warehouse[]; customers: Customer[]; pricelists?: Pricelist[]; products: ProductUom[] };
type OrderLine = { id: string; lineNo: number; productId: string; uomId: string; orderedQty: number; canonicalUnitPrice: number; unitPrice: number; priceOverrideApplied: boolean; priceOverrideUnitPrice: number | null; lineSubtotal: number; lineDiscountType: string | null; lineDiscountInput: number | null; lineDiscountAmount: number; allocatedOrderDiscountAmount: number; discountAmount: number; taxCode: string | null; taxName: string | null; taxRatePercent: number | null; taxPriceMode: string | null; taxBase: number; taxAmount: number; taxRounding: number; allocatedDocumentRounding: number; lineTotal: number; productCode: string; productName: string; uomCode: string; uomName: string; pricingSnapshot?: { pricelistId?: string | null; pricelistName?: string | null; pricingSelectionSource?: string | null } };
type Order = {
  id: string; quotationNo: string; orderNo: string | null; status: Status; fulfillmentStatus: FulfillmentStatus; fulfillmentStatusUpdatedAt: string; storeId: string; warehouseId: string; customerId: string; pricelistId: string | null;
  orderDate: string; plannedDeliveryDate: string; isTempo: boolean; dueDate: string | null; customerSnapshot: { code?: string; name?: string; phone?: string | null; email?: string | null; address?: string | null };
  notes: string | null; subtotal: number; discountTotal: number; globalDiscount: number; taxTotal: number; deliveryFeeAmount: number; deliveryFeeInvoiceDisplayMode: string; grandTotalBeforeRounding: number; roundingDirection: string; roundingIncrement: number; roundingAdjustment: number; grandTotal: number; masterVersion: number;
  revisionCount: number; lastRevisedAt: string | null; lastRevisedBy: string | null; updatedAt: string; sentAt: string | null; confirmedAt: string | null; canceledAt: string | null; cancelReason: string | null; activity?: { action: string; reason: string | null; actorId: string; actorName: string | null; createdAt: string; relatedDocumentId?: string; relatedDocumentNo?: string; relatedDocumentType?: string }[]; lines: OrderLine[];
  invoiceStatus: InvoiceStatus; draftInvoiceId: string | null; activeInvoiceCount: number; postedInvoiceCount: number;
  returns?: ReturnLink[];
};
type FormLine = { key: string; productUomId: string; quantity: string; canonicalUnitPrice?: number; overrideUnitPrice: string | null; lineDiscountType: "" | "AMOUNT" | "PERCENT"; lineDiscountInput: string; taxLabel?: string; taxRatePercent?: number | null };
type FormState = { storeId: string; warehouseId: string; customerId: string; selectedPricelistId: string; orderDate: string; plannedDeliveryDate: string; isTempo: boolean; dueDate: string; notes: string; revisionReason: string; globalDiscount: string; deliveryFeeAmount: string; roundingDirection: "NONE" | "DOWN" | "UP"; lines: FormLine[] };
type PreviewLine = { productUomId: string; canonicalUnitPrice: number; taxApplied: boolean; taxName: string | null; taxRatePercent: string | number | null };
type DocumentTab = "lines" | "other" | "notes";
type OrderActivity = NonNullable<Order["activity"]>[number];
type DiscrepancyCase = { id: string; discrepancyNo: string; status: string; masterVersion: number; requiresSalesApproval: boolean; updatedAt: string };
type DiscrepancyLine = { id: string; discrepancyId: string; discrepancyType: string; requestedResolution: string; quantityUom: number; uomName: string; expectedProductCode: string; expectedProductName: string; commercialApprovalStatus: string; sourceUnitPrice: number; sourceDiscountAmount: number; sourceTaxRuleId: string | null; sourceTaxName: string | null; approvedUnitPrice: number | null; approvedDiscountAmount: number | null; approvedTaxAmount: number | null };
type SalesTaxRule = { id: string; code: string; name: string; ratePercent: number };
type DiscrepancyWorkspace = { workspaceVersion: number; cases: DiscrepancyCase[]; lines: DiscrepancyLine[]; taxRules: SalesTaxRule[] };

const statusClass: Record<Status, string> = { DRAFT: "bg-slate-100 text-slate-700", SENT: "bg-blue-100 text-blue-700", CONFIRMED: "bg-emerald-100 text-emerald-700", CANCELED: "bg-rose-100 text-rose-700" };
const fulfillmentLabel: Record<FulfillmentStatus, string> = { QUOTATION: "Quotation", CONFIRMED: "Dikonfirmasi", PREPARING: "Disiapkan", PARTIALLY_SHIPPED: "Dikirim sebagian", IN_TRANSIT: "Dalam perjalanan", COMPLETED: "Selesai", CANCELED: "Dibatalkan" };
const fulfillmentClass: Record<FulfillmentStatus, string> = { QUOTATION: "bg-slate-100 text-slate-700", CONFIRMED: "bg-emerald-100 text-emerald-700", PREPARING: "bg-amber-100 text-amber-800", PARTIALLY_SHIPPED: "bg-orange-100 text-orange-800", IN_TRANSIT: "bg-blue-100 text-blue-700", COMPLETED: "bg-teal-100 text-teal-800", CANCELED: "bg-rose-100 text-rose-700" };
const invoiceLabel: Record<InvoiceStatus, string> = { NOT_READY: "Belum siap", READY: "Siap dibuat", DRAFT: "Draft", PARTIALLY_INVOICED: "Ditagih sebagian", INVOICED: "Sudah ditagih" };
const invoiceClass: Record<InvoiceStatus, string> = { NOT_READY: "bg-slate-100 text-slate-600", READY: "bg-amber-100 text-amber-800", DRAFT: "bg-blue-100 text-blue-700", PARTIALLY_INVOICED: "bg-violet-100 text-violet-700", INVOICED: "bg-emerald-100 text-emerald-700" };
const friendly: Record<string, string> = {
  MASTER_VERSION_CONFLICT: "Data sudah berubah. Muat ulang sebelum mencoba lagi.", IDEMPOTENCY_PAYLOAD_CONFLICT: "Permintaan dengan identitas yang sama memiliki isi berbeda.",
  BACKOFFICE_SALES_ORDER_LINES_REQUIRED: "Minimal satu produk harus dipilih.", BACKOFFICE_SALES_ORDER_PRODUCT_UOM_DUPLICATE: "Produk dan UOM yang sama tidak boleh diduplikasi.",
  BACKOFFICE_SALES_ORDER_BUSINESS_DATE_OR_LINE_INVALID: "Tanggal, jatuh tempo, atau baris produk tidak valid.", BACKOFFICE_SALES_PRICELIST_MIXED: "Produk terpilih menghasilkan Pricelist berbeda. Periksa Customer dan produk.",
  BACKOFFICE_SALES_ORDER_WAREHOUSE_SCOPE_INVALID: "Warehouse harus aktif, untuk penjualan, dan sesuai Company/Store dokumen.", CUSTOM_PERMISSION_DENIED: "Anda tidak memiliki kewenangan untuk tindakan ini.",
  INVALID_PRICELIST_SELECTION: "Pilihan Pricelist tidak valid.", PRICELIST_NOT_ELIGIBLE: "Pricelist tidak berlaku untuk Customer, Store, atau tanggal order ini.",
  CANCEL_REASON_REQUIRED: "Alasan pembatalan wajib diisi.", BACKOFFICE_SALES_ORDER_REVISION_REASON_REQUIRED: "Alasan revisi Sales Order wajib diisi.",
  BACKOFFICE_SALES_ORDER_EDIT_STATE_INVALID: "Dokumen pada status ini tidak dapat diedit.", BACKOFFICE_SALES_ORDER_REVISION_REQUIRES_RETURN_OR_FULFILLMENT_SYNC: "Sales Order sudah masuk proses pemenuhan. Perubahan harus melalui sinkronisasi gudang atau Retur."
  , BACKOFFICE_PRICE_OVERRIDE_INVALID: "Harga manual harus berupa angka nol atau lebih.", LINE_DISCOUNT_INVALID: "Nilai diskon baris tidak valid.", LINE_DISCOUNT_EXCEEDS_LINE_TOTAL: "Diskon baris melebihi nilai barang.", GLOBAL_DISCOUNT_EXCEEDS_SALE_TOTAL: "Diskon order melebihi total setelah diskon baris.", BACKOFFICE_DELIVERY_FEE_INVALID: "Ongkir harus berupa angka nol atau lebih.", BACKOFFICE_DELIVERY_FEE_BELOW_INVOICE_ALLOCATION: "Ongkir SO tidak boleh lebih kecil dari ongkir yang sudah dialokasikan ke Invoice."
  , SALES_ROLE_REQUIRED: "Approval ini hanya dapat dilakukan Super Admin, Company Admin, Sales, atau Sales Admin.", BACKOFFICE_DISCREPANCY_SALES_APPROVAL_NOT_PENDING: "Approval komersial ini sudah diproses atau statusnya berubah.", OVERAGE_APPROVAL_LINE_SET_INVALID: "Daftar kelebihan barang berubah. Muat ulang Sales Order.", OVERAGE_COMMERCIAL_INPUT_INVALID: "Harga atau diskon kelebihan barang tidak valid.", OVERAGE_TAX_RULE_REQUIRED: "Pilih Tax Rule jika pajak diaktifkan."
  , SALES_PROCESS_ROOT_CREATION_MODE_BLOCKED: "Company masih memakai proses Retail. Terapkan pergantian ke proses Backoffice sebelum membuat Quotation baru.", SALES_PROCESS_SETTING_NOT_FOUND: "Pengaturan proses penjualan Company belum tersedia. Hubungi Super Admin."
};

function authHeaders(session: Session, json = false) { return { Authorization: `Bearer ${session.access_token}`, ...(json ? { "Content-Type": "application/json" } : {}) }; }
function today() { return new Date().toLocaleDateString("en-CA"); }
function money(value: number) { return new Intl.NumberFormat("id-ID", { style: "currency", currency: "IDR", maximumFractionDigits: 0 }).format(value); }
function dateText(value: string | null) { return value ? new Intl.DateTimeFormat("id-ID", { dateStyle: "medium" }).format(new Date(`${value}T12:00:00`)) : "-"; }
function dateTimeText(value: string | null) { return value ? new Intl.DateTimeFormat("id-ID", { dateStyle: "medium", timeStyle: "short" }).format(new Date(value)) : "-"; }
function errorText(code: string) { return userFacingError(code, friendly, "Operasi Sales Order belum berhasil."); }
function returnStatusLabel(status: string) {
  return ({ DRAFT: "Draft", SUBMITTED: "Menunggu persetujuan", APPROVED: "Menunggu barang", PARTIALLY_RECEIVED: "Diterima sebagian", RECEIVED: "Menunggu koreksi", CREDIT_PENDING: "Credit Note Draft", REFUND_PENDING: "Menunggu refund", COMPLETED: "Selesai", CANCELED: "Dibatalkan" } as Record<string, string>)[status] ?? status.replaceAll("_", " ");
}
function activityLabel(action: string) {
  return ({ CREATE: "Quotation dibuat", UPDATE: "Quotation diperbarui", SEND: "Quotation dikirim", CONFIRM: "Dikonfirmasi menjadi Sales Order", REVISE: "Sales Order direvisi", CANCEL: "Dokumen dibatalkan", CUTOVER_RECOVERY: "Dipindahkan dari proses Retail" } as Record<string, string>)[action] ?? action.replaceAll("_", " ");
}
async function jsonResponse(response: Response) { const body = await response.json().catch(() => ({})); if (!response.ok) throw new Error(errorText(typeof body.error === "string" ? body.error : "OPERASI_GAGAL")); return body; }
function newForm(workspace: Workspace): FormState {
  const value = today();
  const selected = workspace.warehouses.find((item) => item.id === workspace.defaultWarehouseId);
  return { storeId: selected?.storeId ?? (workspace.stores.length === 1 ? workspace.stores[0].id : ""), warehouseId: selected?.id ?? "", customerId: "", selectedPricelistId: "", orderDate: value, plannedDeliveryDate: value, isTempo: false, dueDate: "", notes: "", revisionReason: "", globalDiscount: "0", deliveryFeeAmount: "0", roundingDirection: "NONE", lines: [] };
}

export function BackofficeSalesOrderView({ session, companyId, companyName, canCreate, canEdit, canManage, notify, openProcessSettings, openSalesReturn }: { session: Session; companyId: string; companyName: string; canCreate: boolean; canEdit: boolean; canManage: boolean; notify: (message: string) => void; openProcessSettings: () => void; openSalesReturn: (salesOrderId: string, returnId?: string) => void }) {
  const consumedOrderLink = useRef("");
  const consumedRetailHistoryLink = useRef("");
  const [workspace, setWorkspace] = useState<Workspace | null>(null);
  const [orders, setOrders] = useState<Order[]>([]);
  const [history, setHistory] = useState<RetailHistory[]>([]);
  const [selectedHistory, setSelectedHistory] = useState<RetailHistory | null>(null);
  const [documentKind, setDocumentKind] = useState<DocumentKind>("QUOTATION");
  const [fulfillmentStatus, setFulfillmentStatus] = useState("");
  const [invoiceStatus, setInvoiceStatus] = useState("");
  const [dateBasis, setDateBasis] = useState<DateBasis>("ORDER_DATE");
  const [dateFrom, setDateFrom] = useState("");
  const [dateTo, setDateTo] = useState("");
  const [search, setSearch] = useState("");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [selected, setSelected] = useState<Order | null>(null);
  const [editing, setEditing] = useState<Order | null | undefined>(undefined);
  const [invoiceMode, setInvoiceMode] = useState<{ salesOrderId?: string; invoiceId?: string; list?: boolean } | null>(null);

  const load = useCallback(async () => {
    setLoading(true); setError("");
    try {
      const query = new URLSearchParams({ documentKind, dateBasis });
      if (documentKind === "SALES_ORDER" && fulfillmentStatus) query.set("fulfillmentStatus", fulfillmentStatus);
      if (documentKind === "SALES_ORDER" && invoiceStatus) query.set("invoiceStatus", invoiceStatus);
      if (dateFrom) query.set("dateFrom", dateFrom);
      if (dateTo) query.set("dateTo", dateTo);
      if (search.trim()) query.set("search", search.trim());
      const [workspaceBody, orderBody, historyBody] = await Promise.all([
        fetch("/api/sales/backoffice-orders/workspace", { headers: authHeaders(session), cache: "no-store" }).then(jsonResponse),
        fetch(`/api/sales/backoffice-orders?${query}`, { headers: authHeaders(session), cache: "no-store" }).then(jsonResponse),
        fetch('/api/sales/backoffice-orders/history', { headers: authHeaders(session), cache: 'no-store' }).then(jsonResponse)
      ]);
      setWorkspace(workspaceBody as Workspace); setOrders((orderBody.data ?? []) as Order[]);
      setHistory((historyBody.data ?? []) as RetailHistory[]);
    } catch (caught) { setError(caught instanceof Error ? caught.message : "Data gagal dimuat."); }
    finally { setLoading(false); }
  }, [dateBasis, dateFrom, dateTo, documentKind, fulfillmentStatus, invoiceStatus, search, session]);

  useEffect(() => { const timer = window.setTimeout(() => void load(), 250); return () => window.clearTimeout(timer); }, [load, companyId]);

  const readOrder = useCallback(async (orderId: string) => {
    const body = await fetch(`/api/sales/backoffice-orders/${orderId}`, {
      headers: authHeaders(session),
      cache: "no-store",
    }).then(jsonResponse);
    return body.data as Order;
  }, [session]);

  useEffect(() => {
    const query = new URLSearchParams(window.location.search);
    const orderId = query.get("orderId");
    if (!orderId || query.get("companyId") !== companyId || consumedOrderLink.current === orderId) return;
    consumedOrderLink.current = orderId;
    let active = true;
    void readOrder(orderId).then((order) => {
      if (!active) return;
      setSelected(order); setDocumentKind(order.orderNo ? "SALES_ORDER" : "QUOTATION");
      for (const key of ["view", "orderId", "companyId"]) query.delete(key);
      window.history.replaceState(window.history.state, "", `${window.location.pathname}${query.size ? `?${query}` : ""}${window.location.hash}`);
    }).catch((caught) => { if (active) setError(caught instanceof Error ? caught.message : "Dokumen gagal dimuat."); });
    return () => { active = false; consumedOrderLink.current = ""; };
  }, [companyId, readOrder]);

  useEffect(() => {
    const query = new URLSearchParams(window.location.search);
    const retailSalesId = query.get("retailSalesId");
    if (!retailSalesId || query.get("companyId") !== companyId || consumedRetailHistoryLink.current === retailSalesId) return;
    consumedRetailHistoryLink.current = retailSalesId;
    let active = true;
    void fetch(`/api/sales/backoffice-orders/history?salesId=${encodeURIComponent(retailSalesId)}`, {
      headers: authHeaders(session), cache: "no-store",
    }).then(jsonResponse).then((body) => {
      if (!active) return;
      if (body.companyId !== companyId) throw new Error("Company dokumen tidak sesuai. Muat ulang.");
      const row = (body.data as RetailHistory[])[0];
      if (!row || row.companyId !== companyId) throw new Error("Order sumber Retail tidak ditemukan atau tidak dapat diakses.");
      setSelectedHistory(row); setDocumentKind(row.kind);
      for (const key of ["view", "retailSalesId", "companyId"]) query.delete(key);
      window.history.replaceState(window.history.state, "", `${window.location.pathname}${query.size ? `?${query}` : ""}${window.location.hash}`);
    }).catch((caught) => { if (active) setError(caught instanceof Error ? caught.message : "Order sumber Retail gagal dimuat."); });
    return () => { active = false; consumedRetailHistoryLink.current = ""; };
  }, [companyId, session]);

  async function transition(order: Order, action: "SEND" | "CONFIRM" | "CANCEL") {
    const reason = action === "CANCEL" ? window.prompt("Alasan pembatalan")?.trim() : undefined;
    if (action === "CANCEL" && !reason) return;
    setError("");
    try {
      const body = await fetch(`/api/sales/backoffice-orders/${order.id}/transition`, { method: "POST", headers: authHeaders(session, true), body: JSON.stringify({ action, reason, masterVersion: order.masterVersion, operationId: crypto.randomUUID() }) }).then(jsonResponse);
      const updated = body.data as Order;
      notify(action === "SEND" ? "Quotation ditandai sudah dikirim." : action === "CONFIRM" ? "Quotation berhasil dikonfirmasi menjadi Sales Order." : "Dokumen dibatalkan.");
      await load();
      setSelected(await readOrder(updated.id));
    } catch (caught) { setError(caught instanceof Error ? caught.message : "Operasi gagal."); }
  }

  if (invoiceMode) return <BackofficeSalesInvoiceView session={session} companyId={companyId} initialSalesOrderId={!invoiceMode.list && !invoiceMode.invoiceId ? invoiceMode.salesOrderId ?? null : null} initialInvoiceId={invoiceMode.invoiceId ?? null} initialListSalesOrderId={invoiceMode.list ? invoiceMode.salesOrderId ?? null : null} canCreate={canCreate} canEdit={canEdit} canManage={canManage} companyName={companyName} notify={notify} back={() => { setInvoiceMode(null); void load(); }} />;
  if (editing !== undefined && workspace) return <OrderEditor session={session} workspace={workspace} order={editing} close={() => setEditing(undefined)} saved={async (order) => { setEditing(undefined); await load(); setSelected(await readOrder(order.id)); }} />;
  if (selected && workspace) return <OrderDetail openSource={(id) => { setSelected(null); void openHistory({ id }); }} session={session} order={selected} workspace={workspace} canCreate={canCreate} canEdit={canEdit} canManage={canManage} close={() => setSelected(null)} edit={() => { setEditing(selected); setSelected(null); }} createInvoice={() => setInvoiceMode({ salesOrderId: selected.id })} createReturn={() => openSalesReturn(selected.id)} openReturn={(returnId) => openSalesReturn(selected.id, returnId)} transition={transition} refresh={async () => setSelected(await readOrder(selected.id))} error={error} />;

  const visibleHistory = filterRetailHistory(history, { companyId, kind: documentKind,
    search, fulfillment: documentKind === 'SALES_ORDER' ? fulfillmentStatus : '',
    invoice: documentKind === 'SALES_ORDER' ? invoiceStatus : '', dateBasis, dateFrom, dateTo });
  const officeCreationActive = workspace?.activeSalesProcessMode === "BACKOFFICE_DELIVERED_QTY_INVOICE";
  async function openHistory(row: Pick<RetailHistory, "id">) {
    setError('');
    try {
      const body = await fetch(`/api/sales/backoffice-orders/history?salesId=${encodeURIComponent(row.id)}`, { headers: authHeaders(session), cache: 'no-store' }).then(jsonResponse);
      if (body.companyId !== companyId) throw new Error('Company dokumen tidak sesuai. Muat ulang.');
      setSelectedHistory((body.data as RetailHistory[])[0]);
    } catch (caught) { setError(caught instanceof Error ? caught.message : 'Histori gagal dimuat.'); }
  }
  if (selectedHistory?.companyId === companyId) return <OfficeRetailHistoryDetail key={selectedHistory.id} row={selectedHistory} session={session} companyName={companyName} notify={notify} back={() => setSelectedHistory(null)} />;
  const missingMaster = workspace && (!workspace.stores.length || !workspace.warehouses.length || !workspace.customers.length || !(workspace.pricelists?.length ?? 0) || !workspace.products.length);
  return <div className="space-y-5">
    <section className="rounded-[28px] border border-slate-200 bg-white p-6 shadow-sm">
      <div className="flex flex-wrap items-start justify-between gap-4"><div><p className="text-xs font-black uppercase tracking-[0.2em] text-emerald-700">Sales Backoffice</p><h1 className="mt-1 text-3xl font-black">Quotation & Sales Order</h1><p className="mt-1 text-slate-500">Buat Quotation lalu konfirmasi menjadi Sales Order.</p></div>{canCreate && <button disabled={Boolean(missingMaster) || !officeCreationActive} onClick={() => setEditing(null)} className="inline-flex items-center gap-2 rounded-xl bg-emerald-600 px-4 py-3 font-bold text-white disabled:cursor-not-allowed disabled:bg-slate-300"><Plus className="h-5 w-5" />Quotation Baru</button>}</div>
      {workspace && !officeCreationActive && <div className="flex flex-col gap-3 rounded-xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-950 sm:flex-row sm:items-center sm:justify-between"><div><p className="font-black">Proses penjualan {companyName} masih menggunakan Retail.</p><p className="mt-1 text-amber-800">Quotation Backoffice baru dapat dibuat setelah pergantian proses ke Office diterapkan. Dokumen dan histori yang sudah ada tetap dapat dilihat.</p></div><button type="button" onClick={openProcessSettings} className="shrink-0 rounded-lg bg-amber-900 px-4 py-2 font-bold text-white">Buka Pengaturan Sales</button></div>}
      <div className="mt-5 flex gap-2 border-b border-slate-200"><button onClick={() => { setDocumentKind("QUOTATION"); setFulfillmentStatus(""); setInvoiceStatus(""); }} className={`border-b-2 px-4 py-3 text-sm font-black ${documentKind === "QUOTATION" ? "border-emerald-600 text-emerald-700" : "border-transparent text-slate-500"}`}>Quotation</button><button onClick={() => setDocumentKind("SALES_ORDER")} className={`border-b-2 px-4 py-3 text-sm font-black ${documentKind === "SALES_ORDER" ? "border-emerald-600 text-emerald-700" : "border-transparent text-slate-500"}`}>Sales Order</button></div>
      {missingMaster && <div className="mt-4 rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">Belum dapat membuat Quotation: Store, Warehouse penjualan, Customer, dan Product-UOM aktif harus tersedia.</div>}
      {error && <div className="mt-4 rounded-xl bg-rose-50 p-3 text-sm font-semibold text-rose-700">{error}</div>}
      <div className="mt-5 grid gap-3 xl:grid-cols-[minmax(240px,1fr)_170px_180px_170px_150px_150px_auto]"><label className="relative"><Search className="absolute left-3 top-3 h-5 w-5 text-slate-400" /><input value={search} onChange={(event) => setSearch(event.target.value)} onKeyDown={(event) => { if (event.key === "Enter") void load(); }} placeholder="Cari nomor atau Customer" className="w-full rounded-xl border border-slate-200 py-2.5 pl-10 pr-3" /></label>{documentKind === "SALES_ORDER" ? <><select aria-label="Status Sales Order" value={fulfillmentStatus} onChange={(event) => setFulfillmentStatus(event.target.value)} className="rounded-xl border border-slate-200 px-3"><option value="">Semua status SO</option>{(["CONFIRMED","PREPARING","PARTIALLY_SHIPPED","IN_TRANSIT","COMPLETED","CANCELED"] as FulfillmentStatus[]).map((value) => <option key={value} value={value}>{fulfillmentLabel[value]}</option>)}</select><select aria-label="Status Invoice" value={invoiceStatus} onChange={(event) => setInvoiceStatus(event.target.value)} className="rounded-xl border border-slate-200 px-3"><option value="">Semua status Invoice</option>{(["NOT_READY","READY","DRAFT","PARTIALLY_INVOICED","INVOICED"] as InvoiceStatus[]).map((value) => <option key={value} value={value}>{invoiceLabel[value]}</option>)}</select></> : <><div className="hidden xl:block"/><div className="hidden xl:block"/></>}<select aria-label="Jenis tanggal" value={dateBasis} onChange={(event) => setDateBasis(event.target.value as DateBasis)} className="rounded-xl border border-slate-200 px-3"><option value="ORDER_DATE">Tanggal Order</option><option value="DELIVERY_DATE">Rencana Kirim</option><option value="DUE_DATE">Jatuh Tempo</option></select><input aria-label="Tanggal mulai" type="date" value={dateFrom} onChange={(event) => setDateFrom(event.target.value)} className="rounded-xl border border-slate-200 px-3" /><input aria-label="Tanggal akhir" type="date" min={dateFrom || undefined} value={dateTo} onChange={(event) => setDateTo(event.target.value)} className="rounded-xl border border-slate-200 px-3" /><button onClick={() => void load()} className="inline-flex items-center justify-center gap-2 rounded-xl border border-slate-200 px-4 py-2.5 font-bold"><RefreshCw className={`h-4 w-4 ${loading ? "animate-spin" : ""}`} />Muat ulang</button></div>
    </section>
    <section className="overflow-hidden rounded-[24px] border border-slate-200 bg-white shadow-sm"><div className="overflow-x-auto"><table className="w-full min-w-[1120px] table-fixed text-left text-sm"><thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500"><tr><th className="w-[19%] px-5 py-4">Nomor</th><th className="w-[18%] px-5 py-4">Customer</th><th className="w-[19%] px-5 py-4">Tanggal Order</th><th className="w-[15%] px-5 py-4">Status Pengiriman</th>{documentKind === "SALES_ORDER" && <th className="w-[16%] px-5 py-4">Status Invoice</th>}<th className="w-[13%] px-5 py-4 text-right">Total</th></tr></thead><tbody className="divide-y divide-slate-100">
      {!loading && !orders.length && !visibleHistory.length && <tr><td colSpan={documentKind === "SALES_ORDER" ? 6 : 5} className="px-5 py-14 text-center text-slate-500">Belum ada {documentKind === "QUOTATION" ? "Quotation" : "Sales Order"} pada filter ini.</td></tr>}
      {orders.map((order) => <tr key={order.id} onClick={() => setSelected(order)} className="cursor-pointer hover:bg-slate-50"><td className="px-5 py-4"><div className="font-black">{order.orderNo ?? order.quotationNo}</div>{order.orderNo && <div className="text-xs text-slate-500">Asal {order.quotationNo}</div>}</td><td className="px-5 py-4"><div className="font-bold">{order.customerSnapshot.name ?? "-"}</div><div className="text-xs text-slate-500">{order.customerSnapshot.code ?? "-"}</div></td><td className="px-5 py-4"><div>{dateText(order.orderDate)}</div><div className="text-xs text-slate-500">Rencana kirim {dateText(order.plannedDeliveryDate)}</div>{order.isTempo && <div className="text-xs text-slate-500">Jatuh tempo {dateText(order.dueDate)}</div>}</td><td className="px-5 py-4"><span className={`rounded-full px-2.5 py-1 text-xs font-bold ${fulfillmentClass[order.fulfillmentStatus]}`}>{order.orderNo ? fulfillmentLabel[order.fulfillmentStatus] : order.status === "CANCELED" ? "Dibatalkan" : "Draft"}</span></td>{documentKind === "SALES_ORDER" && <td className="px-5 py-4"><button type="button" disabled={order.invoiceStatus === "NOT_READY"} onClick={(event) => { event.stopPropagation(); if (order.invoiceStatus === "DRAFT" && order.draftInvoiceId) setInvoiceMode({ invoiceId: order.draftInvoiceId }); else if (order.invoiceStatus === "READY") setInvoiceMode({ salesOrderId: order.id }); else if (order.invoiceStatus === "PARTIALLY_INVOICED" || order.invoiceStatus === "INVOICED") setInvoiceMode({ salesOrderId: order.id, list: true }); }} className={`rounded-full px-2.5 py-1 text-xs font-bold ${invoiceClass[order.invoiceStatus]} disabled:cursor-default`}>{invoiceLabel[order.invoiceStatus]}</button></td>}<td className="px-5 py-4 text-right font-black">{money(Number(order.grandTotal))}</td></tr>)}
      {visibleHistory.map((row) => <tr key={`retail-${row.id}`} onClick={() => void openHistory(row)} className="cursor-pointer hover:bg-slate-50"><td className="px-5 py-4"><div className="font-black">{row.documentNo}</div><div className="text-xs text-slate-500">Dokumen asal Retail · Histori</div></td><td className="px-5 py-4"><div className="font-bold">{row.customerName ?? '-'}</div><div className="text-xs text-slate-500">{row.storeName ?? '-'}</div></td><td className="px-5 py-4">{dateText(row.orderDate)}{row.dueDate && <div className="text-xs text-slate-500">Jatuh tempo {dateText(row.dueDate)}</div>}</td><td className="px-5 py-4"><span className="rounded-full bg-slate-100 px-2.5 py-1 text-xs font-bold">{retailStatusLabel(row)}</span></td>{documentKind === 'SALES_ORDER' && <td className="px-5 py-4">{row.invoiceSnapshotId ? <button onClick={(event) => { event.stopPropagation(); void openHistory(row); }} className="text-xs font-bold text-emerald-700">Invoice asli</button> : <span className="text-xs text-slate-500">Belum ada Invoice</span>}</td>}<td className="px-5 py-4 text-right font-black">{money(row.total)}</td></tr>)}
    </tbody></table></div></section>
  </div>;
}

function DocumentHeader({ title, subtitle, status, fulfillmentStatus, back, actions }: { title: string; subtitle: string; status: Status; fulfillmentStatus: FulfillmentStatus; back: () => void; actions: ReactNode }) {
  return <><button onClick={back} className="inline-flex items-center gap-2 text-sm font-bold text-slate-600 hover:text-slate-950"><ArrowLeft className="h-4 w-4" />Quotation & Sales Order</button><div className="flex flex-wrap items-center justify-between gap-3 border border-slate-200 bg-white px-4 py-3"><div className="flex flex-wrap items-center gap-2">{actions}</div><StatusBar status={status} fulfillmentStatus={fulfillmentStatus} /></div><div className="sr-only">{subtitle}: {title}</div></>;
}
function StatusBar({ status, fulfillmentStatus }: { status: Status; fulfillmentStatus: FulfillmentStatus }) {
  const label = status === "CANCELED" ? "Dibatalkan" : status === "CONFIRMED" ? fulfillmentLabel[fulfillmentStatus] : "Draft Quotation";
  const color = status === "CONFIRMED" ? fulfillmentClass[fulfillmentStatus] : statusClass[status];
  return <span className={`rounded-full px-3 py-1.5 text-xs font-black ${color}`}>{label}</span>;
}
function Tabs({ active, setActive }: { active: DocumentTab; setActive: (tab: DocumentTab) => void }) {
  return <div className="flex gap-5 border-b border-slate-200 px-5">{([["lines", "Order Lines"], ["other", "Informasi Lainnya"], ["notes", "Catatan"]] as [DocumentTab, string][]).map(([value, label]) => <button key={value} onClick={() => setActive(value)} className={`border-b-2 px-1 py-4 text-sm font-bold ${active === value ? "border-emerald-600 text-emerald-700" : "border-transparent text-slate-500"}`}>{label}</button>)}</div>;
}
function Field({ label, children }: { label: string; children: ReactNode }) { return <label className="space-y-1.5 text-sm font-bold text-slate-700"><span>{label}</span>{children}</label>; }
const control = "w-full rounded-lg border border-slate-200 bg-white px-3 py-2.5 font-normal text-slate-900";

function OrderEditor({ session, workspace, order, close, saved }: { session: Session; workspace: Workspace; order: Order | null; close: () => void; saved: (order: Order) => Promise<void> }) {
  const [form, setForm] = useState<FormState>(() => order ? { storeId: order.storeId, warehouseId: order.warehouseId, customerId: order.customerId, selectedPricelistId: order.lines[0]?.pricingSnapshot?.pricingSelectionSource === "BACKOFFICE_EXPLICIT" ? order.pricelistId ?? "" : "", orderDate: order.orderDate, plannedDeliveryDate: order.plannedDeliveryDate, isTempo: order.isTempo, dueDate: order.dueDate ?? "", notes: order.notes ?? "", revisionReason: "", globalDiscount: String(order.globalDiscount ?? 0), deliveryFeeAmount: String(order.deliveryFeeAmount ?? 0), roundingDirection: (order.roundingDirection ?? "NONE") as FormState["roundingDirection"], lines: order.lines.map((line) => ({ key: crypto.randomUUID(), productUomId: workspace.products.find((item) => item.productId === line.productId && item.uomId === line.uomId)?.productUomId ?? "", quantity: String(line.orderedQty), canonicalUnitPrice: Number(line.canonicalUnitPrice ?? line.unitPrice), overrideUnitPrice: line.priceOverrideApplied ? String(line.priceOverrideUnitPrice ?? line.unitPrice) : null, lineDiscountType: (line.lineDiscountType ?? "") as FormLine["lineDiscountType"], lineDiscountInput: String(line.lineDiscountInput ?? 0), taxLabel: line.taxName ? `${line.taxName} ${Number(line.taxRatePercent)}%` : "Tanpa pajak", taxRatePercent: line.taxRatePercent })) } : newForm(workspace));
  const [activeTab, setActiveTab] = useState<DocumentTab>("lines"); const [busy, setBusy] = useState(false); const [previewing, setPreviewing] = useState(false); const [error, setError] = useState("");
  const availableWarehouses = useMemo(() => workspace.warehouses.filter((item) => !item.storeId || item.storeId === form.storeId), [workspace.warehouses, form.storeId]);
  const customer = workspace.customers.find((item) => item.id === form.customerId);
  const eligiblePricelists = useMemo(() => {
    const resolvedAt = new Date(`${form.orderDate}T12:00:00`).getTime();
    return (workspace.pricelists ?? []).filter((item) => {
      const customerEligible = item.scope === "GLOBAL" || item.id === customer?.defaultPricelistId;
      const storeEligible = item.appliesAllStores || item.storeIds.includes(form.storeId);
      const dateEligible = (!item.validFrom || new Date(item.validFrom).getTime() <= resolvedAt) && (!item.validUntil || new Date(item.validUntil).getTime() >= resolvedAt);
      return customerEligible && storeEligible && dateEligible;
    });
  }, [customer?.defaultPricelistId, form.orderDate, form.storeId, workspace.pricelists]);
  function update<K extends keyof FormState>(key: K, value: FormState[K]) { setForm((current) => ({ ...current, [key]: value })); }
  function changeStore(storeId: string) { setForm((current) => { const currentWarehouse = workspace.warehouses.find((item) => item.id === current.warehouseId); const defaultWarehouse = workspace.warehouses.find((item) => item.id === workspace.defaultWarehouseId); const currentFits = currentWarehouse && (!currentWarehouse.storeId || currentWarehouse.storeId === storeId); const defaultFits = defaultWarehouse && (!defaultWarehouse.storeId || defaultWarehouse.storeId === storeId); return { ...current, storeId, selectedPricelistId: "", warehouseId: currentFits ? current.warehouseId : defaultFits ? defaultWarehouse.id : "" }; }); }
  function addLine() { update("lines", [...form.lines, { key: crypto.randomUUID(), productUomId: "", quantity: "1", overrideUnitPrice: null, lineDiscountType: "", lineDiscountInput: "0" }]); }
  const previewKey = JSON.stringify({ storeId: form.storeId, customerId: form.customerId, selectedPricelistId: form.selectedPricelistId, orderDate: form.orderDate, lines: form.lines.map((line) => [line.productUomId, line.quantity]) });
  useEffect(() => {
    if (!form.storeId || !form.warehouseId || !form.customerId || !form.orderDate || !form.lines.length || form.lines.some((line) => !line.productUomId || Number(line.quantity) <= 0)) return;
    let cancelled = false;
    const timer = window.setTimeout(async () => {
      setPreviewing(true);
      try {
        const body = await fetch("/api/sales/backoffice-orders/preview", { method: "POST", headers: authHeaders(session, true), body: JSON.stringify({ ...form, plannedDeliveryDate: form.plannedDeliveryDate || form.orderDate, dueDate: form.isTempo ? form.dueDate : null, lines: form.lines.map((line) => ({ productUomId: line.productUomId, quantity: Number(line.quantity) })) }) }).then(jsonResponse);
        if (cancelled) return;
        const previews = new Map(((body.lines ?? []) as PreviewLine[]).map((line) => [line.productUomId, line]));
        setForm((current) => ({ ...current, lines: current.lines.map((line) => { const preview = previews.get(line.productUomId); return preview ? { ...line, canonicalUnitPrice: Number(preview.canonicalUnitPrice), taxLabel: preview.taxApplied ? `${preview.taxName} ${Number(preview.taxRatePercent)}%` : "Tanpa pajak", taxRatePercent: preview.taxApplied ? Number(preview.taxRatePercent) : null } : line; }) }));
      } catch (caught) { if (!cancelled) setError(caught instanceof Error ? caught.message : "Preview harga gagal dimuat."); }
      finally { if (!cancelled) setPreviewing(false); }
    }, 300);
    return () => { cancelled = true; window.clearTimeout(timer); };
  // previewKey intentionally excludes preview result fields to avoid a request loop.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [previewKey, session]);
  const lineAmount = (line: FormLine) => { const product = workspace.products.find((item) => item.productUomId === line.productUomId); const qty = Number(line.quantity || 0); const unit = Number(line.overrideUnitPrice ?? line.canonicalUnitPrice ?? product?.salePrice ?? 0); const gross = qty * unit; const input = Number(line.lineDiscountInput || 0); const discount = line.lineDiscountType === "PERCENT" ? gross * input / 100 : line.lineDiscountType === "AMOUNT" ? input : 0; return Math.max(0, gross - discount); };
  const beforeGlobal = form.lines.reduce((total, line) => total + lineAmount(line), 0); const estimatedBeforeRounding = Math.max(0, beforeGlobal - Number(form.globalDiscount || 0)); const estimatedProductTotal = form.roundingDirection === "DOWN" ? Math.floor(estimatedBeforeRounding / 100) * 100 : form.roundingDirection === "UP" ? Math.ceil(estimatedBeforeRounding / 100) * 100 : estimatedBeforeRounding; const estimatedTotal = estimatedProductTotal + Number(form.deliveryFeeAmount || 0);
  async function save() { setBusy(true); setError(""); try { const response = await fetch(order ? `/api/sales/backoffice-orders/${order.id}` : "/api/sales/backoffice-orders", { method: order ? "PUT" : "POST", headers: authHeaders(session, true), body: JSON.stringify({ ...form, globalDiscount: Number(form.globalDiscount || 0), dueDate: form.isTempo ? form.dueDate : null, masterVersion: order?.masterVersion, operationId: crypto.randomUUID(), lines: form.lines.map((line) => ({ productUomId: line.productUomId, quantity: Number(line.quantity), ...(line.overrideUnitPrice !== null ? { overrideUnitPrice: Number(line.overrideUnitPrice) } : {}), lineDiscountType: line.lineDiscountType || null, lineDiscountInput: line.lineDiscountType ? Number(line.lineDiscountInput || 0) : null })) }) }).then(jsonResponse); await saved(response.data as Order); } catch (caught) { setError(caught instanceof Error ? caught.message : "Draft gagal disimpan."); } finally { setBusy(false); } }
  const revisingSalesOrder = order?.status === "CONFIRMED";
  const invalid = !form.storeId || !form.warehouseId || !form.customerId || !form.lines.length || form.lines.some((line) => !line.productUomId || Number(line.quantity) <= 0 || (line.overrideUnitPrice !== null && Number(line.overrideUnitPrice) < 0) || Number(line.lineDiscountInput || 0) < 0 || (line.lineDiscountType === "PERCENT" && Number(line.lineDiscountInput || 0) > 100) || lineAmount(line) < 0) || Number(form.globalDiscount || 0) < 0 || Number(form.globalDiscount || 0) > beforeGlobal || Number(form.deliveryFeeAmount || 0) < 0 || (form.isTempo && !form.dueDate) || (revisingSalesOrder && !form.revisionReason.trim());
  return <div className="space-y-3"><DocumentHeader title={order?.orderNo ?? order?.quotationNo ?? "Quotation Baru"} subtitle={revisingSalesOrder ? "Revisi Sales Order" : "Quotation"} status={order?.status ?? "DRAFT"} fulfillmentStatus={order?.fulfillmentStatus ?? "QUOTATION"} back={close} actions={<><button disabled={busy || invalid} onClick={() => void save()} className="inline-flex items-center gap-2 rounded-md bg-emerald-600 px-4 py-2 font-bold text-white disabled:bg-slate-300">{busy && <Loader2 className="h-4 w-4 animate-spin" />}{revisingSalesOrder ? "Simpan Revisi" : "Simpan"}</button><button onClick={close} className="rounded-md border border-slate-300 px-4 py-2 font-bold">Buang</button></>} />
    {error && <div className="rounded-xl bg-rose-50 p-3 text-sm font-semibold text-rose-700">{error}</div>}
    <section className="overflow-hidden border border-slate-200 bg-white shadow-sm">
      <div className="p-6">
        <p className="text-sm font-semibold text-slate-500">{revisingSalesOrder ? "Revisi Sales Order" : "Quotation"}</p>
        <h1 className="mt-1 text-3xl font-black text-slate-950">{order?.orderNo ?? order?.quotationNo ?? "Baru"}</h1>
        {revisingSalesOrder && <div className="mt-5 rounded-xl border border-amber-200 bg-amber-50 p-4"><Field label="Alasan revisi"><textarea required maxLength={1000} value={form.revisionReason} onChange={(event) => update("revisionReason", event.target.value)} className={`${control} min-h-20`} placeholder="Jelaskan perubahan pada Sales Order" /></Field><p className="mt-2 text-xs text-amber-800">Nomor SO tetap sama dan perubahan disimpan pada riwayat audit.</p></div>}
        <div className="mt-7 grid gap-6 lg:grid-cols-[minmax(0,1.15fr)_minmax(420px,0.85fr)]">
          <div className="rounded-xl border border-slate-200 p-4">
            <Field label="Customer"><select className={control} value={form.customerId} onChange={(event) => { const next = workspace.customers.find((item) => item.id === event.target.value); setForm((current) => ({ ...current, customerId: event.target.value, selectedPricelistId: "", isTempo: Boolean(next?.creditTermDays), dueDate: next?.creditTermDays ? current.dueDate : "" })); }}><option value="">Pilih Customer</option>{workspace.customers.map((item) => <option key={item.id} value={item.id}>{item.code} · {item.name}</option>)}</select></Field>
            {customer && <div className="mt-3 rounded-lg bg-slate-50 p-3 text-sm leading-6 text-slate-600"><strong className="block text-slate-900">{customer.name}</strong><span className="block">{customer.code}</span>{customer.address ? <span className="block">{customer.address}</span> : <span className="block text-slate-400">Alamat belum tersedia</span>}{customer.phone && <span className="block">{customer.phone}</span>}</div>}
          </div>
          <div className="space-y-4 rounded-xl border border-slate-200 p-4">
            <div className="grid gap-4 sm:grid-cols-2"><Field label="Tanggal Order"><input type="date" className={control} value={form.orderDate} onChange={(event) => setForm((current) => ({ ...current, orderDate: event.target.value, selectedPricelistId: "" }))} /></Field><Field label="Rencana Pengiriman"><input type="date" className={control} min={form.orderDate} value={form.plannedDeliveryDate} onChange={(event) => update("plannedDeliveryDate", event.target.value)} /></Field></div>
            <Field label="Pricelist"><select className={control} value={form.selectedPricelistId} onChange={(event) => update("selectedPricelistId", event.target.value)}><option value="">Otomatis · Customer / Global default</option>{eligiblePricelists.map((item) => <option key={item.id} value={item.id}>{item.name}{item.id === customer?.defaultPricelistId ? " · Customer" : item.isDefault ? " · Default" : ""}</option>)}</select><span className="mt-1 block text-xs font-normal text-slate-500">Harga dihitung dan dikunci oleh resolver Pricelist server.</span></Field>
            <div className="rounded-lg bg-slate-50 p-3"><label className="flex items-center gap-3 text-sm font-bold"><input type="checkbox" checked={form.isTempo} onChange={(event) => update("isTempo", event.target.checked)} />Pembayaran TEMPO{customer?.creditTermDays ? <span className="ml-auto text-xs text-slate-500">Default {customer.creditTermDays} hari</span> : null}</label>{form.isTempo && <div className="mt-3"><Field label="Tanggal jatuh tempo"><input type="date" className={control} min={form.orderDate} value={form.dueDate} onChange={(event) => update("dueDate", event.target.value)} /></Field></div>}</div>
          </div>
        </div>
      </div>
      <Tabs active={activeTab} setActive={setActiveTab} />
      {activeTab === "lines" && <div>
        {/* eslint-disable-next-line @typescript-eslint/no-unused-vars */}
        <div className="overflow-x-auto"><table className="min-w-[1440px] text-sm"><thead className="bg-slate-50 text-left text-xs uppercase text-slate-500"><tr><th className="w-56 px-4 py-3">Produk</th><th className="px-4 py-3">Deskripsi</th><th className="w-28 px-4 py-3 text-right">Qty</th><th className="w-24 px-4 py-3">UOM</th><th className="w-48 px-4 py-3 text-right">Harga Satuan</th><th className="w-56 px-4 py-3">Diskon</th><th className="w-44 px-4 py-3">Pajak</th><th className="w-40 px-4 py-3 text-right">Jumlah</th><th className="w-14"></th></tr></thead><tbody className="divide-y divide-slate-100">{form.lines.map((line, index) => { const product = workspace.products.find((item) => item.productUomId === line.productUomId); const unitPrice = Number(line.overrideUnitPrice ?? line.canonicalUnitPrice ?? product?.salePrice ?? 0); const amount = lineAmount(line); return <tr key={line.key} className="align-top"><td className="px-4 py-3"><select className={control} value={line.productUomId} onChange={(event) => update("lines", form.lines.map((item) => item.key === line.key ? { ...item, productUomId: event.target.value, canonicalUnitPrice: undefined, overrideUnitPrice: null, taxLabel: undefined, taxRatePercent: undefined } : item))}><option value="">Pilih Product</option>{workspace.products.map((item) => <option key={item.productUomId} value={item.productUomId}>{item.sku} · {item.productName}</option>)}</select></td><td className="px-4 py-3"><span className="font-semibold text-slate-800">{product?.productName ?? "Pilih produk terlebih dahulu"}</span><span className="mt-1 block text-xs text-slate-400">{product?.sku ?? "-"}</span></td><td className="px-4 py-3"><input aria-label={`Quantity baris ${index + 1}`} type="number" min="0.0001" step="any" className={`${control} text-right`} value={line.quantity} onChange={(event) => update("lines", form.lines.map((item) => item.key === line.key ? { ...item, quantity: event.target.value } : item))} /></td><td className="px-4 py-3 font-bold">{product?.uomCode ?? "-"}</td><td className="px-4 py-3"><input aria-label={`Harga satuan baris ${index + 1}`} type="number" min="0" step="any" className={`${control} text-right font-bold`} value={line.overrideUnitPrice ?? line.canonicalUnitPrice ?? product?.salePrice ?? ""} onChange={(event) => update("lines", form.lines.map((item) => item.key === line.key ? { ...item, overrideUnitPrice: event.target.value } : item))} />{line.overrideUnitPrice !== null ? <button type="button" onClick={() => update("lines", form.lines.map((item) => item.key === line.key ? { ...item, overrideUnitPrice: null } : item))} className="mt-1 text-xs font-bold text-emerald-700">Kembalikan ke Pricelist</button> : <span className="mt-1 block text-xs text-slate-400">Pricelist canonical</span>}</td><td className="px-4 py-3"><div className="grid grid-cols-[110px_1fr] gap-2"><select aria-label={`Jenis diskon baris ${index + 1}`} className={control} value={line.lineDiscountType} onChange={(event) => update("lines", form.lines.map((item) => item.key === line.key ? { ...item, lineDiscountType: event.target.value as FormLine["lineDiscountType"], lineDiscountInput: event.target.value ? item.lineDiscountInput : "0" } : item))}><option value="">Tanpa</option><option value="AMOUNT">Nominal</option><option value="PERCENT">Persen</option></select><input aria-label={`Nilai diskon baris ${index + 1}`} type="number" min="0" max={line.lineDiscountType === "PERCENT" ? 100 : undefined} step="any" disabled={!line.lineDiscountType} className={`${control} text-right disabled:bg-slate-100`} value={line.lineDiscountInput} onChange={(event) => update("lines", form.lines.map((item) => item.key === line.key ? { ...item, lineDiscountInput: event.target.value } : item))} /></div></td><td className="px-4 py-3"><span className="font-semibold">{line.taxLabel ?? (product ? previewing ? "Menghitung…" : "Belum dipreview" : "-")}</span><span className="block text-xs text-slate-400">Harga termasuk pajak</span></td><td className="px-4 py-3 text-right font-black">{product ? money(amount) : "-"}</td><td className="px-2 py-3"><button aria-label={`Hapus baris ${index + 1}`} onClick={() => update("lines", form.lines.filter((item) => item.key !== line.key))} className="rounded-lg p-2 text-rose-600"><Trash2 className="h-4 w-4" /></button></td></tr>; })}</tbody></table></div>
        <div className="flex flex-col gap-4 border-t border-slate-100 p-4 sm:flex-row sm:items-start sm:justify-between"><button onClick={addLine} className="inline-flex items-center gap-2 text-sm font-bold text-emerald-700"><Plus className="h-4 w-4" />Tambah produk</button><div className="w-full max-w-md space-y-3 rounded-xl bg-slate-50 p-4 text-sm"><label className="grid grid-cols-[1fr_160px] items-center gap-3 text-slate-600"><span>Diskon order</span><input type="number" min="0" step="any" value={form.globalDiscount} onChange={(event) => update("globalDiscount", event.target.value)} className={`${control} text-right`} /></label><label className="grid grid-cols-[1fr_160px] items-center gap-3 text-slate-600"><span>Ongkir</span><input aria-label="Ongkir" type="number" min="0" step="any" value={form.deliveryFeeAmount} onChange={(event) => update("deliveryFeeAmount", event.target.value)} className={`${control} text-right`} /></label><label className="grid grid-cols-[1fr_160px] items-center gap-3 text-slate-600"><span>Pembulatan Rp100</span><select value={form.roundingDirection} onChange={(event) => update("roundingDirection", event.target.value as FormState["roundingDirection"])} className={control}><option value="NONE">Tanpa</option><option value="DOWN">Turun</option><option value="UP">Naik</option></select></label><div className="flex justify-between text-slate-500"><span>Setelah diskon baris</span><strong className="text-slate-800">{money(beforeGlobal)}</strong></div><div className="flex justify-between text-slate-500"><span>Pajak penjualan</span><strong className="text-slate-800">Termasuk harga</strong></div><div className="flex justify-between text-slate-500"><span>Ongkir</span><strong className="text-slate-800">{money(Number(form.deliveryFeeAmount || 0))}</strong></div><div className="flex justify-between border-t border-slate-200 pt-2 text-base"><span className="font-black">Total estimasi</span><strong className="text-lg">{money(estimatedTotal)}</strong></div><p className="text-xs text-slate-400">Server menghitung ulang harga, diskon, pajak, ongkir, dan pembulatan saat Draft disimpan.</p></div></div>
      </div>}
      {activeTab === "other" && <div className="grid gap-4 p-5 md:grid-cols-2"><Field label="Store"><select className={control} value={form.storeId} onChange={(event) => changeStore(event.target.value)}><option value="">Pilih Store</option>{workspace.stores.map((item) => <option key={item.id} value={item.id}>{item.code} · {item.name}</option>)}</select></Field><Field label="Warehouse"><select className={control} value={form.warehouseId} onChange={(event) => update("warehouseId", event.target.value)}><option value="">Pilih Warehouse</option>{availableWarehouses.map((item) => <option key={item.id} value={item.id}>{item.code} · {item.name}{item.id === workspace.defaultWarehouseId ? " (Default)" : ""}</option>)}</select><span className="block text-xs font-normal text-slate-500">Terisi dari default Company. Dapat diganti sebelum Quotation dikonfirmasi.</span></Field></div>}
      {activeTab === "notes" && <div className="p-5"><Field label="Syarat dan catatan"><textarea className={`${control} min-h-32`} value={form.notes} onChange={(event) => update("notes", event.target.value)} maxLength={1000} placeholder="Catatan yang perlu diketahui Customer atau tim internal" /></Field></div>}
    </section>
  </div>;
}

function OrderDetail({ openSource, session, order, workspace, canCreate, canEdit, canManage, close, edit, createInvoice, createReturn, openReturn, transition, refresh, error }: { openSource: (id: string) => void; session: Session; order: Order; workspace: Workspace; canCreate: boolean; canEdit: boolean; canManage: boolean; close: () => void; edit: () => void; createInvoice: () => void; createReturn: () => void; openReturn: (returnId: string) => void; transition: (order: Order, action: "SEND" | "CONFIRM" | "CANCEL") => Promise<void>; refresh: () => Promise<void>; error: string }) {
  const [activeTab, setActiveTab] = useState<DocumentTab>("lines");
  const [showActivity, setShowActivity] = useState(true);
  const warehouse = workspace.warehouses.find((item) => item.id === order.warehouseId); const store = workspace.stores.find((item) => item.id === order.storeId);
  const pricelistName = order.lines[0]?.pricingSnapshot?.pricelistName ?? workspace.pricelists?.find((item) => item.id === order.pricelistId)?.name ?? "Harga dasar Product";
  const pricelistSource = order.lines[0]?.pricingSnapshot?.pricingSelectionSource === "BACKOFFICE_EXPLICIT" ? "Dipilih pada dokumen" : "Otomatis dari Customer / Global";
  const latestReturn = order.returns?.[0];
  const actions = <>{order.status === "CONFIRMED" && order.fulfillmentStatus === "COMPLETED" && canCreate && <><button onClick={createInvoice} className="inline-flex items-center gap-2 rounded-xl bg-emerald-600 px-4 py-2 font-bold text-white"><FileText className="h-4 w-4" />Buat Invoice</button>{latestReturn ? <button onClick={() => openReturn(latestReturn.returnId)} className="inline-flex items-center gap-2 rounded-xl border border-emerald-200 px-4 py-2 font-bold text-emerald-800"><RotateCcw className="h-4 w-4" />{latestReturn.returnNo} · {returnStatusLabel(latestReturn.status)}</button> : <button onClick={createReturn} className="inline-flex items-center gap-2 rounded-xl border border-emerald-200 px-4 py-2 font-bold text-emerald-800"><RotateCcw className="h-4 w-4" />Buat Retur</button>}</>}{((order.status === "DRAFT" || order.status === "SENT") || (order.status === "CONFIRMED" && (order.fulfillmentStatus === "CONFIRMED" || order.fulfillmentStatus === "PREPARING") && order.activeInvoiceCount === 0)) && canEdit && <button onClick={edit} className="inline-flex items-center gap-2 rounded-xl border border-slate-200 px-4 py-2 font-bold"><FilePenLine className="h-4 w-4" />{order.status === "CONFIRMED" ? "Revisi SO" : "Edit"}</button>}{(order.status === "DRAFT" || order.status === "SENT") && canManage && <button onClick={() => void transition(order, "CONFIRM")} className="inline-flex items-center gap-2 rounded-xl bg-emerald-600 px-4 py-2 font-bold text-white"><ShoppingCart className="h-4 w-4" />Konfirmasi menjadi SO</button>}{((order.status === "DRAFT" || order.status === "SENT") || (order.status === "CONFIRMED" && (order.fulfillmentStatus === "CONFIRMED" || order.fulfillmentStatus === "PREPARING") && order.activeInvoiceCount === 0)) && canManage && <button onClick={() => void transition(order, "CANCEL")} className="rounded-xl border border-rose-200 px-4 py-2 font-bold text-rose-700">{order.status === "CONFIRMED" ? "Batalkan SO" : "Batalkan"}</button>}</>;
  return <div className="space-y-3"><DocumentHeader title={order.orderNo ?? order.quotationNo} subtitle={order.orderNo ? `Sales Order · asal ${order.quotationNo}` : "Quotation"} status={order.status} fulfillmentStatus={order.fulfillmentStatus} back={close} actions={actions} />
    {error && <div className="rounded-xl bg-rose-50 p-3 text-sm font-semibold text-rose-700">{error}</div>}{order.cancelReason && <div className="rounded-xl bg-rose-50 p-3 text-sm text-rose-700">Alasan pembatalan: {order.cancelReason}</div>}
    <section className="overflow-hidden border border-slate-200 bg-white shadow-sm">
      <div className="p-6">
        <p className="text-sm font-semibold text-slate-500">{order.orderNo ? "Sales Order" : "Quotation"}</p>
        <h1 className="mt-1 text-3xl font-black text-slate-950">{order.orderNo ?? order.quotationNo}</h1>
        {order.orderNo && <p className="mt-1 text-xs text-slate-500">Berasal dari {order.quotationNo}</p>}
        <div className="mt-7 grid gap-6 lg:grid-cols-[minmax(0,1.15fr)_minmax(420px,0.85fr)]">
          <div className="rounded-xl border border-slate-200 p-4">
            <span className="text-sm font-bold text-slate-700">Customer</span>
            <h2 className="mt-2 text-xl font-black">{order.customerSnapshot.name ?? "-"}</h2>
            <p className="text-sm text-slate-500">{order.customerSnapshot.code ?? "-"}</p>
            {order.customerSnapshot.address ? <p className="mt-2 max-w-xl text-sm leading-6 text-slate-500">{order.customerSnapshot.address}</p> : <p className="mt-2 text-sm text-slate-400">Alamat belum tersedia</p>}
            {order.customerSnapshot.phone && <p className="text-sm text-slate-500">{order.customerSnapshot.phone}</p>}
          </div>
          <div className="space-y-4 rounded-xl border border-slate-200 p-4 text-sm">
            <div className="grid grid-cols-2 gap-4"><Info label="Tanggal Order" value={dateText(order.orderDate)} /><Info label="Rencana Pengiriman" value={dateText(order.plannedDeliveryDate)} /></div>
            <Info label="Pricelist" value={pricelistName} />
            <p className="-mt-3 text-xs text-slate-400">{pricelistSource}</p>
            <div className="rounded-lg bg-slate-50 p-3"><span className="text-slate-500">Syarat pembayaran</span><strong className="block">{order.isTempo ? "TEMPO" : "Non-TEMPO"}</strong>{order.isTempo && <span className="text-xs text-slate-500">Jatuh tempo {dateText(order.dueDate)}</span>}</div>
          </div>
        </div>
      </div>
      {order.orderNo && <SalesDiscrepancyApprovalPanel session={session} orderId={order.id} canApprove={canManage} refreshed={refresh} />}
      <Tabs active={activeTab} setActive={setActiveTab} />
      {activeTab === "lines" && <div><div className="overflow-x-auto"><table className="w-full min-w-[1240px] table-fixed text-sm"><thead className="bg-slate-50 text-left text-xs uppercase text-slate-500"><tr><th className="w-40 px-4 py-3">Produk</th><th className="px-4 py-3">Deskripsi</th><th className="w-20 px-4 py-3 text-right">Qty</th><th className="w-28 px-4 py-3">UOM</th><th className="w-44 px-4 py-3 text-right">Harga Satuan</th><th className="w-40 px-4 py-3 text-right">Diskon</th><th className="w-44 px-4 py-3">Pajak</th><th className="w-44 px-4 py-3 text-right">Jumlah</th></tr></thead><tbody className="divide-y divide-slate-100">{order.lines.map((line) => <tr key={line.id} className="align-top"><td className="px-4 py-3 font-bold">{line.productCode}</td><td className="break-words px-4 py-3">{line.productName}</td><td className="px-4 py-3 text-right">{line.orderedQty}</td><td className="px-4 py-3">{line.uomCode}</td><td className="px-4 py-3 text-right"><strong>{money(Number(line.unitPrice))}</strong>{line.priceOverrideApplied && <span className="block text-xs text-amber-700">Manual · Pricelist {money(Number(line.canonicalUnitPrice))}</span>}</td><td className="px-4 py-3 text-right"><strong>{money(Number(line.discountAmount))}</strong>{line.lineDiscountType && <span className="block text-xs text-slate-400">{line.lineDiscountType === "PERCENT" ? `${Number(line.lineDiscountInput)}%` : "Nominal"}</span>}</td><td className="px-4 py-3"><strong>{line.taxName ? `${line.taxName} ${Number(line.taxRatePercent)}%` : "Tanpa pajak"}</strong>{line.taxName && <span className="block text-xs text-slate-400">Termasuk {money(Number(line.taxAmount))}</span>}</td><td className="px-4 py-3 text-right font-bold">{money(Number(line.lineTotal))}</td></tr>)}</tbody></table></div><div className="flex justify-end border-t border-slate-100 px-5 py-4"><div className="w-full max-w-md space-y-2 rounded-xl bg-slate-50 p-4 text-sm"><div className="grid grid-cols-[1fr_auto] gap-x-8"><span className="text-slate-500">Subtotal</span><strong className="min-w-36 text-right">{money(Number(order.subtotal))}</strong></div><div className="grid grid-cols-[1fr_auto] gap-x-8"><span className="text-slate-500">Total diskon</span><strong className="min-w-36 text-right">-{money(Number(order.discountTotal))}</strong></div><div className="grid grid-cols-[1fr_auto] gap-x-8"><span className="text-slate-500">Dasar Pengenaan Pajak</span><strong className="min-w-36 text-right">{money(Number(order.grandTotalBeforeRounding) - Number(order.taxTotal))}</strong></div><div className="grid grid-cols-[1fr_auto] gap-x-8"><span className="text-slate-500">Pajak termasuk</span><strong className="min-w-36 text-right">{money(Number(order.taxTotal))}</strong></div>{Number(order.roundingAdjustment) !== 0 && <div className="grid grid-cols-[1fr_auto] gap-x-8"><span className="text-slate-500">Pembulatan</span><strong className="min-w-36 text-right">{money(Number(order.roundingAdjustment))}</strong></div>}<div className="grid grid-cols-[1fr_auto] gap-x-8"><span className="text-slate-500">Ongkir</span><strong className="min-w-36 text-right">{money(Number(order.deliveryFeeAmount ?? 0))}</strong></div><div className="grid grid-cols-[1fr_auto] items-end gap-x-8 border-t border-slate-200 pt-3 text-base"><span className="font-black">Total</span><strong className="min-w-36 text-right text-xl">{money(Number(order.grandTotal))}</strong></div></div></div></div>}
      {activeTab === "other" && <div className="space-y-5 p-5 text-sm"><div className="grid gap-4 md:grid-cols-3"><Info label="Store" value={store ? `${store.code} · ${store.name}` : "-"} /><Info label="Warehouse" value={warehouse ? `${warehouse.code} · ${warehouse.name}` : "-"} /><Info label="Status SO" value={order.orderNo ? fulfillmentLabel[order.fulfillmentStatus] : order.status === "CANCELED" ? "Dibatalkan" : "Draft Quotation"} /><Info label="Versi Dokumen" value={String(order.masterVersion)} /><Info label="Jumlah Revisi" value={String(order.revisionCount ?? 0)} /><Info label="Revisi Terakhir" value={dateTimeText(order.lastRevisedAt)} /><Info label="Terakhir Diperbarui" value={dateTimeText(order.updatedAt)} /><Info label="SO Dikonfirmasi" value={dateTimeText(order.confirmedAt)} /></div></div>}
      {activeTab === "notes" && <div className="min-h-28 whitespace-pre-wrap p-5 text-sm text-slate-700">{order.notes || "Tidak ada catatan."}</div>}
    </section>
    <ActivityLog openSource={openSource} activity={order.activity ?? []} open={showActivity} toggle={() => setShowActivity((value) => !value)} />
  </div>;
}

function SalesDiscrepancyApprovalPanel({ session, orderId, canApprove, refreshed }: { session: Session; orderId: string; canApprove: boolean; refreshed: () => Promise<void> }) {
  const [workspace, setWorkspace] = useState<DiscrepancyWorkspace | null>(null);
  const [expanded, setExpanded] = useState<string | null>(null);
  const [forms, setForms] = useState<Record<string, { unitPrice: string; discountAmount: string; taxRuleId: string; taxApplied: boolean }>>({});
  const [notes, setNotes] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const load = useCallback(async () => {
    try {
      const body = await fetch(`/api/sales/backoffice-orders/${orderId}/discrepancies`, { headers: authHeaders(session), cache: "no-store" }).then(jsonResponse) as DiscrepancyWorkspace;
      if (body.workspaceVersion !== 1) throw new Error("DISCREPANCY_WORKSPACE_CONTRACT_MISMATCH");
      setWorkspace(body);
      const next: typeof forms = {};
      body.lines.filter((line) => line.commercialApprovalStatus === "PENDING").forEach((line) => { next[line.id] = { unitPrice: String(line.sourceUnitPrice), discountAmount: String(line.sourceDiscountAmount), taxRuleId: line.sourceTaxRuleId ?? "", taxApplied: Boolean(line.sourceTaxRuleId) }; });
      setForms(next);
    } catch (caught) { setError(caught instanceof Error ? caught.message : "Discrepancy gagal dimuat."); }
  }, [orderId, session]);
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- fetch synchronizes the active SO projection
    void load();
  }, [load]);
  if (!workspace?.cases.length) return null;
  async function approve(item: DiscrepancyCase) {
    const lines = workspace?.lines.filter((line) => line.discrepancyId === item.id && line.commercialApprovalStatus === "PENDING") ?? [];
    if (!lines.length) return;
    setBusy(true); setError("");
    try {
      await fetch(`/api/sales/backoffice-orders/${orderId}/discrepancies`, { method: "PATCH", headers: authHeaders(session, true), body: JSON.stringify({ action: "APPROVE_OVERAGE", discrepancyId: item.id, masterVersion: item.masterVersion, operationId: crypto.randomUUID(), notes: notes.trim() || undefined, lines: lines.map((line) => ({ discrepancyLineId: line.id, unitPrice: Number(forms[line.id]?.unitPrice), discountAmount: Number(forms[line.id]?.discountAmount), taxApplied: forms[line.id]?.taxApplied ?? false, taxRuleId: forms[line.id]?.taxApplied ? forms[line.id]?.taxRuleId : null })) }) }).then(jsonResponse);
      await load(); await refreshed(); setNotes("");
    } catch (caught) { setError(caught instanceof Error ? caught.message : "Approval gagal."); }
    finally { setBusy(false); }
  }
  return <section className="border-t border-amber-200 bg-amber-50/60 p-5">
    <div className="flex items-start gap-3"><AlertTriangle className="mt-0.5 h-5 w-5 text-amber-700"/><div><h2 className="font-black text-slate-950">Selisih penerimaan Customer</h2><p className="text-sm text-slate-600">Sales hanya menetapkan nilai komersial kelebihan barang. Penyesuaian barang fisik tetap dilakukan Gudang dari Surat Jalan.</p></div></div>
    {error && <div className="mt-3 rounded-xl bg-rose-50 p-3 text-sm font-semibold text-rose-700">{errorText(error)}</div>}
    <div className="mt-4 space-y-3">{workspace.cases.map((item) => { const lines = workspace.lines.filter((line) => line.discrepancyId === item.id); const pending = lines.filter((line) => line.commercialApprovalStatus === "PENDING"); const open = expanded === item.id; return <article key={item.id} className="overflow-hidden rounded-xl border border-amber-200 bg-white"><button type="button" onClick={() => setExpanded(open ? null : item.id)} className="flex w-full items-center justify-between gap-3 p-4 text-left"><span><strong>{item.discrepancyNo}</strong><span className="ml-2 rounded-full bg-slate-100 px-2 py-1 text-xs font-bold">{item.status.replaceAll("_", " ")}</span><span className="mt-1 block text-xs text-slate-500">{lines.length} baris selisih · diperbarui {dateTimeText(item.updatedAt)}</span></span>{open ? <ChevronUp className="h-5 w-5"/> : <ChevronDown className="h-5 w-5"/>}</button>{open && <div className="border-t p-4"><div className="space-y-3">{lines.map((line) => { const form = forms[line.id]; return <div key={line.id} className="rounded-xl border border-slate-200 p-4"><div className="flex flex-wrap justify-between gap-2"><div><strong>{line.expectedProductCode} · {line.expectedProductName}</strong><p className="text-xs text-slate-500">{line.discrepancyType} · {line.quantityUom} {line.uomName}</p></div><span className={`h-fit rounded-full px-2 py-1 text-xs font-bold ${line.commercialApprovalStatus === "APPROVED" ? "bg-emerald-100 text-emerald-800" : line.commercialApprovalStatus === "PENDING" ? "bg-amber-100 text-amber-800" : "bg-slate-100 text-slate-600"}`}>{line.commercialApprovalStatus === "NOT_REQUIRED" ? "Tidak perlu approval Sales" : line.commercialApprovalStatus}</span></div>{form && <div className="mt-4 grid gap-3 lg:grid-cols-3"><label className="text-xs font-bold text-slate-600">Harga satuan<input type="number" min="0" step="any" value={form.unitPrice} onChange={(event) => setForms((current) => ({ ...current, [line.id]: { ...form, unitPrice: event.target.value } }))} className="mt-1 min-h-11 w-full rounded-xl border px-3 text-right text-sm"/></label><label className="text-xs font-bold text-slate-600">Diskon untuk qty ini<input type="number" min="0" step="any" value={form.discountAmount} onChange={(event) => setForms((current) => ({ ...current, [line.id]: { ...form, discountAmount: event.target.value } }))} className="mt-1 min-h-11 w-full rounded-xl border px-3 text-right text-sm"/></label><label className="text-xs font-bold text-slate-600">Pajak<select value={form.taxApplied ? form.taxRuleId : ""} onChange={(event) => setForms((current) => ({ ...current, [line.id]: { ...form, taxApplied: Boolean(event.target.value), taxRuleId: event.target.value } }))} className="mt-1 min-h-11 w-full rounded-xl border px-3 text-sm"><option value="">Tanpa pajak</option>{workspace.taxRules.map((tax) => <option key={tax.id} value={tax.id}>{tax.code} · {tax.name} {Number(tax.ratePercent)}%</option>)}</select></label></div>}</div>; })}</div>{pending.length > 0 && canApprove && <><label className="mt-4 block text-xs font-bold text-slate-600">Catatan approval (opsional)<textarea value={notes} onChange={(event) => setNotes(event.target.value)} maxLength={500} className="mt-1 min-h-20 w-full rounded-xl border p-3 text-sm"/></label><div className="mt-3 flex justify-end"><button disabled={busy || pending.some((line) => !Number.isFinite(Number(forms[line.id]?.unitPrice)) || !Number.isFinite(Number(forms[line.id]?.discountAmount)) || (forms[line.id]?.taxApplied && !forms[line.id]?.taxRuleId))} onClick={() => void approve(item)} className="inline-flex min-h-11 items-center gap-2 rounded-xl bg-emerald-600 px-4 font-black text-white disabled:bg-slate-300">{busy ? <Loader2 className="h-4 w-4 animate-spin"/> : <CheckCircle2 className="h-4 w-4"/>}Setujui nilai kelebihan</button></div></>}</div>}</article>; })}</div>
  </section>;
}

function ActivityLog({ openSource, activity, open, toggle }: { openSource: (id: string) => void; activity: OrderActivity[]; open: boolean; toggle: () => void }) {
  return <section className="overflow-hidden rounded-xl border border-slate-200 bg-white shadow-sm">
    <button type="button" onClick={toggle} aria-expanded={open} className="flex w-full items-center justify-between gap-4 px-5 py-4 text-left hover:bg-slate-50">
      <span className="flex items-center gap-3"><span className="rounded-full bg-emerald-50 p-2 text-emerald-700"><History className="h-4 w-4" /></span><span><strong className="block text-sm text-slate-950">Log aktivitas</strong><span className="text-xs text-slate-500">Riwayat perubahan dokumen · {activity.length} aktivitas</span></span></span>
      {open ? <ChevronUp className="h-5 w-5 text-slate-400" /> : <ChevronDown className="h-5 w-5 text-slate-400" />}
    </button>
    {open && <div className="border-t border-slate-200 px-5 py-5">
      {activity.length ? <ol className="relative ml-2 border-l border-slate-200">{activity.map((item, index) => <li key={`${item.createdAt}-${index}`} className="relative pb-6 pl-6 last:pb-0">
        <span className={`absolute -left-1.5 top-1 h-3 w-3 rounded-full border-2 border-white ${item.action === "CANCEL" ? "bg-rose-500" : item.action === "REVISE" ? "bg-amber-500" : item.action === "CONFIRM" ? "bg-emerald-600" : "bg-slate-400"}`} />
        <div className="flex flex-wrap items-start justify-between gap-x-4 gap-y-1"><strong className="text-sm text-slate-950">{activityLabel(item.action)}</strong><time className="text-xs text-slate-500">{dateTimeText(item.createdAt)}</time></div>
        <p className="mt-0.5 text-xs text-slate-500">oleh {item.actorName ?? "User"}</p>
        {item.reason && <div className="mt-2 rounded-lg bg-slate-50 px-3 py-2 text-sm text-slate-700">{item.reason}</div>}
        {item.relatedDocumentType === 'RETAIL_SALE' && item.relatedDocumentId && <button onClick={() => openSource(item.relatedDocumentId!)} className="mt-2 text-sm font-bold text-emerald-700 underline">Buka dokumen asal {item.relatedDocumentNo}</button>}
      </li>)}</ol> : <p className="py-3 text-center text-sm text-slate-500">Belum ada aktivitas pada dokumen ini.</p>}
    </div>}
  </section>;
}

function Info({ label, value }: { label: string; value: string }) { return <div><span className="text-slate-500">{label}</span><strong className="block">{value}</strong></div>; }
