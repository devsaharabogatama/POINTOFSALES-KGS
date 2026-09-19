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
  ArrowLeft,
  Ban,
  Boxes,
  CalendarDays,
  ChevronDown,
  FilePenLine,
  FilePlus2,
  Download,
  Loader2,
  RefreshCcw,
  RotateCcw,
  Save,
  Search,
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
  requested_total_base_qty?: number | string;
  requested_at?: string;
  master_version?: number;
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
  supplier_id: string | null;
  store_id: string | null;
  status: string;
  line_count: number;
  estimated_total: number | string;
  master_version: number;
  order_date: string;
  expected_date: string | null;
  notes?: string | null;
  destination_warehouse_id?: string | null;
  created_at?: string;
  order_source?: "MANUAL" | "DAILY_REPLENISHMENT";
  purchase_daily_batch_id?: string | null;
  supplier_assignment_status?: "ASSIGNED" | "SUPPLIER_PENDING";
};
type OrderLine = {
  id: string;
  document_id: string;
  line_no: number;
  product_id: string;
  client_line_key: string;
  ordered_uom_id: string;
  ordered_qty: number | string;
  factor_to_base_snapshot: number | string;
  ordered_base_qty: number | string;
  product_sku_snapshot: string;
  product_name_snapshot: string;
  ordered_uom_name_snapshot: string;
  estimated_unit_price: number | string;
  estimated_subtotal: number | string;
  source_warehouse_id: string | null;
  destination_warehouse_id: string | null;
  received_base_qty: number | string;
  remaining_base_qty: number | string;
  received_ordered_qty: number | string;
  remaining_ordered_qty: number | string;
  over_received_base_qty: number | string;
  receipt_progress: "NOT_RECEIVED" | "PARTIAL" | "COMPLETE";
  posted_receipt_count: number;
  last_received_at: string | null;
};
type ReturnReadiness = {
  canCancel: boolean;
  netReceivedBaseQty: number | string;
  draftReturnRows: number;
  draftBillRows: number;
  invalidPostedReturnFinanceRows: number;
  supplierRefundReceivable: number | string;
  blockers: string[];
};
type SupplierOrderActivity = {
  id: number | string;
  documentId: string;
  action: string;
  actorName: string;
  createdAt: string;
};
type Allocation = {
  supplier_order_line_id: string;
  stock_request_line_id: string;
  allocated_base_qty: number | string;
};
type BillStatus =
  | "NOT_READY"
  | "READY"
  | "DRAFT"
  | "HOLD"
  | "PARTIALLY_BILLED"
  | "BILLED";
type SupplierOrderBill = {
  id: string;
  invoice_no: string;
  supplier_invoice_no: string;
  invoice_date: string;
  due_date: string | null;
  status: "DRAFT" | "HOLD" | "VALIDATED";
  matching_status: string;
};
type SupplierOrderBillSummary = {
  supplierOrderId: string;
  billStatus: BillStatus;
  billableBaseQty: number | string;
  validatedBilledBaseQty: number | string;
  bills: SupplierOrderBill[];
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
type DailyBatch = {
  id: string;
  batch_no: string;
  business_date: string;
  mode_snapshot: "AUTO_RO" | "AUTO_PO";
  status: string;
  line_count: number;
  requested_total_base_qty: number | string;
  generated_by: string | null;
  generated_by_name?: string | null;
  master_version: number;
};
type DailyLine = {
  id: string;
  batch_id: string;
  product_id: string;
  warehouse_id: string;
  base_uom_id: string;
  requested_base_qty: number | string;
  suggested_product_supplier_id: string | null;
  destination_warehouse_id: string | null;
  product_sku_snapshot: string;
  product_name_snapshot: string;
  warehouse_name_snapshot: string;
  base_uom_name_snapshot: string;
  readiness_status: string;
  master_version: number;
};
type DailyRelation = {
  id: string;
  productId: string;
  supplierId: string;
  purchaseUomId: string;
  referencePurchasePrice: number | string | null;
  lastPurchasePrice: number | string | null;
  preferred: boolean;
};
type DailyUom = {
  productId: string;
  uomId: string;
  uomName: string;
  factorToBase: number | string;
  allowDecimal: boolean;
  decimalPrecision: number;
  purchasePrice: number | string | null;
};
type DailyWorkspace = {
  clientWorkspaceVersion?: number;
  batches?: DailyBatch[];
  lines?: DailyLine[];
  supplierOrders?: OrderDoc[];
  suppliers?: { id: string; supplierName: string }[];
  productSuppliers?: DailyRelation[];
  purchaseUoms?: DailyUom[];
  receivingWarehouses?: { id: string; name: string; storeId: string | null }[];
  defaultPurchaseReceiptWarehouseId?: string | null;
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
  supplierOrderReceiptProgressVersion?: number;
  supplierOrderListVersion?: number;
  supplierOrderBillSummaries?: SupplierOrderBillSummary[];
  supplierOrderActivity?: SupplierOrderActivity[];
  procurementWorkspaceVersion?: number;
  procurementDemands?: ProcurementDemand[];
  procurementDemandLines?: ProcurementDemandLine[];
  procurementAmendments?: ProcurementAmendment[];
  dailyWorkspace?: DailyWorkspace;
  error?: string;
};
type FormLine = {
  source: RequestLine;
  key: string;
  quantity: string;
  price: string;
  include: boolean;
};
type RoListRow = {
  key: string;
  number: string;
  source: "AUTO_RO" | "AUTO_PO" | "MANUAL" | "NEGATIVE_STOCK_SESSION_CLOSE";
  supplierLabel: string;
  documentDate: string | null;
  neededDate: string | null;
  status: string;
  itemCount: number;
  totalBaseQty: number;
  estimatedTotal: number | null;
  batch?: DailyBatch;
  request?: RequestDoc;
  relatedOrders: OrderDoc[];
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
    SUPPLIER_ORDER_RECEIPT_PROGRESS_CONTRACT_MISMATCH:
      "Runtime detail penerimaan Supplier Order belum lengkap. Jalankan migration read model lalu muat ulang.",
    PURCHASE_AUTO_RO_NOT_DRAFT: "RO ini tidak lagi berstatus Draft. Muat ulang daftar.",
    PURCHASE_AUTO_RO_DRAFT_REQUIRED: "Hanya RO Draft yang dapat dibatalkan.",
    PURCHASE_AUTO_RO_HAS_ACTIVE_PO: "RO sudah memiliki PO aktif dan tidak dapat dibatalkan langsung.",
    PURCHASE_AUTO_RO_ALL_LINES_REQUIRED: "Seluruh baris RO wajib ditentukan sebelum dikonfirmasi.",
    PURCHASE_AUTO_RO_LINE_VERSION_CONFLICT: "Baris RO berubah. Muat ulang sebelum melanjutkan.",
    PURCHASE_RECEIPT_WAREHOUSE_INVALID: "Gudang penerimaan tidak aktif atau tidak diizinkan menerima Purchase.",
    ACTIVE_PRODUCT_SUPPLIER_NOT_FOUND: "Relasi Product-Supplier sudah tidak aktif.",
    SUPPLIER_PENDING_MUST_USE_BASE_UOM: "Baris tanpa Supplier wajib memakai satuan dasar Product.",
    SUPPLIER_ORDER_NOT_CANCELABLE: "Status PO ini tidak dapat dibatalkan.",
    SUPPLIER_ORDER_RETURN_REQUIRED_BEFORE_CANCEL:
      "Barang yang sudah diterima wajib diretur seluruhnya sebelum PO dibatalkan.",
    SUPPLIER_ORDER_DRAFT_RETURN_REQUIRES_COMPLETION:
      "Masih ada Draft Retur untuk PO ini. Selesaikan atau batalkan Draft Retur terlebih dahulu.",
    SUPPLIER_ORDER_DRAFT_BILL_REQUIRES_CANCEL:
      "Masih ada Draft Bill untuk PO ini. Selesaikan atau batalkan Draft Bill terlebih dahulu.",
    SUPPLIER_ORDER_RETURN_FINANCE_RECONCILIATION_REQUIRED:
      "Koreksi stok dan Finance retur belum rekonsiliasi. Periksa dokumen Retur sebelum membatalkan PO.",
    PURCHASE_PO_PRE_RECEIPT_REVISION_NOT_ALLOWED:
      "PO ini tidak dapat direvisi pada status sekarang.",
    PURCHASE_PO_RECEIPT_ALREADY_STARTED:
      "PO tidak dapat direvisi karena proses penerimaan sudah dimulai.",
    PURCHASE_PO_BILL_ALREADY_STARTED:
      "PO tidak dapat direvisi karena proses Faktur Supplier sudah dimulai.",
    PURCHASE_PO_REVISION_ALL_LINES_REQUIRED:
      "Seluruh baris PO wajib tetap disertakan saat revisi.",
    PURCHASE_PO_SUPPLIER_GROUP_CONFLICT:
      "Supplier tersebut sudah mempunyai PO lain pada batch harian yang sama.",
    CUSTOM_PERMISSION_DENIED: "Akses Anda tidak mengizinkan tindakan ini.",
  };
  return map[code ?? ""] ?? code ?? "Operasi Supplier Order gagal.";
}
const quantity = (value: number | string) =>
  new Intl.NumberFormat("id-ID", { maximumFractionDigits: 6 }).format(
    Number(value) || 0,
  );
