"use client";

import {
  useCallback,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from "react";
import type { Session } from "@supabase/supabase-js";
import {
  AlertTriangle,
  Boxes,
  FilePlus2,
  Download,
  Loader2,
  RefreshCcw,
  Send,
  ShoppingCart,
  X,
} from "lucide-react";
import { useEscapeClose } from "@/lib/use-escape-close";

type RequestDoc = {
  id: string;
  request_no: string;
  store_id: string;
  request_source: "MANUAL" | "NEGATIVE_STOCK_SESSION_CLOSE";
  needed_date: string | null;
  notes: string | null;
  status: string;
  line_count: number;
};
type RequestLine = {
  id: string;
  document_id: string;
  product_id: string;
  requested_uom_id: string;
  requested_qty: number | string;
  factor_to_base_snapshot: number | string;
  requested_base_qty: number | string;
  product_name_snapshot: string;
  requested_uom_name_snapshot: string;
};
type OrderDoc = {
  id: string;
  order_no: string;
  supplier_id: string;
  store_id: string;
  status: string;
  line_count: number;
  estimated_total: number | string;
  master_version: number;
};
type OrderLine = { id: string; document_id: string };
type Allocation = {
  supplier_order_line_id: string;
  stock_request_line_id: string;
  allocated_base_qty: number | string;
};
type Supplier = { id: string; supplier_name: string };
type Warehouse = { id: string; name: string; store_id: string | null };
type Store = { id: string; store_name: string };
type Relation = {
  product_id: string;
  supplier_id: string;
  purchase_uom_id: string;
  reference_purchase_price: number | string | null;
  last_purchase_price: number | string | null;
};
type PurchaseUom = {
  product_id: string;
  uom_id: string;
  purchase_price: number | string | null;
};
type ProcurementDemand = {
  id: string;
  store_id: string;
  store_name: string;
  warehouse_id: string;
  warehouse_name: string;
  cashier_session_id: string;
  session_code: string;
  status: string;
  total_demand_base_qty: number | string;
  total_released_base_qty: number | string;
  stock_request_document_id: string | null;
  master_version: number;
  session_closed_at: string | null;
  updated_at: string;
};
type ProcurementDemandLine = {
  id: string;
  demand_id: string;
  sales_id: string;
  stock_product_id: string;
  product_sku: string;
  product_name: string;
  demand_base_qty: number | string;
  released_base_qty: number | string;
  open_demand_base_qty: number | string;
  stock_request_line_id: string | null;
  status: string;
};
type ProcurementAmendment = {
  id: string;
  demand_id: string;
  stock_request_document_id: string;
  stock_request_line_id: string;
  product_id: string;
  reason: string;
  status: string;
  desired_base_qty: number | string;
  draft_allocated_base_qty: number | string;
  final_allocated_base_qty: number | string;
  delta_base_qty: number | string;
  resolution_supplier_order_id: string | null;
  updated_at: string;
};
type Payload = {
  requests?: RequestDoc[];
  requestLines?: RequestLine[];
  orders?: OrderDoc[];
  orderLines?: OrderLine[];
  allocations?: Allocation[];
  suppliers?: Supplier[];
  warehouses?: Warehouse[];
  stores?: Store[];
  productSuppliers?: Relation[];
  purchaseUoms?: PurchaseUom[];
  procurementWorkspaceVersion?: number;
  procurementDemands?: ProcurementDemand[];
  procurementDemandLines?: ProcurementDemandLine[];
  procurementAmendments?: ProcurementAmendment[];
  error?: string;
};
type FormLine = {
  source: RequestLine;
  key: string;
  quantity: string;
  price: string;
  include: boolean;
};

const headers = (session: Session) => ({
  Authorization: `Bearer ${session.access_token}`,
});
const money = (value: number | string) =>
  new Intl.NumberFormat("id-ID", {
    style: "currency",
    currency: "IDR",
    maximumFractionDigits: 0,
  }).format(Number(value) || 0);
function friendly(code?: string) {
  const map: Record<string, string> = {
    PURCHASE_MANAGER_REQUIRED: "Role Anda tidak boleh membuat Supplier Order.",
    ACTIVE_DESTINATION_WAREHOUSE_NOT_FOUND:
      "Gudang tujuan tidak sesuai toko atau sudah tidak aktif.",
    ACTIVE_SUPPLIER_NOT_FOUND: "Supplier sudah tidak aktif.",
    SUPPLIER_ORDER_EXPECTED_DATE_INVALID:
      "Perkiraan datang tidak boleh sebelum tanggal order.",
    SUPPLIER_ORDER_LINE_WITHOUT_REQUEST_ALLOCATION:
      "Setiap barang wajib berasal dari Permintaan Stok.",
    REQUEST_ALLOCATION_EXCEEDS_REQUESTED_QUANTITY:
      "Alokasi melebihi sisa permintaan.",
    MASTER_VERSION_CONFLICT: "Dokumen berubah di tab lain. Muat ulang.",
    SUPPLIER_ORDER_EXPORT_SELECTION_REQUIRED:
      "Pilih minimal satu Supplier Order untuk diekspor.",
    SUPPLIER_ORDER_EXPORT_SELECTION_LIMIT_EXCEEDED:
      "Maksimal 100 Supplier Order dalam satu file Excel.",
    SUPPLIER_ORDER_EXPORT_SELECTION_INVALID:
      "Pilihan Supplier Order tidak valid. Muat ulang lalu pilih kembali.",
    SUPPLIER_ORDER_EXPORT_NOT_FOUND_OR_ACCESS_DENIED:
      "Salah satu Supplier Order tidak ditemukan atau bukan milik perusahaan aktif.",
    SUPPLIER_ORDER_EXPORT_RESULT_INVALID:
      "Hasil export tidak lengkap. Muat ulang lalu coba kembali.",
    PROCUREMENT_WORKSPACE_CONTRACT_MISMATCH:
      "Runtime Demand Purchasing belum lengkap. Hentikan operasi dan selesaikan rollout ODR-4.",
  };
  return map[code ?? ""] ?? code ?? "Operasi Supplier Order gagal.";
}
const quantity = (value: number | string) =>
  new Intl.NumberFormat("id-ID", { maximumFractionDigits: 6 }).format(
    Number(value) || 0,
  );
function amendmentLabel(reason: string) {
  return ({
    UNALLOCATED: "Belum dialokasikan ke Draft PO",
    DRAFT_SYNC_PENDING: "Menunggu sinkronisasi Draft PO",
    AMBIGUOUS_DRAFT_TARGET: "Lebih dari satu Draft PO kandidat",
    MIXED_MANUAL_DRAFT_LINE: "Baris Draft PO bercampur input manual",
    FINAL_PO_IMMUTABLE: "PO final tidak boleh diubah; buat order selisih",
    QUANTITY_DECREASE_REQUIRES_REVIEW: "Penurunan quantity perlu review",
    DRAFT_UOM_CONVERSION_REQUIRES_REVIEW: "Konversi UOM Draft perlu review",
  } as Record<string, string>)[reason] ?? reason;
}

export function SupplierOrderView({
  session,
  companyId,
  canCreate,
  canPost,
  canExport,
  notify,
}: {
  session: Session;
  companyId: string;
  canCreate: boolean;
  canPost: boolean;
  canExport: boolean;
  notify: (value: string) => void;
}) {
  const [payload, setPayload] = useState<Payload>({}),
    [loading, setLoading] = useState(true),
    [error, setError] = useState(""),
    [selected, setSelected] = useState<RequestDoc | null>(null),
    [exporting, setExporting] = useState(false),
    [exportStatus, setExportStatus] = useState('ALL'),
    [exportSupplier, setExportSupplier] = useState(''),
    [exportStore, setExportStore] = useState(''),
    [selectedOrderIds, setSelectedOrderIds] = useState<Set<string>>(new Set());
  const load = useCallback(async () => {
    const response = await fetch("/api/purchase/supplier-orders", {
      headers: headers(session),
    });
    const body = (await response.json()) as Payload;
    if (!response.ok) throw new Error(friendly(body.error));
    if (body.procurementWorkspaceVersion !== 1) {
      throw new Error(friendly("PROCUREMENT_WORKSPACE_CONTRACT_MISMATCH"));
    }
    setPayload(body);
  }, [session]);
  const refresh = useCallback(async () => {
    setLoading(true);
    setError("");
    setSelectedOrderIds(new Set());
    try {
      await load();
    } catch (reason) {
      setError(
        reason instanceof Error
          ? reason.message
          : "Gagal memuat data Purchase.",
      );
    } finally {
      setLoading(false);
    }
  }, [load]);
  const confirmExisting = useCallback(
    async (order: OrderDoc) => {
      setLoading(true);
      setError("");
      try {
        const response = await fetch(
          `/api/purchase/supplier-orders/${order.id}/confirm`,
          {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              ...headers(session),
            },
            body: JSON.stringify({
              masterVersion: order.master_version,
              idempotencyKey: crypto.randomUUID(),
            }),
          },
        );
        const result = (await response.json()) as { error?: string };
        if (!response.ok) throw new Error(friendly(result.error));
        notify(`${order.order_no} berhasil dikonfirmasi.`);
        await load();
      } catch (reason) {
        setError(
          reason instanceof Error
            ? reason.message
            : "Gagal mengonfirmasi order.",
        );
      } finally {
        setLoading(false);
      }
    },
    [load, notify, session],
  );
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- workspace data follows the active Company
    void refresh();
  }, [companyId, refresh]);
  const stores = useMemo(
    () => new Map((payload.stores ?? []).map((v) => [v.id, v.store_name])),
    [payload.stores],
  );
  const suppliers = useMemo(
    () =>
      new Map((payload.suppliers ?? []).map((v) => [v.id, v.supplier_name])),
    [payload.suppliers],
  );
  const filteredOrders = useMemo(() => (payload.orders ?? []).filter((order) =>
    (exportStatus === 'ALL' || order.status === exportStatus) &&
    (!exportSupplier || order.supplier_id === exportSupplier) &&
    (!exportStore || order.store_id === exportStore)
  ), [exportStatus, exportStore, exportSupplier, payload.orders]);
  const allFilteredSelected = filteredOrders.length > 0 &&
    filteredOrders.every((order) => selectedOrderIds.has(order.id));
  const remainingLines = useMemo(() => {
    const activeOrderIds = new Set(
      (payload.orders ?? [])
        .filter((order) =>
          ["DRAFT", "CONFIRMED", "PARTIALLY_RECEIVED", "RECEIVED"].includes(
            order.status,
          ),
        )
        .map((order) => order.id),
    );
    const activeOrderLineIds = new Set(
      (payload.orderLines ?? [])
        .filter((line) => activeOrderIds.has(line.document_id))
        .map((line) => line.id),
    );
    const allocatedByRequest = new Map<string, number>();
    for (const allocation of payload.allocations ?? []) {
      if (!activeOrderLineIds.has(allocation.supplier_order_line_id)) continue;
      allocatedByRequest.set(
        allocation.stock_request_line_id,
        (allocatedByRequest.get(allocation.stock_request_line_id) ?? 0) +
          Number(allocation.allocated_base_qty),
      );
    }
    return (payload.requestLines ?? [])
      .map((line) => {
        const remainingBase = Math.max(
          0,
          Number(line.requested_base_qty) -
            (allocatedByRequest.get(line.id) ?? 0),
        );
        return {
          ...line,
          remaining_base_qty: remainingBase,
          remaining_qty: remainingBase / Number(line.factor_to_base_snapshot),
        };
      })
      .filter((line) => line.remaining_base_qty > 0);
  }, [
    payload.allocations,
    payload.orderLines,
    payload.orders,
    payload.requestLines,
  ]);
  const visibleRequests = useMemo(() => {
    const ids = new Set(remainingLines.map((line) => line.document_id));
    return (payload.requests ?? []).filter((request) => ids.has(request.id));
  }, [payload.requests, remainingLines]);
  const requestNumbers = useMemo(
    () => new Map((payload.requests ?? []).map((row) => [row.id, row.request_no])),
    [payload.requests],
  );
  const requestLineProducts = useMemo(
    () => new Map((payload.requestLines ?? []).map((row) => [
      row.id,
      { name: row.product_name_snapshot, uom: row.requested_uom_name_snapshot },
    ])),
    [payload.requestLines],
  );
  const activeDemands = useMemo(() => (payload.procurementDemands ?? []).filter(
    (demand) => demand.status !== "CLOSED" ||
      (payload.procurementDemandLines ?? []).some((line) =>
        line.demand_id === demand.id && Number(line.open_demand_base_qty) > 0),
  ), [payload.procurementDemandLines, payload.procurementDemands]);
  const openAmendments = useMemo(() =>
    (payload.procurementAmendments ?? []).filter((row) => row.status === "OPEN"),
  [payload.procurementAmendments]);
  async function exportOrders() {
    if (selectedOrderIds.size<1) return
    setExporting(true); setError('')
    try {
      const response = await fetch('/api/purchase/supplier-orders/export', {
        method: 'POST',
        headers: { ...headers(session), 'Content-Type': 'application/json' },
        body: JSON.stringify({ documentIds: Array.from(selectedOrderIds) }),
      })
      if (!response.ok) {
        const body = await response.json() as { error?: string }
        throw new Error(friendly(body.error))
      }
      const disposition = response.headers.get('content-disposition') ?? ''
      const fileName = disposition.match(/filename="([^"]+)"/)?.[1] ?? 'Supplier-Order.xlsx'
      const url = URL.createObjectURL(await response.blob())
      const anchor = document.createElement('a')
      anchor.href = url; anchor.download = fileName; anchor.click()
      URL.revokeObjectURL(url)
      setSelectedOrderIds(new Set())
      notify('Export Supplier Order berhasil diunduh.')
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : 'Export Supplier Order gagal.')
    } finally { setExporting(false) }
  }
  function toggleOrder(orderId: string) {
    setError('')
    if (!selectedOrderIds.has(orderId) && selectedOrderIds.size>=100) {
      setError('Maksimal 100 Supplier Order dalam satu file Excel.')
      return
    }
    setSelectedOrderIds((current) => {
      const next = new Set(current)
      if (next.has(orderId)) next.delete(orderId)
      else next.add(orderId)
      return next
    })
  }
  function toggleAllFiltered() {
    setError('')
    if (!allFilteredSelected && filteredOrders.length>100) {
      setError('Hasil filter lebih dari 100 PO. Persempit filter sebelum memilih semua.')
      return
    }
    setSelectedOrderIds((current) => {
      const next = new Set(current)
      for (const order of filteredOrders) {
        if (allFilteredSelected) next.delete(order.id)
        else next.add(order.id)
      }
      return next
    })
  }
  return (
    <>
      <div className="mb-7 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <p className="text-xs font-bold uppercase tracking-[.16em] text-emerald-600">
            Purchase
          </p>
          <h1 className="mt-2 text-3xl font-black">Supplier Order</h1>
          <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-500">
            Tinjau permintaan dari POS, tentukan Supplier dan Gudang tujuan,
            lalu konfirmasi order. Belum ada penerimaan barang, perubahan stok,
            atau Finance pada tahap ini.
          </p>
        </div>
        <div className="flex flex-wrap gap-2">{canExport && <button onClick={() => void exportOrders()} disabled={exporting || selectedOrderIds.size===0} className="inline-flex items-center gap-2 rounded-xl bg-emerald-600 px-4 py-3 text-sm font-bold text-white disabled:cursor-not-allowed disabled:opacity-40"><Download className="h-4 w-4"/>{exporting ? 'Menyiapkan...' : `Export PO Terpilih (${selectedOrderIds.size})`}</button>}<button onClick={() => void refresh()} className="inline-flex items-center gap-2 rounded-xl border bg-white px-4 py-3 text-sm font-bold"><RefreshCcw className={`h-4 w-4 ${loading ? "animate-spin" : ""}`} />Muat ulang</button></div>
      </div>
      {canExport && <div className="mb-5 grid gap-3 rounded-2xl border border-slate-200 bg-white p-4 sm:grid-cols-3"><label className="text-xs font-bold uppercase tracking-wide text-slate-500">Status<select value={exportStatus} onChange={(event) => { setExportStatus(event.target.value); setSelectedOrderIds(new Set()) }} className="mt-2 min-h-11 w-full rounded-xl border border-slate-200 px-3 text-sm font-semibold text-slate-800"><option value="ALL">Semua status</option>{['DRAFT','CONFIRMED','PARTIALLY_RECEIVED','RECEIVED','CANCELED'].map((value) => <option key={value}>{value}</option>)}</select></label><label className="text-xs font-bold uppercase tracking-wide text-slate-500">Supplier<select value={exportSupplier} onChange={(event) => { setExportSupplier(event.target.value); setSelectedOrderIds(new Set()) }} className="mt-2 min-h-11 w-full rounded-xl border border-slate-200 px-3 text-sm font-semibold text-slate-800"><option value="">Semua Supplier</option>{(payload.suppliers ?? []).map((item) => <option key={item.id} value={item.id}>{item.supplier_name}</option>)}</select></label><label className="text-xs font-bold uppercase tracking-wide text-slate-500">Toko<select value={exportStore} onChange={(event) => { setExportStore(event.target.value); setSelectedOrderIds(new Set()) }} className="mt-2 min-h-11 w-full rounded-xl border border-slate-200 px-3 text-sm font-semibold text-slate-800"><option value="">Semua Toko</option>{(payload.stores ?? []).map((item) => <option key={item.id} value={item.id}>{item.store_name}</option>)}</select></label></div>}
      {!canCreate && !canPost && (
        <div className="mb-5 rounded-2xl border border-blue-200 bg-blue-50 p-4 text-sm text-blue-800">
          Akses baca saja sesuai permission Supplier Order Anda.
        </div>
      )}
      {canCreate && !canPost && (
        <div className="mb-5 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-800">
          Akses operasional: Anda dapat membuat Draft, tetapi konfirmasi
          dilakukan approver.
        </div>
      )}
      {error && (
        <div className="mb-5 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-700">
          {error}
        </div>
      )}
      <section className="mb-6 rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <p className="text-xs font-bold uppercase tracking-[.16em] text-violet-600">
              Demand reservation per sesi
            </p>
            <h2 className="mt-1 text-xl font-black">Kebutuhan Purchasing canonical</h2>
            <p className="mt-1 text-sm text-slate-500">
              Kekurangan berasal dari Reservation Sales Order. Draft PO boleh disinkronkan;
              PO final tidak pernah diubah otomatis.
            </p>
          </div>
          <div className="flex gap-2 text-xs font-black">
            <span className="rounded-full bg-violet-50 px-3 py-2 text-violet-700">
              {activeDemands.length} demand aktif
            </span>
            <span className={`rounded-full px-3 py-2 ${openAmendments.length
              ? "bg-amber-50 text-amber-800" : "bg-emerald-50 text-emerald-700"}`}>
              {openAmendments.length} perlu review
            </span>
          </div>
        </div>
        {activeDemands.length === 0 ? (
          <div className="mt-4 rounded-xl border border-dashed p-5 text-sm text-slate-500">
            Belum ada shortage Reservation aktif untuk Company ini.
          </div>
        ) : (
          <div className="mt-4 grid gap-3 lg:grid-cols-2">
            {activeDemands.map((demand) => {
              const lines = (payload.procurementDemandLines ?? []).filter(
                (line) => line.demand_id === demand.id &&
                  Number(line.open_demand_base_qty) > 0,
              );
              const openQty = lines.reduce(
                (total, line) => total + Number(line.open_demand_base_qty), 0,
              );
              return <article key={demand.id} className="rounded-2xl border border-violet-100 bg-violet-50/40 p-4">
                <div className="flex items-start gap-3">
                  <Boxes className="mt-0.5 h-5 w-5 shrink-0 text-violet-600"/>
                  <div className="min-w-0 flex-1">
                    <div className="flex flex-wrap items-center gap-2">
                      <p className="font-black">{demand.session_code}</p>
                      <span className="rounded-full bg-white px-2.5 py-1 text-[11px] font-black text-violet-700">
                        {demand.status}
                      </span>
                    </div>
                    <p className="mt-1 text-sm text-slate-600">
                      {demand.store_name} · {demand.warehouse_name}
                    </p>
                    <p className="mt-2 text-sm font-black text-violet-800">
                      Sisa kebutuhan {quantity(openQty)} base qty · {lines.length} Product
                    </p>
                    {demand.stock_request_document_id && <p className="mt-1 text-xs text-slate-500">
                      Stock Request: {requestNumbers.get(demand.stock_request_document_id) ?? "Terhubung"}
                    </p>}
                    <div className="mt-3 space-y-1 text-xs text-slate-600">
                      {lines.slice(0, 4).map((line) => <p key={line.id} className="flex justify-between gap-3">
                        <span className="truncate">{line.product_sku} · {line.product_name}</span>
                        <strong className="shrink-0">{quantity(line.open_demand_base_qty)} base</strong>
                      </p>)}
                      {lines.length > 4 && <p className="font-bold text-violet-700">+{lines.length - 4} Product lainnya</p>}
                    </div>
                  </div>
                </div>
              </article>;
            })}
          </div>
        )}
        {openAmendments.length > 0 && <div className="mt-4 rounded-2xl border border-amber-200 bg-amber-50 p-4">
          <div className="flex items-center gap-2 text-amber-900">
            <AlertTriangle className="h-5 w-5"/>
            <h3 className="font-black">Selisih yang perlu tindakan Purchasing</h3>
          </div>
          <div className="mt-3 space-y-2">
            {openAmendments.map((amendment) => {
              const product = requestLineProducts.get(amendment.stock_request_line_id);
              return <div key={amendment.id} className="rounded-xl border border-amber-200 bg-white p-3 text-sm">
                <div className="flex flex-wrap items-start justify-between gap-2">
                  <div>
                    <p className="font-black">{product?.name ?? "Product terkait"}</p>
                    <p className="mt-1 text-xs font-semibold text-amber-800">{amendmentLabel(amendment.reason)}</p>
                  </div>
                  <span className={`rounded-full px-2.5 py-1 text-xs font-black ${Number(amendment.delta_base_qty) >= 0
                    ? "bg-blue-50 text-blue-700" : "bg-rose-50 text-rose-700"}`}>
                    Selisih {quantity(amendment.delta_base_qty)} base
                  </span>
                </div>
                <p className="mt-2 text-xs text-slate-500">
                  Dibutuhkan {quantity(amendment.desired_base_qty)} · Draft {quantity(amendment.draft_allocated_base_qty)} · Final {quantity(amendment.final_allocated_base_qty)}
                </p>
              </div>;
            })}
          </div>
        </div>}
      </section>
      <div className="grid gap-6 xl:grid-cols-2">
        <List title="Permintaan menunggu order">
          {visibleRequests.length === 0 ? (
            <Empty text="Tidak ada barang yang masih menunggu order." />
          ) : (
            visibleRequests.map((doc) => (
              <article
                key={doc.id}
                className="rounded-2xl border bg-white p-5 shadow-sm"
              >
                <div className="flex items-start gap-3">
                  <FilePlus2 className="mt-1 h-5 w-5 text-emerald-600" />
                  <div className="flex-1">
                    <div className="flex flex-wrap items-center gap-2">
                      <p className="font-black">{doc.request_no}</p>
                      {doc.request_source === "NEGATIVE_STOCK_SESSION_CLOSE" && (
                        <span className="rounded-full bg-rose-50 px-2.5 py-1 text-[11px] font-black uppercase tracking-wide text-rose-700">
                          Otomatis · stok minus sesi
                        </span>
                      )}
                    </div>
                    <p className="mt-1 text-sm text-slate-500">
                      {stores.get(doc.store_id) ?? "Toko"} ·{" "}
                      {
                        remainingLines.filter(
                          (line) => line.document_id === doc.id,
                        ).length
                      }{" "}
                      barang tersisa · perlu{" "}
                      {doc.needed_date ?? "belum ditentukan"}
                    </p>
                    {doc.request_source === "NEGATIVE_STOCK_SESSION_CLOSE" && (
                      <p className="mt-2 text-xs font-semibold text-rose-700">
                        Dibuat saat kasir menutup sesi dari kekurangan yang belum direplenish.
                      </p>
                    )}
                  </div>
                  <span className="rounded-full bg-amber-50 px-3 py-1 text-xs font-bold text-amber-700">
                    {doc.status}
                  </span>
                </div>
                {canCreate && (
                  <button
                    onClick={() => setSelected(doc)}
                    className="mt-4 inline-flex items-center gap-2 rounded-xl bg-emerald-500 px-4 py-2.5 text-sm font-black text-white"
                  >
                    <ShoppingCart className="h-4 w-4" />
                    Buat Order
                  </button>
                )}
              </article>
            ))
          )}
        </List>
        <List title="Riwayat Supplier Order">
          {canExport && filteredOrders.length>0 && <label className="mb-3 flex min-h-11 cursor-pointer items-center gap-3 rounded-xl border border-slate-200 bg-slate-50 px-4 text-sm font-bold text-slate-700"><input type="checkbox" checked={allFilteredSelected} onChange={toggleAllFiltered} className="h-5 w-5 rounded border-slate-300 accent-emerald-600"/><span>Pilih semua hasil filter ({filteredOrders.length})</span><span className="ml-auto text-xs text-slate-500">Terpilih {selectedOrderIds.size}/100</span></label>}
          {filteredOrders.length === 0 ? (
            <Empty text="Tidak ada Supplier Order yang sesuai filter." />
          ) : (
            filteredOrders.map((order) => (
              <article
                key={order.id}
                className="rounded-2xl border bg-white p-5 shadow-sm"
              >
                <div className="flex items-start gap-3">
                  {canExport && <input type="checkbox" aria-label={`Pilih ${order.order_no}`} checked={selectedOrderIds.has(order.id)} onChange={() => toggleOrder(order.id)} className="mt-1 h-5 w-5 shrink-0 rounded border-slate-300 accent-emerald-600"/>}
                  <ShoppingCart className="mt-1 h-5 w-5 text-slate-500" />
                  <div className="flex-1">
                    <p className="font-black">{order.order_no}</p>
                    <p className="mt-1 text-sm text-slate-500">
                      {suppliers.get(order.supplier_id) ?? "Supplier"} ·{" "}
                      {order.line_count} barang · {money(order.estimated_total)}
                    </p>
                  </div>
                  <span className="rounded-full bg-slate-100 px-3 py-1 text-xs font-bold">
                    {order.status}
                  </span>
                </div>
                {canPost && order.status === "DRAFT" && (
                  <button
                    onClick={() => void confirmExisting(order)}
                    disabled={loading}
                    className="mt-4 inline-flex items-center gap-2 rounded-xl border border-emerald-600 px-4 py-2.5 text-sm font-black text-emerald-700"
                  >
                    <Send className="h-4 w-4" />
                    Konfirmasi Draft
                  </button>
                )}
              </article>
            ))
          )}
        </List>
      </div>
      {selected && (
        <OrderModal
          request={selected}
          lines={remainingLines
            .filter((line) => line.document_id === selected.id)
            .map((line) => ({
              ...line,
              requested_qty: line.remaining_qty,
              requested_base_qty: line.remaining_base_qty,
            }))}
          suppliers={payload.suppliers ?? []}
          warehouses={(payload.warehouses ?? []).filter(
            (item) =>
              item.store_id === null || item.store_id === selected.store_id,
          )}
          relations={payload.productSuppliers ?? []}
          purchaseUoms={payload.purchaseUoms ?? []}
          session={session}
          canPost={canPost}
          close={() => setSelected(null)}
          complete={async (message) => {
            setSelected(null);
            notify(message);
            await refresh();
          }}
        />
      )}
    </>
  );
}