const dateText = (value?: string | null) => {
  if (!value) return "Belum ditentukan";
  const date = new Date(`${value.slice(0, 10)}T00:00:00`);
  return Number.isNaN(date.getTime())
    ? value
    : new Intl.DateTimeFormat("id-ID", {
        day: "numeric",
        month: "short",
        year: "numeric",
      }).format(date);
};
const billLabel: Record<BillStatus, string> = {
  NOT_READY: "Belum siap",
  READY: "Siap dibuat",
  DRAFT: "Draft Bill",
  HOLD: "Perlu review",
  PARTIALLY_BILLED: "Ditagih sebagian",
  BILLED: "Sudah ditagih",
};
const billClass: Record<BillStatus, string> = {
  NOT_READY: "bg-slate-100 text-slate-600",
  READY: "bg-blue-50 text-blue-700",
  DRAFT: "bg-amber-50 text-amber-800",
  HOLD: "bg-rose-50 text-rose-700",
  PARTIALLY_BILLED: "bg-violet-50 text-violet-700",
  BILLED: "bg-emerald-50 text-emerald-700",
};
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
function receiptProgressLabel(value: OrderLine["receipt_progress"]) {
  return ({
    NOT_RECEIVED: "Belum diterima",
    PARTIAL: "Diterima sebagian",
    COMPLETE: "Selesai diterima",
  } as const)[value];
}

function purchaseReceiptStatus(order: OrderDoc, lines: OrderLine[]) {
  if (order.status === "CANCELED") return "CANCELED";
  if (lines.length > 0 && lines.every((line) => line.receipt_progress === "COMPLETE"))
    return "COMPLETE";
  if (lines.some((line) => line.receipt_progress !== "NOT_RECEIVED"))
    return "PARTIAL";
  return "NOT_RECEIVED";
}

const receiptStatusLabel: Record<string, string> = {
  CANCELED: "Dibatalkan",
  COMPLETE: "Selesai",
  PARTIAL: "Diterima sebagian",
  NOT_RECEIVED: "Belum diterima",
};

const receiptStatusClass: Record<string, string> = {
  CANCELED: "bg-rose-50 text-rose-700",
  COMPLETE: "bg-emerald-50 text-emerald-700",
  PARTIAL: "bg-amber-50 text-amber-800",
  NOT_RECEIVED: "bg-slate-100 text-slate-600",
};