function List({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section>
      <h2 className="mb-3 text-lg font-black">{title}</h2>
      <div className="space-y-3">{children}</div>
    </section>
  );
}
function Empty({ text }: { text: string }) {
  return (
    <div className="rounded-2xl border border-dashed bg-white p-8 text-center text-sm text-slate-500">
      {text}
    </div>
  );
}
function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <label className="block text-sm font-bold text-slate-700">
      {label}
      <div className="mt-2 [&_.field]:w-full [&_.field]:rounded-xl [&_.field]:border [&_.field]:border-slate-300 [&_.field]:bg-white [&_.field]:p-3 [&_.field]:font-normal">
        {children}
      </div>
    </label>
  );
}

function OrderModal({
  request,
  lines,
  suppliers,
  warehouses,
  relations,
  purchaseUoms,
  session,
  canPost,
  close,
  complete,
}: {
  request: RequestDoc;
  lines: RequestLine[];
  suppliers: Supplier[];
  warehouses: Warehouse[];
  relations: Relation[];
  purchaseUoms: PurchaseUom[];
  session: Session;
  canPost: boolean;
  close: () => void;
  complete: (value: string) => void | Promise<void>;
}) {
  const [supplierId, setSupplierId] = useState(""),
    [warehouseId, setWarehouseId] = useState(""),
    [orderDate, setOrderDate] = useState(new Date().toISOString().slice(0, 10)),
    [expectedDate, setExpectedDate] = useState(request.needed_date ?? ""),
    [notes, setNotes] = useState(request.notes ?? ""),
    [busy, setBusy] = useState(false),
    [error, setError] = useState("");
  const [form, setForm] = useState<FormLine[]>(() =>
    lines.map((source) => ({
      source,
      key: crypto.randomUUID(),
      quantity: String(source.requested_qty),
      price: "0",
      include: true,
    })),
  );
  useEscapeClose(() => {
    if (!busy) close();
  });
  useEffect(() => {
    if (!supplierId) return;
    // eslint-disable-next-line react-hooks/set-state-in-effect -- changing Supplier intentionally recalculates suggested prices
    setForm((current) =>
      current.map((item) => {
        const relation = relations.find(
          (row) =>
            row.product_id === item.source.product_id &&
            row.supplier_id === supplierId &&
            row.purchase_uom_id === item.source.requested_uom_id,
        );
        const fallback = purchaseUoms.find(
          (row) =>
            row.product_id === item.source.product_id &&
            row.uom_id === item.source.requested_uom_id,
        );
        return {
          ...item,
          price: String(
            relation?.last_purchase_price ??
              relation?.reference_purchase_price ??
              fallback?.purchase_price ??
              0,
          ),
        };
      }),
    );
  }, [supplierId, relations, purchaseUoms]);
  const chosen = form.filter((item) => item.include);
  const unlinked = chosen.filter(
    (item) =>
      !relations.some(
        (row) =>
          row.product_id === item.source.product_id &&
          row.supplier_id === supplierId,
      ),
  ).length;
  async function save(confirm: boolean) {
    if (!supplierId || !warehouseId)
      return setError("Pilih Supplier dan Gudang tujuan.");
    if (!chosen.length) return setError("Pilih minimal satu barang.");
    if (
      chosen.some(
        (item) => Number(item.quantity) <= 0 || Number(item.price) < 0,
      )
    )
      return setError(
        "Jumlah harus lebih dari nol dan harga tidak boleh negatif.",
      );
    setBusy(true);
    setError("");
    try {
      const response = await fetch("/api/purchase/supplier-orders", {
        method: "POST",
        headers: { "Content-Type": "application/json", ...headers(session) },
        body: JSON.stringify({
          storeId: request.store_id,
          destinationWarehouseId: warehouseId,
          supplierId,
          orderDate,
          expectedDate: expectedDate || null,
          notes: notes || null,
          lines: chosen.map((item) => ({
            clientLineKey: item.key,
            productId: item.source.product_id,
            uomId: item.source.requested_uom_id,
            quantity: Number(item.quantity),
            estimatedUnitPrice: Number(item.price),
          })),
          allocations: chosen.map((item) => ({
            orderLineKey: item.key,
            requestLineId: item.source.id,
            allocatedBaseQty: Math.min(
              Number(item.source.requested_base_qty),
              Number(item.quantity) *
                Number(item.source.factor_to_base_snapshot),
            ),
          })),
        }),
      });
      const result = (await response.json()) as {
        data?: { documentId: string; orderNo: string; masterVersion: number };
        error?: string;
      };
      if (!response.ok || !result.data) throw new Error(friendly(result.error));
      if (confirm) {
        const posted = await fetch(
          `/api/purchase/supplier-orders/${result.data.documentId}/confirm`,
          {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              ...headers(session),
            },
            body: JSON.stringify({
              masterVersion: result.data.masterVersion,
              idempotencyKey: crypto.randomUUID(),
            }),
          },
        );
        const postResult = (await posted.json()) as { error?: string };
        if (!posted.ok) throw new Error(friendly(postResult.error));
      }
      await complete(
        `${result.data.orderNo} berhasil ${confirm ? "dikonfirmasi" : "disimpan sebagai Draft"}.`,
      );
    } catch (reason) {
      setError(
        reason instanceof Error ? reason.message : "Gagal menyimpan order.",
      );
      setBusy(false);
    }
  }
  return (
    <div
      className="fixed inset-0 z-50 bg-black/55 p-3 sm:p-6"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget && !busy) close();
      }}
    >
      <section
        role="dialog"
        aria-modal="true"
        className="mx-auto flex h-full max-w-5xl flex-col overflow-hidden rounded-2xl bg-white shadow-2xl"
      >
        <header className="flex items-start justify-between border-b p-5">
          <div>
            <p className="text-xs font-bold uppercase tracking-wider text-emerald-600">
              Dari {request.request_no}
            </p>
            <h2 className="mt-1 text-xl font-black">Buat Supplier Order</h2>
          </div>
          <button
            onClick={close}
            disabled={busy}
            className="rounded-xl border p-2"
            aria-label="Tutup"
          >
            <X className="h-5 w-5" />
          </button>
        </header>
        <div className="flex-1 overflow-y-auto p-5">
          {error && (
            <div className="mb-4 rounded-xl bg-rose-50 p-3 text-sm text-rose-700">
              {error}
            </div>
          )}
          <div className="grid gap-4 md:grid-cols-2">
            <Field label="Supplier">
              <select
                className="field"
                value={supplierId}
                onChange={(event) => setSupplierId(event.target.value)}
              >
                <option value="">Pilih Supplier</option>
                {suppliers.map((row) => (
                  <option key={row.id} value={row.id}>
                    {row.supplier_name}
                  </option>
                ))}
              </select>
            </Field>
            <Field label="Gudang tujuan">
              <select
                className="field"
                value={warehouseId}
                onChange={(event) => setWarehouseId(event.target.value)}
              >
                <option value="">Pilih Gudang</option>
                {warehouses.map((row) => (
                  <option key={row.id} value={row.id}>
                    {row.name}
                  </option>
                ))}
              </select>
            </Field>
            <Field label="Tanggal order">
              <input
                className="field"
                type="date"
                value={orderDate}
                onChange={(event) => setOrderDate(event.target.value)}
              />
            </Field>
            <Field label="Perkiraan datang">
              <input
                className="field"
                type="date"
                min={orderDate}
                value={expectedDate}
                onChange={(event) => setExpectedDate(event.target.value)}
              />
            </Field>
          </div>
          {supplierId && unlinked > 0 && (
            <div className="mt-4 rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-800">
              {unlinked} barang belum terhubung ke Supplier ini. Order tetap
              boleh dibuat; relasi tidak dibuat otomatis dan dapat dilengkapi
              lewat menu Supplier.
            </div>
          )}
          <div className="mt-5 space-y-3">
            {form.map((item) => (
              <div
                key={item.source.id}
                className="grid gap-3 rounded-xl border bg-slate-50 p-4 md:grid-cols-[36px_1fr_150px_180px]"
              >
                <input
                  type="checkbox"
                  checked={item.include}
                  onChange={(event) =>
                    setForm((all) =>
                      all.map((row) =>
                        row.source.id === item.source.id
                          ? { ...row, include: event.target.checked }
                          : row,
                      ),
                    )
                  }
                />
                <div>
                  <p className="font-bold">
                    {item.source.product_name_snapshot}
                  </p>
                  <p className="text-xs text-slate-500">
                    Diminta {item.source.requested_qty}{" "}
                    {item.source.requested_uom_name_snapshot}
                  </p>
                </div>
                <Field label="Jumlah order">
                  <input
                    className="field"
                    type="number"
                    min="0"
                    step="any"
                    value={item.quantity}
                    onChange={(event) =>
                      setForm((all) =>
                        all.map((row) =>
                          row.source.id === item.source.id
                            ? { ...row, quantity: event.target.value }
                            : row,
                        ),
                      )
                    }
                  />
                </Field>
                <Field label="Harga per satuan">
                  <input
                    className="field"
                    type="number"
                    min="0"
                    value={item.price}
                    onChange={(event) =>
                      setForm((all) =>
                        all.map((row) =>
                          row.source.id === item.source.id
                            ? { ...row, price: event.target.value }
                            : row,
                        ),
                      )
                    }
                  />
                </Field>
              </div>
            ))}
          </div>
          <div className="mt-4">
            <Field label="Catatan (opsional)">
              <textarea
                className="field min-h-20"
                value={notes}
                onChange={(event) => setNotes(event.target.value)}
              />
            </Field>
          </div>
        </div>
        <footer className="flex flex-wrap justify-end gap-3 border-t p-4">
          <button
            onClick={close}
            disabled={busy}
            className="rounded-xl border px-4 py-3 font-bold"
          >
            Batal
          </button>
          <button
            onClick={() => void save(false)}
            disabled={busy}
            className="rounded-xl border border-emerald-600 px-4 py-3 font-bold text-emerald-700"
          >
            Simpan Draft
          </button>
          {canPost && (
            <button
              onClick={() => void save(true)}
              disabled={busy}
              className="inline-flex items-center gap-2 rounded-xl bg-emerald-500 px-5 py-3 font-black text-white"
            >
              {busy ? (
                <Loader2 className="h-4 w-4 animate-spin" />
              ) : (
                <Send className="h-4 w-4" />
              )}
              Simpan & Konfirmasi
            </button>
          )}
        </footer>
      </section>
    </div>
  );
}