export function SupplierOrderView({
  session,
  companyId,
  canCreate,
  canPost,
  canExport,
  canCancel,
  canEdit,
  canOpenSupplierInvoices,
  openSupplierInvoices,
  canOpenPurchaseReturns,
  openPurchaseReturn,
  notify,
}: {
  session: Session;
  companyId: string;
  canCreate: boolean;
  canPost: boolean;
  canExport: boolean;
  canCancel: boolean;
  canEdit: boolean;
  canOpenSupplierInvoices: boolean;
  openSupplierInvoices: (input: {
    invoiceIds: string[];
    supplierId: string | null;
    create: boolean;
  }) => void;
  canOpenPurchaseReturns: boolean;
  openPurchaseReturn: (supplierOrderId: string) => void;
  notify: (value: string) => void;
}) {
  const [payload, setPayload] = useState<Payload>({}),
    [loading, setLoading] = useState(true),
    [error, setError] = useState(""),
    [activeTab, setActiveTab] = useState<"RO" | "PO">("RO"),
    [selected, setSelected] = useState<RequestDoc | null>(null),
    [selectedDailyBatch, setSelectedDailyBatch] = useState<DailyBatch | null>(null),
    [selectedPurchaseOrder, setSelectedPurchaseOrder] = useState<OrderDoc | null>(null),
    [cancelTarget, setCancelTarget] = useState<
      { kind: "RO"; document: DailyBatch } | { kind: "PO"; document: OrderDoc } | null
    >(null),
    [exporting, setExporting] = useState(false),
    [exportStatus, setExportStatus] = useState('ALL'),
    [exportSupplier, setExportSupplier] = useState(''),
    [exportStore, setExportStore] = useState(''),
    [selectedOrderIds, setSelectedOrderIds] = useState<Set<string>>(new Set());
  const [search, setSearch] = useState("");
  const [roStatus, setRoStatus] = useState("ALL");
  const [billStatus, setBillStatus] = useState("ALL");
  const [dateBasis, setDateBasis] = useState<"DOCUMENT" | "EXPECTED">("DOCUMENT");
  const [dateFrom, setDateFrom] = useState("");
  const [dateTo, setDateTo] = useState("");
  const [returnReadiness, setReturnReadiness] = useState<ReturnReadiness | null>(null);
  const [readinessLoading, setReadinessLoading] = useState(false);
  const load = useCallback(async () => {
    const response = await fetch("/api/purchase/supplier-orders", {
      headers: headers(session),
    });
    const body = (await response.json()) as Payload;
    if (!response.ok) throw new Error(friendly(body.error));
    if (body.procurementWorkspaceVersion !== 1) {
      throw new Error(friendly("PROCUREMENT_WORKSPACE_CONTRACT_MISMATCH"));
    }
    if (body.supplierOrderReceiptProgressVersion !== 1) {
      throw new Error(friendly("SUPPLIER_ORDER_RECEIPT_PROGRESS_CONTRACT_MISMATCH"));
    }
    if (body.supplierOrderListVersion !== 3) {
      throw new Error("Runtime daftar RO/PO belum lengkap. Jalankan migration Purchase list parity lalu muat ulang.");
    }
    if (body.dailyWorkspace?.clientWorkspaceVersion !== 1) {
      throw new Error("Runtime workspace RO/PO belum lengkap. Jalankan migration Step 6/6C lalu muat ulang.");
    }
    setPayload(body);
    return body;
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
  const cancelDocument = useCallback(async (reason: string) => {
    if (!cancelTarget) return;
    const isRo = cancelTarget.kind === "RO";
    const document = cancelTarget.document;
    setLoading(true);
    setError("");
    try {
      const response = await fetch(
        isRo
          ? `/api/purchase/daily-replenishment/${document.id}/cancel`
          : `/api/purchase/supplier-orders/${document.id}/cancel`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json", ...headers(session) },
          body: JSON.stringify({
            masterVersion: document.master_version,
            idempotencyKey: crypto.randomUUID(),
            reason: reason || null,
          }),
        },
      );
      const result = (await response.json()) as { error?: string };
      if (!response.ok) throw new Error(friendly(result.error));
      notify(`${isRo ? (document as DailyBatch).batch_no : (document as OrderDoc).order_no} berhasil dibatalkan.`);
      setCancelTarget(null);
      await load();
    } catch (reasonValue) {
      setError(reasonValue instanceof Error ? reasonValue.message : "Gagal membatalkan dokumen.");
    } finally {
      setLoading(false);
    }
  }, [cancelTarget, load, notify, session]);
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- workspace data follows the active Company
    void refresh();
  }, [companyId, refresh]);
  useEffect(() => {
    if (!cancelTarget || cancelTarget.kind !== "PO") {
      // eslint-disable-next-line react-hooks/set-state-in-effect -- clear readiness when dialog target changes
      setReturnReadiness(null);
      // eslint-disable-next-line react-hooks/set-state-in-effect -- clear loading flag with target
      setReadinessLoading(false);
      return;
    }
    let canceled = false;
    // eslint-disable-next-line react-hooks/set-state-in-effect -- begin async readiness fetch for selected PO
    setReadinessLoading(true);
    fetch(`/api/purchase/supplier-orders/${cancelTarget.document.id}/return-readiness`, {
      headers: headers(session),
    })
      .then(async (response) => {
        const body = (await response.json()) as { data?: ReturnReadiness; error?: string };
        if (!response.ok) throw new Error(friendly(body.error));
        if (!canceled) setReturnReadiness(body.data ?? null);
      })
      .catch((reason) => {
        if (!canceled)
          setError(reason instanceof Error ? reason.message : "Gagal memeriksa kesiapan pembatalan PO.");
      })
      .finally(() => {
        if (!canceled) setReadinessLoading(false);
      });
    return () => {
      canceled = true;
    };
  }, [cancelTarget, session]);
  const stores = useMemo(
    () => new Map((payload.stores ?? []).map((v) => [v.id, v.store_name])),
    [payload.stores],
  );
  const suppliers = useMemo(
    () =>
      new Map((payload.suppliers ?? []).map((v) => [v.id, v.supplier_name])),
    [payload.suppliers],
  );
  const orders = useMemo(() => {
    const dailyById = new Map(
      (payload.dailyWorkspace?.supplierOrders ?? []).map((order) => [order.id, order]),
    );
    return (payload.orders ?? []).map((order) => ({
      ...order,
      ...(dailyById.get(order.id) ?? {}),
    }));
  }, [payload.dailyWorkspace?.supplierOrders, payload.orders]);
  const orderLinesByOrder = useMemo(() => {
    const grouped = new Map<string, OrderLine[]>();
    for (const line of payload.orderLines ?? []) {
      const rows = grouped.get(line.document_id) ?? [];
      rows.push(line);
      grouped.set(line.document_id, rows);
    }
    return grouped;
  }, [payload.orderLines]);
  const remainingLines = useMemo(() => {
    const activeOrderIds = new Set(
      orders
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
    orders,
    payload.requestLines,
  ]);
  const visibleRequests = useMemo(() => {
    const ids = new Set(remainingLines.map((line) => line.document_id));
    return (payload.requests ?? []).filter((request) => ids.has(request.id));
  }, [payload.requests, remainingLines]);
  const billSummaries = useMemo(
    () => new Map((payload.supplierOrderBillSummaries ?? []).map((row) => [row.supplierOrderId, row])),
    [payload.supplierOrderBillSummaries],
  );
  const dateMatches = useCallback((value: string | null | undefined) => {
    if (!value) return !dateFrom && !dateTo;
    const date = value.slice(0, 10);
    return (!dateFrom || date >= dateFrom) && (!dateTo || date <= dateTo);
  }, [dateFrom, dateTo]);
  const filteredOrders = useMemo(() => {
    const query = search.trim().toLocaleLowerCase("id-ID");
    return orders.filter((order) => {
      const supplierName = order.supplier_id ? suppliers.get(order.supplier_id) ?? "" : "Supplier belum ditentukan";
      const summary = billSummaries.get(order.id);
      const selectedDate = dateBasis === "EXPECTED" ? order.expected_date : order.order_date;
      return (!query || `${order.order_no} ${supplierName}`.toLocaleLowerCase("id-ID").includes(query))
        && (exportStatus === "ALL" || order.status === exportStatus)
        && (billStatus === "ALL" || (summary?.billStatus ?? "NOT_READY") === billStatus)
        && (!exportSupplier || order.supplier_id === exportSupplier)
        && (!exportStore || order.store_id === exportStore)
        && dateMatches(selectedDate);
    });
  }, [billStatus, billSummaries, dateBasis, dateMatches, exportStatus, exportStore, exportSupplier, orders, search, suppliers]);
  const roRows = useMemo<RoListRow[]>(() => {
    const supplierNames = new Map((payload.dailyWorkspace?.suppliers ?? []).map((row) => [row.id, row.supplierName]));
    const relationSupplier = new Map((payload.dailyWorkspace?.productSuppliers ?? []).map((row) => [row.id, row.supplierId]));
    const dailyRows = (payload.dailyWorkspace?.batches ?? [])
      .filter((batch) => batch.mode_snapshot === "AUTO_RO")
      .map((batch): RoListRow => {
        const batchLines = (payload.dailyWorkspace?.lines ?? []).filter((line) => line.batch_id === batch.id);
        const relatedOrders = orders.filter((order) => order.purchase_daily_batch_id === batch.id);
        const exactSupplierIds = new Set(relatedOrders.map((order) => order.supplier_id).filter((id): id is string => Boolean(id)));
        if (relatedOrders.length === 0) {
          for (const line of batchLines) {
            const supplierId = line.suggested_product_supplier_id
              ? relationSupplier.get(line.suggested_product_supplier_id)
              : null;
            if (supplierId) exactSupplierIds.add(supplierId);
          }
        }
        const hasPendingSupplier = relatedOrders.length > 0
          ? relatedOrders.some((order) => !order.supplier_id)
          : batchLines.some((line) => !line.suggested_product_supplier_id);
        const names = [...exactSupplierIds].map((id) => supplierNames.get(id) ?? suppliers.get(id) ?? "Supplier");
        const supplierLabel = names.length === 0
          ? "Belum ditentukan"
          : names.length === 1 && !hasPendingSupplier
            ? names[0]
            : `${names.length} Supplier${hasPendingSupplier ? " · ada yang belum ditentukan" : ""}`;
        return {
          key: `daily-${batch.id}`,
          number: batch.batch_no,
          source: "AUTO_RO",
          supplierLabel,
          documentDate: batch.business_date,
          neededDate: batch.business_date,
          status: batch.status === "DRAFT" ? "DRAFT" : batch.status === "CANCELED" ? "CANCELED" : "ORDERED",
          itemCount: batchLines.length,
          totalBaseQty: Number(batch.requested_total_base_qty),
          estimatedTotal: relatedOrders.length > 0
            ? relatedOrders.reduce((total, order) => total + Number(order.estimated_total), 0)
            : null,
          batch,
          relatedOrders,
        };
      });
    const requestRows = visibleRequests.map((request): RoListRow => {
      const lines = remainingLines.filter((line) => line.document_id === request.id);
      return {
        key: `request-${request.id}`,
        number: request.request_no,
        source: request.request_source,
        supplierLabel: "Belum ditentukan",
        documentDate: request.requested_at ?? null,
        neededDate: request.needed_date,
        status: request.status === "ORDERED" ? "PARTIALLY_ORDERED" : "DRAFT",
        itemCount: lines.length,
        totalBaseQty: lines.reduce((total, line) => total + Number(line.remaining_base_qty), 0),
        estimatedTotal: null,
        request,
        relatedOrders: [],
      };
    });
    const query = search.trim().toLocaleLowerCase("id-ID");
    return [...dailyRows, ...requestRows]
      .filter((row) => (!query || `${row.number} ${row.supplierLabel}`.toLocaleLowerCase("id-ID").includes(query))
        && (roStatus === "ALL" || row.status === roStatus)
        && dateMatches(dateBasis === "EXPECTED" ? row.neededDate : row.documentDate))
      .sort((left, right) => (right.documentDate ?? "").localeCompare(left.documentDate ?? "") || right.number.localeCompare(left.number));
  }, [dateBasis, dateMatches, orders, payload.dailyWorkspace?.batches, payload.dailyWorkspace?.lines, payload.dailyWorkspace?.productSuppliers, payload.dailyWorkspace?.suppliers, remainingLines, roStatus, search, suppliers, visibleRequests]);
  const batchNumbers = useMemo(
    () => new Map((payload.dailyWorkspace?.batches ?? []).map((batch) => [batch.id, batch.batch_no])),
    [payload.dailyWorkspace?.batches],
  );
  const allFilteredSelected = filteredOrders.length > 0 &&
    filteredOrders.every((order) => selectedOrderIds.has(order.id));
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
  if (selectedPurchaseOrder) {
    const currentOrder = orders.find((order) => order.id === selectedPurchaseOrder.id)
      ?? selectedPurchaseOrder;
    const currentLines = orderLinesByOrder.get(currentOrder.id) ?? [];
    const currentSummary = billSummaries.get(currentOrder.id) ?? {
      supplierOrderId: currentOrder.id,
      billStatus: "NOT_READY" as BillStatus,
      billableBaseQty: 0,
      validatedBilledBaseQty: 0,
      bills: [],
    };
    return <PurchaseOrderDocument
      order={currentOrder}
      lines={currentLines}
      suppliers={payload.dailyWorkspace?.suppliers ?? []}
      uoms={payload.dailyWorkspace?.purchaseUoms ?? []}
      warehouses={payload.dailyWorkspace?.receivingWarehouses ?? []}
      defaultWarehouseId={payload.dailyWorkspace?.defaultPurchaseReceiptWarehouseId ?? null}
      activity={(payload.supplierOrderActivity ?? []).filter((row) => row.documentId === currentOrder.id)}
      billSummary={currentSummary}
      session={session}
      canEdit={canEdit}
      canCancel={canCancel}
      canOpenSupplierInvoices={canOpenSupplierInvoices}
      canOpenPurchaseReturns={canOpenPurchaseReturns}
      close={() => setSelectedPurchaseOrder(null)}
      openBill={() => openSupplierInvoices({
        invoiceIds: currentSummary.bills.map((bill) => bill.id),
        supplierId: currentOrder.supplier_id,
        create: currentSummary.billStatus === "READY",
      })}
      openReturn={() => openPurchaseReturn(currentOrder.id)}
      cancel={() => {
        setSelectedPurchaseOrder(null);
        setCancelTarget({ kind: "PO", document: currentOrder });
      }}
      complete={async (message) => {
        notify(message);
        const next = await load();
        const nextDaily = new Map((next.dailyWorkspace?.supplierOrders ?? []).map((order) => [order.id, order]));
        const nextOrder = (next.orders ?? []).find((order) => order.id === currentOrder.id);
        if (nextOrder) setSelectedPurchaseOrder({ ...nextOrder, ...(nextDaily.get(nextOrder.id) ?? {}) });
      }}
    />;
  }
  return (
    <>
      <div className="mb-5 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <p className="text-xs font-bold uppercase tracking-[.16em] text-emerald-600">
            Purchase
          </p>
          <h1 className="mt-2 text-3xl font-black">Request Order & Purchase Order</h1>
          <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-500">Buat atau tinjau Request Order, konfirmasi menjadi Purchase Order, lalu pantau penerimaan dan Faktur Supplier.</p>
        </div>
        <div className="flex flex-wrap gap-2">{canExport && <button onClick={() => void exportOrders()} disabled={exporting || selectedOrderIds.size===0} className="inline-flex items-center gap-2 rounded-xl bg-emerald-600 px-4 py-3 text-sm font-bold text-white disabled:cursor-not-allowed disabled:opacity-40"><Download className="h-4 w-4"/>{exporting ? 'Menyiapkan...' : `Export PO Terpilih (${selectedOrderIds.size})`}</button>}<button onClick={() => void refresh()} className="inline-flex items-center gap-2 rounded-xl border bg-white px-4 py-3 text-sm font-bold"><RefreshCcw className={`h-4 w-4 ${loading ? "animate-spin" : ""}`} />Muat ulang</button></div>
      </div>
      <div className="flex gap-2 border-b border-slate-200">
        {(["RO", "PO"] as const).map((tab) => <button key={tab} onClick={() => setActiveTab(tab)} className={`border-b-2 px-5 py-3 text-sm font-black ${activeTab === tab ? "border-emerald-600 text-emerald-700" : "border-transparent text-slate-500"}`}>{tab === "RO" ? "Request Order" : "Purchase Order"}</button>)}
      </div>
      <div className={`mb-5 mt-5 grid gap-3 ${activeTab === "PO" ? "xl:grid-cols-[minmax(220px,1fr)_155px_165px_165px_145px_155px_140px_140px_auto]" : "xl:grid-cols-[minmax(260px,1fr)_190px_170px_150px_150px_auto]"}`}>
        <label className="relative"><Search className="absolute left-3 top-3 h-5 w-5 text-slate-400"/><input value={search} onChange={(event) => setSearch(event.target.value)} placeholder={`Cari nomor ${activeTab === "RO" ? "RO" : "PO"} atau Supplier`} className="w-full rounded-xl border border-slate-200 py-2.5 pl-10 pr-3"/></label>
        {activeTab === "RO" ? <select aria-label="Status Request Order" value={roStatus} onChange={(event) => setRoStatus(event.target.value)} className="rounded-xl border border-slate-200 px-3"><option value="ALL">Semua status RO</option><option value="DRAFT">Draft</option><option value="PARTIALLY_ORDERED">Sebagian jadi PO</option><option value="ORDERED">Sudah jadi PO</option><option value="CANCELED">Dibatalkan</option></select> : <><select aria-label="Status Purchase Order" value={exportStatus} onChange={(event) => { setExportStatus(event.target.value); setSelectedOrderIds(new Set()); }} className="rounded-xl border border-slate-200 px-3"><option value="ALL">Semua status PO</option>{["DRAFT","CONFIRMED","PARTIALLY_RECEIVED","RECEIVED","CANCELED"].map((value) => <option key={value}>{value}</option>)}</select><select aria-label="Status Bill" value={billStatus} onChange={(event) => setBillStatus(event.target.value)} className="rounded-xl border border-slate-200 px-3"><option value="ALL">Semua status Bill</option>{(Object.keys(billLabel) as BillStatus[]).map((value) => <option key={value} value={value}>{billLabel[value]}</option>)}</select><select aria-label="Supplier" value={exportSupplier} onChange={(event) => { setExportSupplier(event.target.value); setSelectedOrderIds(new Set()); }} className="rounded-xl border border-slate-200 px-3"><option value="">Semua Supplier</option>{(payload.suppliers ?? []).map((item) => <option key={item.id} value={item.id}>{item.supplier_name}</option>)}</select><select aria-label="Toko" value={exportStore} onChange={(event) => { setExportStore(event.target.value); setSelectedOrderIds(new Set()); }} className="rounded-xl border border-slate-200 px-3"><option value="">Semua Toko</option>{(payload.stores ?? []).map((item) => <option key={item.id} value={item.id}>{item.store_name}</option>)}</select></>}
        <select aria-label="Jenis tanggal" value={dateBasis} onChange={(event) => setDateBasis(event.target.value as "DOCUMENT" | "EXPECTED")} className="rounded-xl border border-slate-200 px-3"><option value="DOCUMENT">Tanggal {activeTab === "RO" ? "RO" : "PO"}</option><option value="EXPECTED">{activeTab === "RO" ? "Tanggal kebutuhan" : "Rencana terima"}</option></select>
        <input aria-label="Tanggal mulai" type="date" value={dateFrom} onChange={(event) => setDateFrom(event.target.value)} className="rounded-xl border border-slate-200 px-3"/>
        <input aria-label="Tanggal akhir" type="date" min={dateFrom || undefined} value={dateTo} onChange={(event) => setDateTo(event.target.value)} className="rounded-xl border border-slate-200 px-3"/>
        <button onClick={() => void refresh()} className="inline-flex items-center justify-center gap-2 rounded-xl border border-slate-200 px-4 py-2.5 font-bold"><RefreshCcw className={`h-4 w-4 ${loading ? "animate-spin" : ""}`}/>Muat ulang</button>
      </div>
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
      {activeTab === "RO" && <section className="overflow-hidden rounded-[24px] border border-slate-200 bg-white shadow-sm">
        <div className="overflow-x-auto"><table className="w-full min-w-[980px] table-fixed text-left text-sm">
          <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500"><tr><th className="w-[22%] px-5 py-4">Nomor RO</th><th className="w-[22%] px-5 py-4">Supplier Rencana</th><th className="w-[19%] px-5 py-4">Tanggal RO</th><th className="w-[17%] px-5 py-4">Status RO</th><th className="w-[20%] px-5 py-4 text-right">Estimasi Total</th></tr></thead>
          <tbody className="divide-y divide-slate-100">
            {!loading && roRows.length === 0 && <tr><td colSpan={5} className="px-5 py-14 text-center text-slate-500">Belum ada Request Order pada filter ini.</td></tr>}
            {roRows.map((row) => {
              const statusLabel = row.status === "DRAFT" ? "Draft" : row.status === "PARTIALLY_ORDERED" ? "Sebagian jadi PO" : row.status === "ORDERED" ? "Sudah jadi PO" : "Dibatalkan";
              const statusClass = row.status === "DRAFT" ? "bg-amber-50 text-amber-800" : row.status === "CANCELED" ? "bg-rose-50 text-rose-700" : row.status === "PARTIALLY_ORDERED" ? "bg-blue-50 text-blue-700" : "bg-emerald-50 text-emerald-700";
              return <tr key={row.key} className="align-top hover:bg-slate-50">
                <td className="px-5 py-4"><div className="font-black">{row.number}</div><div className="mt-1 text-xs text-slate-500">{row.source === "AUTO_RO" ? "Otomatis · stok minus harian" : row.source === "NEGATIVE_STOCK_SESSION_CLOSE" ? "Otomatis · kekurangan sesi" : "Manual"}</div><div className="mt-1 text-xs text-slate-500">{row.itemCount} barang · {quantity(row.totalBaseQty)} base qty</div></td>
                <td className="px-5 py-4"><div className="font-bold">{row.supplierLabel}</div>{row.relatedOrders.length > 0 && <div className="mt-1 text-xs text-slate-500">{row.relatedOrders.length} PO terhubung</div>}</td>
                <td className="px-5 py-4"><div>{dateText(row.documentDate)}</div>{row.neededDate && row.neededDate !== row.documentDate && <div className="mt-1 text-xs text-slate-500">Dibutuhkan {dateText(row.neededDate)}</div>}</td>
                <td className="px-5 py-4"><span className={`rounded-full px-2.5 py-1 text-xs font-bold ${statusClass}`}>{statusLabel}</span><div className="mt-3 flex flex-wrap gap-2">{row.batch?.status === "DRAFT" && canPost && <button onClick={() => setSelectedDailyBatch(row.batch!)} className="rounded-lg bg-emerald-600 px-3 py-2 text-xs font-black text-white">Konfirmasi jadi PO</button>}{row.request && canCreate && <button onClick={() => setSelected(row.request!)} className="rounded-lg bg-emerald-600 px-3 py-2 text-xs font-black text-white">Buat PO</button>}{row.batch?.status === "DRAFT" && canCancel && <button onClick={() => setCancelTarget({ kind: "RO", document: row.batch! })} className="rounded-lg border border-rose-300 px-3 py-2 text-xs font-black text-rose-700">Batalkan</button>}</div></td>
                <td className="px-5 py-4 text-right"><div className="font-black">{row.estimatedTotal === null ? "Belum dihitung" : money(row.estimatedTotal)}</div>{row.estimatedTotal === null && <div className="mt-1 text-xs text-slate-500">Final saat Supplier dan harga dipilih</div>}</td>
              </tr>;
            })}
          </tbody>
        </table></div>
      </section>}
      {activeTab === "PO" && <section className="overflow-hidden rounded-[24px] border border-slate-200 bg-white shadow-sm">
        {canExport && filteredOrders.length > 0 && <label className="flex min-h-11 cursor-pointer items-center gap-3 border-b border-slate-200 bg-slate-50 px-5 text-sm font-bold text-slate-700"><input type="checkbox" checked={allFilteredSelected} onChange={toggleAllFiltered} className="h-5 w-5 rounded border-slate-300 accent-emerald-600"/><span>Pilih semua hasil filter ({filteredOrders.length})</span><span className="ml-auto text-xs text-slate-500">Terpilih {selectedOrderIds.size}/100</span></label>}
        <div className="overflow-x-auto"><table className="w-full min-w-[1160px] table-fixed text-left text-sm">
          <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500"><tr><th className="w-[21%] px-5 py-4">Nomor PO</th><th className="w-[19%] px-5 py-4">Supplier</th><th className="w-[20%] px-5 py-4">Tanggal PO</th><th className="w-[15%] px-5 py-4">Status Penerimaan</th><th className="w-[15%] px-5 py-4">Status Bill</th><th className="w-[10%] px-5 py-4 text-right">Total</th></tr></thead>
          <tbody className="divide-y divide-slate-100">
            {!loading && filteredOrders.length === 0 && <tr><td colSpan={6} className="px-5 py-14 text-center text-slate-500">Belum ada Purchase Order pada filter ini.</td></tr>}
            {filteredOrders.map((order) => {
              const detailLines = orderLinesByOrder.get(order.id) ?? [];
              const receiptStatus = purchaseReceiptStatus(order, detailLines);
              const summary = billSummaries.get(order.id) ?? { supplierOrderId: order.id, billStatus: "NOT_READY" as BillStatus, billableBaseQty: 0, validatedBilledBaseQty: 0, bills: [] };
              const billCanOpen = canOpenSupplierInvoices && (summary.billStatus === "READY" || summary.bills.length > 0);
              return <tr key={order.id} onClick={() => setSelectedPurchaseOrder(order)} className="cursor-pointer align-top hover:bg-slate-50">
                  <td className="px-5 py-4"><div className="flex items-start gap-3">{canExport && <input type="checkbox" aria-label={`Pilih ${order.order_no}`} checked={selectedOrderIds.has(order.id)} onClick={(event) => event.stopPropagation()} onChange={() => toggleOrder(order.id)} className="mt-0.5 h-5 w-5 shrink-0 rounded border-slate-300 accent-emerald-600"/>}<div><div className="font-black">{order.order_no}</div>{order.purchase_daily_batch_id && <div className="mt-1 text-xs text-slate-500">Asal {batchNumbers.get(order.purchase_daily_batch_id) ?? "RO harian"}</div>}<div className="mt-1 text-xs text-slate-500">{order.status}</div></div></div></td>
                  <td className="px-5 py-4"><div className="font-bold">{(order.supplier_id ? suppliers.get(order.supplier_id) : null) ?? "Supplier belum ditentukan"}</div><div className="mt-1 text-xs text-slate-500">{order.line_count} barang</div></td>
                  <td className="px-5 py-4"><div>{dateText(order.order_date)}</div><div className="mt-1 text-xs text-slate-500">Rencana terima {dateText(order.expected_date)}</div></td>
                  <td className="px-5 py-4"><span className={`rounded-full px-2.5 py-1 text-xs font-bold ${receiptStatusClass[receiptStatus]}`}>{receiptStatusLabel[receiptStatus]}</span></td>
                  <td className="px-5 py-4"><button type="button" disabled={!billCanOpen} onClick={(event) => { event.stopPropagation(); if (!billCanOpen) return; openSupplierInvoices({ invoiceIds: summary.bills.map((bill) => bill.id), supplierId: order.supplier_id, create: summary.billStatus === "READY" }); }} className={`rounded-full px-2.5 py-1 text-xs font-bold ${billClass[summary.billStatus]} disabled:cursor-default`}>{billLabel[summary.billStatus]}</button>{summary.bills.length > 1 && <div className="mt-1 text-xs text-slate-500">{summary.bills.length} Faktur terhubung</div>}</td>
                  <td className="px-5 py-4 text-right font-black">{money(order.estimated_total)}</td>
                </tr>;
            })}
          </tbody>
        </table></div>
      </section>}
      {false && activeTab === "RO" && <DailyRoList
        batches={payload.dailyWorkspace?.batches ?? []}
        lines={payload.dailyWorkspace?.lines ?? []}
        canPost={canPost}
        canCancel={canCancel}
        open={setSelectedDailyBatch}
        cancel={(batch) => setCancelTarget({ kind: "RO", document: batch })}
      />}
      {false && activeTab === "RO" && <section className="mb-6 rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
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
      </section>}
      <div className="grid gap-6">
        {false && activeTab === "RO" && <List title="Permintaan menunggu order">
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
        </List>}
        {false && activeTab === "PO" && <List title="Riwayat Supplier Order">
          {canExport && filteredOrders.length>0 && <label className="mb-3 flex min-h-11 cursor-pointer items-center gap-3 rounded-xl border border-slate-200 bg-slate-50 px-4 text-sm font-bold text-slate-700"><input type="checkbox" checked={allFilteredSelected} onChange={toggleAllFiltered} className="h-5 w-5 rounded border-slate-300 accent-emerald-600"/><span>Pilih semua hasil filter ({filteredOrders.length})</span><span className="ml-auto text-xs text-slate-500">Terpilih {selectedOrderIds.size}/100</span></label>}
          {filteredOrders.length === 0 ? (
            <Empty text="Tidak ada Supplier Order yang sesuai filter." />
          ) : (
            filteredOrders.map((order) => {
              const detailLines = orderLinesByOrder.get(order.id) ?? [];
              const expanded = false;
              const completedLines = detailLines.filter(
                (line) => line.receipt_progress === "COMPLETE",
              ).length;
              return <article
                key={order.id}
                className="rounded-2xl border bg-white p-5 shadow-sm"
              >
                <div className="flex items-start gap-3">
                  {canExport && <input type="checkbox" aria-label={`Pilih ${order.order_no}`} checked={selectedOrderIds.has(order.id)} onChange={() => toggleOrder(order.id)} className="mt-1 h-5 w-5 shrink-0 rounded border-slate-300 accent-emerald-600"/>}
                  <ShoppingCart className="mt-1 h-5 w-5 text-slate-500" />
                  <div className="flex-1">
                    <p className="font-black">{order.order_no}</p>
                    <p className="mt-1 text-sm text-slate-500">
                      {(order.supplier_id ? suppliers.get(order.supplier_id) : null) ?? "Supplier belum ditentukan"} ·{" "}
                      {order.line_count} barang · {money(order.estimated_total)}
                    </p>
                  </div>
                  <span className="rounded-full bg-slate-100 px-3 py-1 text-xs font-bold">
                    {order.status}
                  </span>
                </div>
                <div className="mt-4 flex flex-wrap gap-2">
                  <button
                    type="button"
                    aria-expanded={expanded}
                    onClick={() => setSelectedPurchaseOrder(order)}
                    className="inline-flex min-h-10 items-center gap-2 rounded-xl border border-slate-300 px-4 text-sm font-black text-slate-700"
                  >
                    <ChevronDown className={`h-4 w-4 transition-transform ${expanded ? "rotate-180" : ""}`} />
                    {expanded ? "Tutup detail" : "Lihat detail barang"}
                  </button>
                {canPost && order.status === "DRAFT" && (
                  <button
                    onClick={() => void confirmExisting(order)}
                    disabled={loading}
                    className="inline-flex min-h-10 items-center gap-2 rounded-xl border border-emerald-600 px-4 text-sm font-black text-emerald-700"
                  >
                    <Send className="h-4 w-4" />
                    Konfirmasi Draft
                  </button>
                )}
                {canCancel && ["DRAFT", "CONFIRMED", "PARTIALLY_RECEIVED", "RECEIVED"].includes(order.status) && (
                  <button
                    onClick={() => setCancelTarget({ kind: "PO", document: order })}
                    disabled={loading}
                    className="inline-flex min-h-10 items-center gap-2 rounded-xl border border-rose-300 px-4 text-sm font-black text-rose-700"
                  >
                    <Ban className="h-4 w-4" />Batalkan PO
                  </button>
                )}
                </div>
                {expanded && <div className="mt-4 overflow-hidden rounded-xl border border-slate-200">
                  <div className="flex flex-wrap items-center justify-between gap-2 bg-slate-50 px-4 py-3 text-xs font-bold text-slate-600">
                    <span>{detailLines.length} barang dalam PO</span>
                    <span>{completedLines}/{detailLines.length} selesai diterima</span>
                  </div>
                  {detailLines.length === 0 ? <p className="p-5 text-sm text-slate-500">
                    Detail barang tidak ditemukan. Muat ulang setelah runtime read model diterapkan.
                  </p> : <div className="divide-y divide-slate-100">
                    {detailLines.map((line) => {
                      const progressClass = line.receipt_progress === "COMPLETE"
                        ? "bg-emerald-50 text-emerald-700"
                        : line.receipt_progress === "PARTIAL"
                          ? "bg-amber-50 text-amber-800"
                          : "bg-slate-100 text-slate-600";
                      return <div key={line.id} className="p-4">
                        <div className="flex flex-wrap items-start justify-between gap-2">
                          <div className="min-w-0">
                            <p className="font-black text-slate-900">{line.product_name_snapshot}</p>
                            <p className="mt-0.5 text-xs text-slate-500">
                              {line.product_sku_snapshot} · {line.ordered_uom_name_snapshot}
                            </p>
                          </div>
                          <span className={`rounded-full px-2.5 py-1 text-[11px] font-black ${progressClass}`}>
                            {receiptProgressLabel(line.receipt_progress)}
                          </span>
                        </div>
                        <dl className="mt-3 grid grid-cols-3 gap-2 text-sm">
                          <div className="rounded-lg bg-slate-50 p-2">
                            <dt className="text-[11px] font-bold uppercase text-slate-500">Dipesan</dt>
                            <dd className="mt-1 font-black">{quantity(line.ordered_qty)}</dd>
                          </div>
                          <div className="rounded-lg bg-emerald-50 p-2 text-emerald-800">
                            <dt className="text-[11px] font-bold uppercase">Diterima</dt>
                            <dd className="mt-1 font-black">{quantity(line.received_ordered_qty)}</dd>
                          </div>
                          <div className="rounded-lg bg-amber-50 p-2 text-amber-900">
                            <dt className="text-[11px] font-bold uppercase">Belum</dt>
                            <dd className="mt-1 font-black">{quantity(line.remaining_ordered_qty)}</dd>
                          </div>
                        </dl>
                        <p className="mt-2 text-xs text-slate-500">
                          Satuan {line.ordered_uom_name_snapshot}
                          {line.posted_receipt_count > 0 && ` · ${line.posted_receipt_count} penerimaan final`}
                          {Number(line.over_received_base_qty) > 0 && ` · Lebih terima ${quantity(line.over_received_base_qty)} base`}
                        </p>
                      </div>;
                    })}
                  </div>}
                </div>}
              </article>;
            })
          )}
        </List>}
      </div>
      {selectedDailyBatch && <DailyRoModal
        batch={selectedDailyBatch}
        lines={(payload.dailyWorkspace?.lines ?? []).filter((line) => line.batch_id === selectedDailyBatch.id)}
        suppliers={payload.dailyWorkspace?.suppliers ?? []}
        relations={payload.dailyWorkspace?.productSuppliers ?? []}
        uoms={payload.dailyWorkspace?.purchaseUoms ?? []}
        warehouses={payload.dailyWorkspace?.receivingWarehouses ?? []}
        session={session}
        close={() => setSelectedDailyBatch(null)}
        complete={async (message) => {
          setSelectedDailyBatch(null);
          notify(message);
          await refresh();
        }}
      />}
      {cancelTarget && <CancelPurchaseModal
        label={cancelTarget.kind === "RO" ? cancelTarget.document.batch_no : cancelTarget.document.order_no}
        busy={loading}
        readiness={cancelTarget.kind === "PO" ? returnReadiness : null}
        readinessLoading={cancelTarget.kind === "PO" && readinessLoading}
        close={() => setCancelTarget(null)}
        submit={cancelDocument}
      />}
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

type PurchaseOrderEditLine = {
  lineId: string;
  productId: string;
  uomId: string;
  quantity: string;
  estimatedUnitPrice: string;
  destinationWarehouseId: string;
};

function PurchaseOrderDocument({ order, lines, suppliers, uoms, warehouses,
  defaultWarehouseId, activity, billSummary, session, canEdit, canCancel,
  canOpenSupplierInvoices, canOpenPurchaseReturns, close, openBill, openReturn,
  cancel, complete }: {
  order: OrderDoc;
  lines: OrderLine[];
  suppliers: { id: string; supplierName: string }[];
  uoms: DailyUom[];
  warehouses: { id: string; name: string; storeId: string | null }[];
  defaultWarehouseId: string | null;
  activity: SupplierOrderActivity[];
  billSummary: SupplierOrderBillSummary;
  session: Session;
  canEdit: boolean;
  canCancel: boolean;
  canOpenSupplierInvoices: boolean;
  canOpenPurchaseReturns: boolean;
  close: () => void;
  openBill: () => void;
  openReturn: () => void;
  cancel: () => void;
  complete: (message: string) => Promise<void>;
}) {
  const [editing, setEditing] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [supplierId, setSupplierId] = useState(order.supplier_id ?? "");
  const [expectedDate, setExpectedDate] = useState(order.expected_date ?? "");
  const [notes, setNotes] = useState(order.notes ?? "");
  const [draftLines, setDraftLines] = useState<PurchaseOrderEditLine[]>(() =>
    lines.map((line) => ({
      lineId: line.id,
      productId: line.product_id,
      uomId: line.ordered_uom_id,
      quantity: String(line.ordered_qty),
      estimatedUnitPrice: String(line.estimated_unit_price),
      destinationWarehouseId: line.destination_warehouse_id ?? defaultWarehouseId ?? "",
    })),
  );
  const receiptStatus = purchaseReceiptStatus(order, lines);
  const canRevise = canEdit && order.order_source === "DAILY_REPLENISHMENT"
    && order.status === "CONFIRMED"
    && lines.length > 0
    && lines.every((line) => line.posted_receipt_count === 0);
  const canOpenBill = canOpenSupplierInvoices
    && (billSummary.billStatus === "READY" || billSummary.bills.length > 0);
  const canOpenReturn = canOpenPurchaseReturns && lines.some(
    (line) => line.posted_receipt_count > 0,
  ) && ["PARTIALLY_RECEIVED", "RECEIVED"].includes(order.status);
  const supplierName = suppliers.find((item) => item.id === order.supplier_id)?.supplierName
    ?? (order.supplier_id ? "Supplier" : "Supplier belum ditentukan");
  const estimatedTotal = draftLines.reduce((total, line) =>
    total + Number(line.quantity || 0) * Number(line.estimatedUnitPrice || 0), 0);
  function updateLine(lineId: string, patch: Partial<PurchaseOrderEditLine>) {
    setDraftLines((current) => current.map((line) =>
      line.lineId === lineId ? { ...line, ...patch } : line));
  }
  function resetForm() {
    setSupplierId(order.supplier_id ?? "");
    setExpectedDate(order.expected_date ?? "");
    setNotes(order.notes ?? "");
    setDraftLines(lines.map((line) => ({
      lineId: line.id, productId: line.product_id,
      uomId: line.ordered_uom_id, quantity: String(line.ordered_qty),
      estimatedUnitPrice: String(line.estimated_unit_price),
      destinationWarehouseId: line.destination_warehouse_id ?? defaultWarehouseId ?? "",
    })));
    setEditing(false); setError("");
  }
  async function save() {
    if (draftLines.some((line) => !line.uomId || !line.destinationWarehouseId
      || Number(line.quantity) <= 0 || Number(line.estimatedUnitPrice) < 0)) {
      setError("Lengkapi satuan, Qty, harga, dan Gudang penerimaan pada seluruh baris.");
      return;
    }
    setBusy(true); setError("");
    try {
      const response = await fetch(`/api/purchase/supplier-orders/${order.id}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json", ...headers(session) },
        body: JSON.stringify({ masterVersion: order.master_version,
          operationId: crypto.randomUUID(), supplierId: supplierId || null,
          expectedDate: expectedDate || null, notes: notes || null,
          lines: draftLines.map((line) => ({ ...line,
            quantity: Number(line.quantity),
            estimatedUnitPrice: Number(line.estimatedUnitPrice) })) }),
      });
      const result = await response.json() as { data?: { orderNo?: string }; error?: string };
      if (!response.ok) throw new Error(friendly(result.error));
      setEditing(false);
      await complete(`${order.order_no} berhasil direvisi.`);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Revisi PO gagal disimpan.");
    } finally { setBusy(false); }
  }
  return <div className="space-y-4">
    <header className="flex flex-wrap items-start justify-between gap-4 rounded-[24px] border border-slate-200 bg-white p-5 shadow-sm">
      <div className="flex items-start gap-3">
        <button onClick={close} className="rounded-xl border border-slate-200 p-2.5" aria-label="Kembali ke daftar PO"><ArrowLeft className="h-5 w-5"/></button>
        <div><p className="text-xs font-black uppercase tracking-[.18em] text-emerald-700">Purchase Order</p><h1 className="mt-1 text-3xl font-black">{order.order_no}</h1><p className="mt-1 text-sm text-slate-500">{order.purchase_daily_batch_id ? "PO otomatis harian" : "PO manual"} · versi {order.master_version}</p></div>
      </div>
      <div className="flex flex-wrap justify-end gap-2">
        {canRevise && !editing && <button onClick={() => setEditing(true)} className="inline-flex items-center gap-2 rounded-xl border border-slate-300 px-4 py-2.5 font-bold"><FilePenLine className="h-4 w-4"/>Edit PO</button>}
        {canOpenBill && !editing && <button onClick={openBill} className="inline-flex items-center gap-2 rounded-xl bg-blue-600 px-4 py-2.5 font-bold text-white"><FilePlus2 className="h-4 w-4"/>{billSummary.bills.length ? "Lihat Bill" : "Buat Bill"}</button>}
        {canOpenReturn && !editing && <button onClick={openReturn} className="inline-flex items-center gap-2 rounded-xl border border-amber-300 bg-amber-50 px-4 py-2.5 font-bold text-amber-800"><RotateCcw className="h-4 w-4"/>Retur ke Supplier</button>}
        {canCancel && !editing && ["DRAFT","CONFIRMED","PARTIALLY_RECEIVED","RECEIVED"].includes(order.status) && <button onClick={cancel} className="rounded-xl border border-rose-300 px-4 py-2.5 font-bold text-rose-700">Batalkan PO</button>}
      </div>
    </header>
    {error && <div className="rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-700">{error}</div>}
    <section className="overflow-hidden rounded-[24px] border border-slate-200 bg-white shadow-sm">
      <div className="grid gap-5 p-6 lg:grid-cols-[minmax(0,1.1fr)_minmax(380px,.9fr)]">
        <div className="rounded-xl border border-slate-200 p-4">
          <span className="text-sm font-bold text-slate-600">Supplier</span>
          {editing ? <select value={supplierId} onChange={(event) => setSupplierId(event.target.value)} className="mt-2 w-full rounded-xl border border-slate-300 p-3 font-bold"><option value="">Supplier belum ditentukan</option>{suppliers.map((supplier) => <option key={supplier.id} value={supplier.id}>{supplier.supplierName}</option>)}</select> : <><h2 className="mt-2 text-xl font-black">{supplierName}</h2><p className="mt-1 text-sm text-slate-500">{order.supplier_assignment_status === "ASSIGNED" ? "Supplier ditentukan" : "Dapat dilengkapi sebelum membuat Bill"}</p></>}
        </div>
        <div className="grid gap-4 rounded-xl border border-slate-200 p-4 sm:grid-cols-2">
          <div><span className="text-sm text-slate-500">Tanggal PO</span><strong className="block">{dateText(order.order_date)}</strong></div>
          <div><span className="text-sm text-slate-500">Rencana terima</span>{editing ? <input type="date" min={order.order_date} value={expectedDate} onChange={(event) => setExpectedDate(event.target.value)} className="mt-1 w-full rounded-lg border border-slate-300 p-2"/> : <strong className="block">{dateText(order.expected_date)}</strong>}</div>
          <div><span className="text-sm text-slate-500">Status penerimaan</span><strong className="block">{receiptStatusLabel[receiptStatus]}</strong></div>
          <div><span className="text-sm text-slate-500">Status Bill</span><strong className="block">{billLabel[billSummary.billStatus]}</strong></div>
        </div>
      </div>
      <div className="border-t border-slate-200"><div className="border-b border-slate-200 px-5 py-4 font-black">Order Lines</div><div className="overflow-x-auto"><table className="w-full min-w-[1040px] table-fixed text-sm"><thead className="bg-slate-50 text-left text-xs uppercase text-slate-500"><tr><th className="w-[28%] px-4 py-3">Product</th><th className="w-[12%] px-4 py-3">UOM</th><th className="w-[12%] px-4 py-3 text-right">Qty</th><th className="w-[18%] px-4 py-3 text-right">Harga</th><th className="w-[18%] px-4 py-3">Gudang terima</th><th className="w-[12%] px-4 py-3 text-right">Jumlah</th></tr></thead><tbody className="divide-y divide-slate-100">{lines.map((line) => { const draft = draftLines.find((item) => item.lineId === line.id)!; const productUoms = uoms.filter((item) => item.productId === line.product_id); const warehouseName = warehouses.find((item) => item.id === draft.destinationWarehouseId)?.name ?? "Belum ditentukan"; return <tr key={line.id} className="align-top"><td className="px-4 py-3"><strong>{line.product_sku_snapshot}</strong><span className="block text-xs text-slate-500">{line.product_name_snapshot}</span>{line.posted_receipt_count > 0 && <span className="mt-1 block text-xs text-emerald-700">Diterima {quantity(line.received_ordered_qty)}</span>}</td><td className="px-4 py-3">{editing ? <select value={draft.uomId} onChange={(event) => updateLine(line.id,{uomId:event.target.value})} className="w-full rounded-lg border p-2">{productUoms.map((uom) => <option key={uom.uomId} value={uom.uomId}>{uom.uomName}</option>)}</select> : line.ordered_uom_name_snapshot}</td><td className="px-4 py-3 text-right">{editing ? <input aria-label={`Qty ${line.product_name_snapshot}`} type="number" min="0.000001" step="any" value={draft.quantity} onChange={(event) => updateLine(line.id,{quantity:event.target.value})} className="w-full rounded-lg border p-2 text-right"/> : quantity(line.ordered_qty)}</td><td className="px-4 py-3 text-right">{editing ? <input aria-label={`Harga ${line.product_name_snapshot}`} type="number" min="0" step="any" value={draft.estimatedUnitPrice} onChange={(event) => updateLine(line.id,{estimatedUnitPrice:event.target.value})} className="w-full rounded-lg border p-2 text-right"/> : money(line.estimated_unit_price)}</td><td className="px-4 py-3">{editing ? <select value={draft.destinationWarehouseId} onChange={(event) => updateLine(line.id,{destinationWarehouseId:event.target.value})} className="w-full rounded-lg border p-2"><option value="">Pilih Gudang</option>{warehouses.map((warehouse) => <option key={warehouse.id} value={warehouse.id}>{warehouse.name}</option>)}</select> : warehouseName}</td><td className="px-4 py-3 text-right font-black">{money(editing ? Number(draft.quantity)*Number(draft.estimatedUnitPrice) : line.estimated_subtotal)}</td></tr>; })}</tbody></table></div>
        <div className="flex justify-end border-t border-slate-100 p-5"><div className="w-full max-w-sm rounded-xl bg-slate-50 p-4"><div className="flex items-center justify-between"><span className="font-bold text-slate-600">Total PO</span><strong className="text-xl">{money(editing ? estimatedTotal : order.estimated_total)}</strong></div></div></div>
      </div>
      <div className="grid gap-5 border-t border-slate-200 p-5 lg:grid-cols-2"><div><h3 className="font-black">Catatan</h3>{editing ? <textarea value={notes} onChange={(event) => setNotes(event.target.value)} maxLength={1000} placeholder="Catatan Purchase Order" className="mt-3 min-h-28 w-full rounded-xl border border-slate-300 p-3"/> : <p className="mt-2 min-h-12 whitespace-pre-wrap text-sm text-slate-600">{order.notes || "Belum ada catatan."}</p>}</div><div><h3 className="font-black">Log aktivitas</h3><div className="mt-3 space-y-2">{activity.length ? activity.map((item) => <div key={item.id} className="rounded-xl bg-slate-50 p-3 text-sm"><strong>{item.action === "UPDATE" ? "PO direvisi" : item.action}</strong><span className="block text-xs text-slate-500">{item.actorName} · {new Date(item.createdAt).toLocaleString("id-ID")}</span></div>) : <p className="text-sm text-slate-500">Belum ada aktivitas.</p>}</div></div></div>
      {editing && <footer className="flex justify-end gap-3 border-t border-slate-200 p-4"><button onClick={resetForm} disabled={busy} className="rounded-xl border px-4 py-3 font-bold">Batal</button><button onClick={() => void save()} disabled={busy} className="inline-flex items-center gap-2 rounded-xl bg-emerald-600 px-5 py-3 font-black text-white disabled:opacity-50">{busy ? <Loader2 className="h-4 w-4 animate-spin"/> : <Save className="h-4 w-4"/>}Simpan perubahan</button></footer>}
    </section>
  </div>;
}

function List({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section>
      <h2 className="mb-3 text-lg font-black">{title}</h2>
      <div className="space-y-3">{children}</div>
    </section>
  );
}

function DailyRoList({ batches, lines, canPost, canCancel, open, cancel }: {
  batches: DailyBatch[];
  lines: DailyLine[];
  canPost: boolean;
  canCancel: boolean;
  open: (batch: DailyBatch) => void;
  cancel: (batch: DailyBatch) => void;
}) {
  return <section className="mb-6 rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
    <div className="flex items-start justify-between gap-3">
      <div><p className="text-xs font-bold uppercase tracking-[.16em] text-emerald-600">Replenishment harian</p><h2 className="mt-1 text-xl font-black">RO otomatis berdasarkan stok minus</h2><p className="mt-1 text-sm text-slate-500">Nomor dan tanggal berasal dari scheduler Company pukul 23.59. Konfirmasi AUTO_RO membuat PO per Supplier.</p></div>
      <span className="rounded-full bg-slate-100 px-3 py-2 text-xs font-black">{batches.length} dokumen</span>
    </div>
    <div className="mt-4 space-y-3">
      {batches.length === 0 && <Empty text="Belum ada RO atau batch PO otomatis harian." />}
      {batches.map((batch) => {
        const batchLines = lines.filter((line) => line.batch_id === batch.id);
        return <article key={batch.id} className="rounded-2xl border border-slate-200 p-4">
          <div className="flex flex-wrap items-start gap-3">
            <CalendarDays className="mt-1 h-5 w-5 text-emerald-600" />
            <div className="min-w-0 flex-1"><div className="flex flex-wrap items-center gap-2"><p className="font-black">{batch.batch_no}</p><span className="rounded-full bg-emerald-50 px-2.5 py-1 text-[11px] font-black text-emerald-700">{batch.mode_snapshot}</span><span className="rounded-full bg-slate-100 px-2.5 py-1 text-[11px] font-black">{batch.status}</span></div><p className="mt-1 text-sm text-slate-500">{batch.business_date} · {batchLines.length} barang · {quantity(batch.requested_total_base_qty)} base qty</p><p className="mt-1 text-xs font-semibold text-slate-500">Dibuat oleh {batch.generated_by_name ?? "Pengguna"}</p></div>
            <div className="flex flex-wrap gap-2">{batch.mode_snapshot === "AUTO_RO" && batch.status === "DRAFT" && canPost && <button onClick={() => open(batch)} className="rounded-xl bg-emerald-600 px-4 py-2 text-sm font-black text-white">Konfirmasi jadi PO</button>}{batch.mode_snapshot === "AUTO_RO" && batch.status === "DRAFT" && canCancel && <button onClick={() => cancel(batch)} className="inline-flex items-center gap-2 rounded-xl border border-rose-300 px-4 py-2 text-sm font-black text-rose-700"><Ban className="h-4 w-4"/>Batalkan RO</button>}</div>
          </div>
          <div className="mt-3 grid gap-2 md:grid-cols-2">{batchLines.map((line) => <div key={line.id} className="rounded-xl bg-slate-50 p-3 text-sm"><p className="font-black">{line.product_sku_snapshot} · {line.product_name_snapshot}</p><p className="mt-1 text-xs text-slate-500">Sumber {line.warehouse_name_snapshot} · {quantity(line.requested_base_qty)} {line.base_uom_name_snapshot}</p></div>)}</div>
        </article>;
      })}
    </div>
  </section>;
}

type DailyAllocationDraft = {
  key: string;
  lineId: string;
  lineVersion: number;
  relationId: string;
  uomId: string;
  quantity: string;
  price: string;
  warehouseId: string;
};

function DailyRoModal({ batch, lines, suppliers, relations, uoms, warehouses, session, close, complete }: {
  batch: DailyBatch;
  lines: DailyLine[];
  suppliers: { id: string; supplierName: string }[];
  relations: DailyRelation[];
  uoms: DailyUom[];
  warehouses: { id: string; name: string; storeId: string | null }[];
  session: Session;
  close: () => void;
  complete: (message: string) => Promise<void>;
}) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [drafts, setDrafts] = useState<DailyAllocationDraft[]>(() => lines.map((line) => {
    const relation = relations.find((item) => item.id === line.suggested_product_supplier_id);
    const uomId = relation?.purchaseUomId ?? line.base_uom_id;
    const uom = uoms.find((item) => item.productId === line.product_id && item.uomId === uomId);
    return { key: crypto.randomUUID(), lineId: line.id, lineVersion: line.master_version,
      relationId: relation?.id ?? "", uomId,
      quantity: String(Number(line.requested_base_qty) / Number(uom?.factorToBase ?? 1)),
      price: String(relation?.lastPurchasePrice ?? relation?.referencePurchasePrice ?? uom?.purchasePrice ?? 0),
      warehouseId: line.destination_warehouse_id ?? "" };
  }));
  useEscapeClose(() => { if (!busy) close(); });
  const supplierById = useMemo(() => new Map(suppliers.map((item) => [item.id, item.supplierName])), [suppliers]);
  function update(key: string, patch: Partial<DailyAllocationDraft>) {
    setDrafts((current) => current.map((item) => item.key === key ? { ...item, ...patch } : item));
  }
  function chooseRelation(draft: DailyAllocationDraft, relationId: string) {
    const line = lines.find((item) => item.id === draft.lineId);
    const oldUom = uoms.find((item) => item.productId === line?.product_id && item.uomId === draft.uomId);
    const baseQty = Number(draft.quantity) * Number(oldUom?.factorToBase ?? 1);
    const relation = relations.find((item) => item.id === relationId);
    const uomId = relation?.purchaseUomId ?? line?.base_uom_id ?? "";
    const nextUom = uoms.find((item) => item.productId === line?.product_id && item.uomId === uomId);
    update(draft.key, { relationId, uomId,
      quantity: String(baseQty / Number(nextUom?.factorToBase ?? 1)),
      price: String(relation?.lastPurchasePrice ?? relation?.referencePurchasePrice ?? nextUom?.purchasePrice ?? 0) });
  }
  function split(line: DailyLine) {
    const source = drafts.find((item) => item.lineId === line.id);
    setDrafts((current) => [...current, { key: crypto.randomUUID(), lineId: line.id,
      lineVersion: line.master_version, relationId: "", uomId: line.base_uom_id,
      quantity: "", price: "0", warehouseId: source?.warehouseId ?? line.destination_warehouse_id ?? "" }]);
  }
  async function submit() {
    if (drafts.some((item) => !item.warehouseId || !item.uomId || Number(item.quantity) <= 0 || Number(item.price) < 0)) return setError("Lengkapi Gudang, satuan, jumlah, dan harga pada seluruh pembagian RO.");
    const duplicates = new Set<string>();
    for (const item of drafts) {
      const key = `${item.lineId}|${item.relationId}|${item.uomId}|${item.warehouseId}`;
      if (duplicates.has(key)) return setError("Pembagian dengan Supplier, satuan, dan Gudang yang sama tidak boleh ganda.");
      duplicates.add(key);
    }
    if (lines.some((line) => !drafts.some((item) => item.lineId === line.id))) return setError("Seluruh barang RO wajib mempunyai minimal satu pembagian.");
    setBusy(true); setError("");
    try {
      const response = await fetch(`/api/purchase/daily-replenishment/${batch.id}/confirm`, {
        method: "POST", headers: { "Content-Type": "application/json", ...headers(session) },
        body: JSON.stringify({ masterVersion: batch.master_version, idempotencyKey: crypto.randomUUID(),
          allocations: drafts.map((item) => ({ batchLineId: item.lineId,
            batchLineVersion: item.lineVersion, destinationWarehouseId: item.warehouseId,
            orderedQty: Number(item.quantity), purchaseUomId: item.uomId,
            productSupplierId: item.relationId || null, estimatedUnitPrice: Number(item.price) })) }),
      });
      const result = await response.json() as { data?: { supplierOrderCount?: number }; error?: string };
      if (!response.ok) throw new Error(friendly(result.error));
      await complete(`${batch.batch_no} dikonfirmasi menjadi ${result.data?.supplierOrderCount ?? 0} PO.`);
    } catch (reason) { setError(reason instanceof Error ? reason.message : "Konfirmasi RO gagal."); setBusy(false); }
  }
  return <div className="fixed inset-0 z-[80] bg-black/60 p-3 sm:p-6"><section role="dialog" aria-modal="true" className="mx-auto flex h-full max-w-6xl flex-col overflow-hidden rounded-2xl bg-white"><header className="flex items-start gap-3 border-b p-5"><div className="flex-1"><p className="text-xs font-bold uppercase tracking-wider text-emerald-600">Konfirmasi Request Order</p><h2 className="mt-1 text-xl font-black">{batch.batch_no}</h2><p className="mt-1 text-sm text-slate-500">Qty, Supplier, satuan, harga, dan Gudang masih dapat disesuaikan sebelum menjadi PO.</p></div><button onClick={close} disabled={busy} className="rounded-xl border p-2"><X className="h-5 w-5"/></button></header><div className="flex-1 overflow-y-auto p-5">{error && <div className="mb-4 rounded-xl bg-rose-50 p-3 text-sm font-semibold text-rose-700">{error}</div>}<div className="space-y-5">{lines.map((line) => <article key={line.id} className="rounded-2xl border border-slate-200 p-4"><div className="flex flex-wrap items-start justify-between gap-3"><div><h3 className="font-black">{line.product_sku_snapshot} · {line.product_name_snapshot}</h3><p className="text-sm text-slate-500">Usulan {quantity(line.requested_base_qty)} {line.base_uom_name_snapshot} dari {line.warehouse_name_snapshot}</p></div><button onClick={() => split(line)} className="rounded-lg border border-emerald-300 px-3 py-2 text-xs font-black text-emerald-700">Bagi ke Supplier lain</button></div><div className="mt-4 space-y-3">{drafts.filter((item) => item.lineId === line.id).map((draft, index) => { const productRelations = relations.filter((item) => item.productId === line.product_id); const productUoms = uoms.filter((item) => item.productId === line.product_id); return <div key={draft.key} className="grid gap-3 rounded-xl bg-slate-50 p-3 md:grid-cols-5"><Field label="Supplier"><select className="field" value={draft.relationId} onChange={(event) => chooseRelation(draft, event.target.value)}><option value="">Belum ditentukan</option>{productRelations.map((relation) => <option key={relation.id} value={relation.id}>{supplierById.get(relation.supplierId) ?? "Supplier"}{relation.preferred ? " · prioritas" : ""}</option>)}</select></Field><Field label="Satuan"><select className="field" value={draft.uomId} onChange={(event) => update(draft.key, { uomId: event.target.value })} disabled={!draft.relationId}><option value={line.base_uom_id}>{line.base_uom_name_snapshot}</option>{productUoms.filter((uom) => uom.uomId !== line.base_uom_id && productRelations.some((relation) => relation.id === draft.relationId && relation.purchaseUomId === uom.uomId)).map((uom) => <option key={uom.uomId} value={uom.uomId}>{uom.uomName}</option>)}</select></Field><Field label="Qty"><input className="field" type="number" min="0" step="any" value={draft.quantity} onChange={(event) => update(draft.key, { quantity: event.target.value })}/></Field><Field label="Harga"><input className="field" type="number" min="0" step="any" value={draft.price} onChange={(event) => update(draft.key, { price: event.target.value })}/></Field><Field label="Gudang terima"><select className="field" value={draft.warehouseId} onChange={(event) => update(draft.key, { warehouseId: event.target.value })}><option value="">Pilih Gudang</option>{warehouses.map((warehouse) => <option key={warehouse.id} value={warehouse.id}>{warehouse.name}</option>)}</select></Field>{index > 0 && <button onClick={() => setDrafts((current) => current.filter((item) => item.key !== draft.key))} className="text-left text-xs font-black text-rose-700">Hapus pembagian</button>}</div>; })}</div></article>)}</div></div><footer className="flex justify-end gap-3 border-t p-4"><button onClick={close} disabled={busy} className="rounded-xl border px-4 py-3 font-bold">Kembali</button><button onClick={() => void submit()} disabled={busy} className="inline-flex items-center gap-2 rounded-xl bg-emerald-600 px-5 py-3 font-black text-white disabled:opacity-50">{busy ? <Loader2 className="h-4 w-4 animate-spin"/> : <Send className="h-4 w-4"/>}Konfirmasi jadi PO</button></footer></section></div>;
}

function CancelPurchaseModal({ label, busy, readiness, readinessLoading, close, submit }: { label: string; busy: boolean; readiness: ReturnReadiness | null; readinessLoading: boolean; close: () => void; submit: (reason: string) => Promise<void> }) {
  const [reason, setReason] = useState("");
  useEscapeClose(() => { if (!busy) close(); });
  const blocked = Boolean(readiness && !readiness.canCancel);
  return <div className="fixed inset-0 z-[90] grid place-items-center bg-black/60 p-4"><section role="dialog" aria-modal="true" className="w-full max-w-xl rounded-2xl bg-white p-6"><h2 className="text-xl font-black">Batalkan {label}?</h2><p className="mt-2 text-sm text-slate-500">PO yang sudah menerima barang hanya dapat dibatalkan setelah seluruh barang diretur dan koreksi tagihannya selesai.</p>{readinessLoading && <div className="mt-4 rounded-xl bg-slate-50 p-3 text-sm font-semibold">Memeriksa penerimaan, retur, Bill, dan Finance…</div>}{readiness && <div className={`mt-4 rounded-xl border p-4 text-sm ${blocked ? "border-amber-200 bg-amber-50 text-amber-900" : "border-emerald-200 bg-emerald-50 text-emerald-900"}`}><p className="font-black">{blocked ? "PO belum dapat dibatalkan" : "PO aman dibatalkan"}</p><p className="mt-1">Sisa penerimaan bersih: {quantity(readiness.netReceivedBaseQty)} base unit.</p>{readiness.draftReturnRows > 0 && <p>Selesaikan {readiness.draftReturnRows} Draft Retur.</p>}{readiness.draftBillRows > 0 && <p>Batalkan atau selesaikan {readiness.draftBillRows} Draft Bill.</p>}{readiness.invalidPostedReturnFinanceRows > 0 && <p>Rekonsiliasi Finance retur belum selesai.</p>}{Number(readiness.supplierRefundReceivable) > 0 && <p>Piutang refund Supplier tetap tercatat: {money(readiness.supplierRefundReceivable)}.</p>}</div>}<label className="mt-5 block text-sm font-bold">Catatan pembatalan (opsional)<textarea value={reason} onChange={(event) => setReason(event.target.value)} maxLength={1000} className="mt-2 min-h-28 w-full rounded-xl border border-slate-300 p-3 font-normal"/></label><div className="mt-5 flex justify-end gap-3"><button onClick={close} disabled={busy} className="rounded-xl border px-4 py-3 font-bold">Kembali</button><button onClick={() => void submit(reason)} disabled={busy || readinessLoading || blocked} className="inline-flex items-center gap-2 rounded-xl bg-rose-600 px-5 py-3 font-black text-white disabled:opacity-50"><Ban className="h-4 w-4"/>Batalkan dokumen</button></div></section></div>;
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
  async function confirmRequestOrder() {
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
      const posted = await fetch(
        `/api/purchase/supplier-orders/${result.data.documentId}/confirm`,
        {
          method: "POST",
          headers: { "Content-Type": "application/json", ...headers(session) },
          body: JSON.stringify({
            masterVersion: result.data.masterVersion,
            idempotencyKey: crypto.randomUUID(),
          }),
        },
      );
      const postResult = (await posted.json()) as { error?: string };
      if (!posted.ok) throw new Error(friendly(postResult.error));
      await complete(`${request.request_no} dikonfirmasi menjadi ${result.data.orderNo}.`);
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
            <h2 className="mt-1 text-xl font-black">Konfirmasi Request Order</h2>
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
          {canPost && (
            <button
              onClick={() => void confirmRequestOrder()}
              disabled={busy}
              className="inline-flex items-center gap-2 rounded-xl bg-emerald-500 px-5 py-3 font-black text-white"
            >
              {busy ? (
                <Loader2 className="h-4 w-4 animate-spin" />
              ) : (
                <Send className="h-4 w-4" />
              )}
              Konfirmasi RO & Buat PO
            </button>
          )}
        </footer>
      </section>
    </div>
  );
}
