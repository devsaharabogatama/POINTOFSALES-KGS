"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import {
  Ban,
  CheckCircle2,
  Eye,
  Loader2,
  RefreshCcw,
  Search,
  X,
} from "lucide-react";
import { useEscapeClose } from "@/lib/use-escape-close";

type Document = {
  id: string;
  return_no: string;
  source_receipt_id: string;
  supplier_id: string;
  store_id: string;
  source_warehouse_id: string;
  return_date: string;
  return_reason: string;
  supplier_document_no: string | null;
  notes: string | null;
  status: "DRAFT" | "POSTED" | "CANCELED";
  review_status: "PENDING" | "APPROVED" | "REJECTED";
  line_count: number | string;
  total_return_base_qty: number | string;
  provisional_ap_adjustment_total: number | string;
  created_by: string;
  reviewed_by: string | null;
  reviewed_at: string | null;
  review_reason: string | null;
  posted_by: string | null;
  posted_at: string | null;
  canceled_by: string | null;
  canceled_at: string | null;
  cancel_reason: string | null;
  master_version: number | string;
  created_at: string;
  financial_event_id: string | null;
};
type Line = {
  id: string;
  document_id: string;
  product_sku_snapshot: string;
  product_name_snapshot: string;
  return_uom_name_snapshot: string;
  return_qty: number | string;
  return_base_qty: number | string;
  source_condition_snapshot: string;
  base_uom_name_snapshot: string;
  provisional_base_unit_cost_snapshot: number | string;
  provisional_return_value: number | string;
};
type Lookup = {
  id: string;
  name?: string;
  receipt_no?: string;
  supplier_delivery_no?: string | null;
  supplier_name?: string;
  store_name?: string;
};
type Payload = {
  data?: Document[];
  lines?: Line[];
  receipts?: Lookup[];
  suppliers?: Lookup[];
  stores?: Lookup[];
  warehouses?: Lookup[];
  actors?: Lookup[];
  error?: string;
};
type Action = "approve" | "reject" | "post" | "cancel";
const authHeaders = (session: Session) => ({
  Authorization: `Bearer ${session.access_token}`,
});
const rupiah = (value: number | string) =>
  new Intl.NumberFormat("id-ID", {
    style: "currency",
    currency: "IDR",
    maximumFractionDigits: 0,
  }).format(Number(value) || 0);
const qty = (value: number | string) =>
  new Intl.NumberFormat("id-ID", { maximumFractionDigits: 6 }).format(
    Number(value) || 0,
  );
const dateTime = (value: string | null) =>
  value ? new Date(value).toLocaleString("id-ID") : "-";
function friendly(code?: string) {
  const map: Record<string, string> = {
    CUSTOM_PERMISSION_DENIED:
      "Akses Retur Pembelian dibatasi oleh pengaturan user Anda.",
    PURCHASE_RETURN_NOT_FOUND: "Retur Pembelian tidak ditemukan.",
    PURCHASE_RETURN_NOT_REVIEWABLE: "Dokumen tidak lagi dapat direview.",
    PURCHASE_RETURN_APPROVER_REQUIRED:
      "Role atau cakupan Store Anda tidak diizinkan.",
    REJECTION_REASON_REQUIRED: "Alasan penolakan wajib diisi.",
    APPROVED_PURCHASE_RETURN_REQUIRED:
      "Retur harus disetujui sebelum diposting.",
    PURCHASE_RETURN_QUANTITY_CHANGED_DURING_POST:
      "Jumlah yang tersedia berubah. Periksa ulang dokumen.",
    PURCHASE_RETURN_FIFO_NOT_AVAILABLE:
      "Stok dari penerimaan asal sudah tidak mencukupi.",
    PURCHASE_RETURN_STOCK_NOT_AVAILABLE: "Stok gudang sudah tidak mencukupi.",
    PURCHASE_RETURN_AP_ADJUSTMENT_EXCEEDS_SOURCE:
      "Nilai retur melebihi provisional AP penerimaan.",
    MASTER_VERSION_CONFLICT: "Dokumen berubah di perangkat lain. Muat ulang.",
    CANCEL_REASON_REQUIRED: "Alasan pembatalan wajib diisi.",
    FORBIDDEN: "Anda tidak diizinkan mengakses Retur Pembelian.",
  };
  return map[code ?? ""] ?? code ?? "Operasi Retur Pembelian gagal.";
}

export function PurchaseReturnApprovalView({
  session,
  companyId,
  canReview,
  canPost,
  canCancel,
  notify,
}: {
  session: Session;
  companyId: string;
  canReview: boolean;
  canPost: boolean;
  canCancel: boolean;
  notify: (message: string) => void;
}) {
  const [payload, setPayload] = useState<Payload>({});
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [status, setStatus] = useState<"ALL" | "DRAFT" | "POSTED" | "CANCELED">(
    "DRAFT",
  );
  const [search, setSearch] = useState("");
  const [detail, setDetail] = useState<Document | null>(null);
  const [action, setAction] = useState<{
    type: Action;
    document: Document;
  } | null>(null);
  const load = useCallback(async () => {
    const response = await fetch("/api/purchase/returns", {
      headers: authHeaders(session),
    });
    const result = (await response.json()) as Payload;
    if (!response.ok) throw new Error(friendly(result.error));
    setPayload(result);
  }, [session]);
  const refresh = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      await load();
    } catch (caught) {
      setError(
        caught instanceof Error
          ? caught.message
          : "Gagal memuat Retur Pembelian.",
      );
    } finally {
      setLoading(false);
    }
  }, [load]);
  useEffect(() => {
    let canceled = false;
    // eslint-disable-next-line react-hooks/set-state-in-effect -- load follows the active tenant context
    load()
      .catch((caught) => {
        if (!canceled)
          setError(
            caught instanceof Error
              ? caught.message
              : "Gagal memuat Retur Pembelian.",
          );
      })
      .finally(() => {
        if (!canceled) setLoading(false);
      });
    return () => {
      canceled = true;
    };
  }, [companyId, load]);
  const receiptById = useMemo(
    () => new Map((payload.receipts ?? []).map((row) => [row.id, row])),
    [payload.receipts],
  );
  const supplierById = useMemo(
    () =>
      new Map(
        (payload.suppliers ?? []).map((row) => [
          row.id,
          row.supplier_name ?? "Supplier",
        ]),
      ),
    [payload.suppliers],
  );
  const storeById = useMemo(
    () =>
      new Map(
        (payload.stores ?? []).map((row) => [
          row.id,
          row.store_name ?? "Store",
        ]),
      ),
    [payload.stores],
  );
  const warehouseById = useMemo(
    () =>
      new Map(
        (payload.warehouses ?? []).map((row) => [row.id, row.name ?? "Gudang"]),
      ),
    [payload.warehouses],
  );
  const actorById = useMemo(
    () =>
      new Map(
        (payload.actors ?? []).map((row) => [row.id, row.name ?? "User"]),
      ),
    [payload.actors],
  );
  const documents = useMemo(() => {
    const term = search.trim().toLowerCase();
    return (payload.data ?? []).filter(
      (row) =>
        (status === "ALL" || row.status === status) &&
        (!term ||
          [
            row.return_no,
            receiptById.get(row.source_receipt_id)?.receipt_no,
            supplierById.get(row.supplier_id),
            storeById.get(row.store_id),
          ].some((value) => value?.toLowerCase().includes(term))),
    );
  }, [payload.data, receiptById, search, status, storeById, supplierById]);
  const counts = {
    pending: (payload.data ?? []).filter(
      (row) => row.status === "DRAFT" && row.review_status === "PENDING",
    ).length,
    approved: (payload.data ?? []).filter(
      (row) => row.status === "DRAFT" && row.review_status === "APPROVED",
    ).length,
    posted: (payload.data ?? []).filter((row) => row.status === "POSTED")
      .length,
  };
  return (
    <>
      <section className="space-y-6">
        <div className="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
          <div>
            <p className="text-xs font-black uppercase tracking-[0.18em] text-amber-600">
              Purchase Control
            </p>
            <h1 className="mt-2 text-3xl font-black text-slate-950">
              Retur Pembelian
            </h1>
            <p className="mt-2 max-w-3xl text-sm text-slate-500">
              Review barang dari Goods Receipt sebelum stok/FIFO dan provisional
              AP dikurangi.
            </p>
          </div>
          <button
            onClick={refresh}
            disabled={loading}
            className="inline-flex min-h-11 items-center justify-center gap-2 rounded-xl border border-slate-200 bg-white px-4 text-sm font-black"
          >
            <RefreshCcw
              className={`h-4 w-4 ${loading ? "animate-spin" : ""}`}
            />
            Muat ulang
          </button>
        </div>
        <div className="grid gap-3 sm:grid-cols-3">
          <Summary
            label="Menunggu review"
            value={counts.pending}
            tone="amber"
          />
          <Summary label="Siap diposting" value={counts.approved} tone="blue" />
          <Summary
            label="Sudah diposting"
            value={counts.posted}
            tone="emerald"
          />
        </div>
        <div className="grid gap-3 rounded-2xl border border-slate-200 bg-white p-4 md:grid-cols-[220px_1fr]">
          <label className="text-sm font-bold">
            Status
            <select
              value={status}
              onChange={(event) =>
                setStatus(event.target.value as typeof status)
              }
              className="mt-2 min-h-11 w-full rounded-xl border border-slate-200 bg-white px-3"
            >
              <option value="DRAFT">Draft / approval</option>
              <option value="POSTED">Sudah diposting</option>
              <option value="CANCELED">Dibatalkan</option>
              <option value="ALL">Semua</option>
            </select>
          </label>
          <label className="text-sm font-bold">
            Cari
            <span className="mt-2 flex min-h-11 items-center gap-2 rounded-xl border border-slate-200 px-3">
              <Search className="h-4 w-4 text-slate-400" />
              <input
                value={search}
                onChange={(event) => setSearch(event.target.value)}
                placeholder="Nomor retur, penerimaan, supplier, atau Store"
                className="w-full bg-transparent text-sm outline-none"
              />
            </span>
          </label>
        </div>
        {error && (
          <div className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-semibold text-rose-700">
            {error}
          </div>
        )}
        <div className="overflow-x-auto rounded-2xl border border-slate-200 bg-white">
          <table className="w-full min-w-[940px] text-left text-sm">
            <thead className="bg-slate-50 text-xs uppercase tracking-wider text-slate-500">
              <tr>
                <th className="px-5 py-4">Retur / Penerimaan</th>
                <th className="px-5 py-4">Supplier</th>
                <th className="px-5 py-4">Gudang</th>
                <th className="px-5 py-4 text-right">Nilai sementara</th>
                <th className="px-5 py-4">Status</th>
                <th className="px-5 py-4 text-right">Aksi</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {documents.map((row) => (
                <tr key={row.id}>
                  <td className="px-5 py-4">
                    <p className="font-black">{row.return_no}</p>
                    <p className="mt-1 text-xs text-slate-500">
                      {receiptById.get(row.source_receipt_id)?.receipt_no ??
                        "Goods Receipt"}{" "}
                      · {dateTime(row.created_at)}
                    </p>
                  </td>
                  <td className="px-5 py-4 font-semibold">
                    {supplierById.get(row.supplier_id) ?? "Supplier"}
                  </td>
                  <td className="px-5 py-4">
                    {warehouseById.get(row.source_warehouse_id) ?? "Gudang"}
                    <p className="text-xs text-slate-500">
                      {storeById.get(row.store_id) ?? "Store"}
                    </p>
                  </td>
                  <td className="px-5 py-4 text-right font-black">
                    {rupiah(row.provisional_ap_adjustment_total)}
                  </td>
                  <td className="px-5 py-4">
                    <Badge document={row} />
                  </td>
                  <td className="px-5 py-4 text-right">
                    <button
                      onClick={() => setDetail(row)}
                      className="inline-flex min-h-10 items-center gap-2 rounded-xl border border-slate-200 px-3 font-black"
                    >
                      <Eye className="h-4 w-4" />
                      Detail
                    </button>
                  </td>
                </tr>
              ))}
              {loading && (
                <tr>
                  <td colSpan={6} className="p-12 text-center">
                    <Loader2 className="mx-auto h-5 w-5 animate-spin" />
                  </td>
                </tr>
              )}
              {!loading && !documents.length && (
                <tr>
                  <td colSpan={6} className="p-12 text-center text-slate-400">
                    Tidak ada dokumen untuk filter ini.
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </section>
      {detail && (
        <Detail
          document={detail}
          lines={(payload.lines ?? []).filter(
            (line) => line.document_id === detail.id,
          )}
          receipt={receiptById.get(detail.source_receipt_id)}
          supplier={supplierById.get(detail.supplier_id)}
          store={storeById.get(detail.store_id)}
          warehouse={warehouseById.get(detail.source_warehouse_id)}
          actors={actorById}
          canReview={canReview}
          canPost={canPost}
          canCancel={canCancel}
          close={() => setDetail(null)}
          act={(type) => setAction({ type, document: detail })}
        />
      )}{" "}
      {action && (
        <ActionDialog
          session={session}
          action={action}
          close={() => setAction(null)}
          complete={async () => {
            const type = action.type;
            setAction(null);
            setDetail(null);
            await refresh();
            notify(
              type === "approve"
                ? "Retur Pembelian disetujui dan siap diposting."
                : type === "post"
                  ? "Retur Pembelian diposting; stok dan provisional AP sudah diperbarui."
                  : type === "reject"
                    ? "Retur Pembelian ditolak."
                    : "Retur Pembelian dibatalkan.",
            );
          }}
        />
      )}
    </>
  );
}
function Summary({
  label,
  value,
  tone,
}: {
  label: string;
  value: number;
  tone: "amber" | "blue" | "emerald";
}) {
  const style =
    tone === "amber"
      ? "border-amber-200 bg-amber-50 text-amber-900"
      : tone === "blue"
        ? "border-blue-200 bg-blue-50 text-blue-900"
        : "border-emerald-200 bg-emerald-50 text-emerald-900";
  return (
    <div className={`rounded-2xl border p-5 ${style}`}>
      <p className="text-xs font-black uppercase tracking-wider opacity-70">
        {label}
      </p>
      <p className="mt-2 text-3xl font-black">{value}</p>
    </div>
  );
}
function Badge({ document }: { document: Document }) {
  const label =
    document.status === "POSTED"
      ? "Diposting"
      : document.status === "CANCELED"
        ? document.review_status === "REJECTED"
          ? "Ditolak"
          : "Dibatalkan"
        : document.review_status === "APPROVED"
          ? "Disetujui"
          : "Menunggu review";
  const style =
    document.status === "POSTED"
      ? "bg-emerald-100 text-emerald-800"
      : document.status === "CANCELED"
        ? "bg-slate-200 text-slate-700"
        : document.review_status === "APPROVED"
          ? "bg-blue-100 text-blue-800"
          : "bg-amber-100 text-amber-800";
  return (
    <span className={`rounded-full px-3 py-1 text-xs font-black ${style}`}>
      {label}
    </span>
  );
}
function Detail({
  document,
  lines,
  receipt,
  supplier,
  store,
  warehouse,
  actors,
  canReview,
  canPost,
  canCancel,
  close,
  act,
}: {
  document: Document;
  lines: Line[];
  receipt?: Lookup;
  supplier?: string;
  store?: string;
  warehouse?: string;
  actors: Map<string, string>;
  canReview: boolean;
  canPost: boolean;
  canCancel: boolean;
  close: () => void;
  act: (type: Action) => void;
}) {
  useEscapeClose(close);
  return (
    <div className="fixed inset-0 z-[70] overflow-y-auto bg-slate-950/60 p-4">
      <div className="mx-auto my-6 max-w-5xl rounded-3xl bg-white p-6 shadow-2xl">
        <div className="flex items-start justify-between">
          <div>
            <p className="text-xs font-black uppercase tracking-wider text-amber-600">
              Detail Retur Pembelian
            </p>
            <h2 className="mt-2 text-2xl font-black">{document.return_no}</h2>
            <p className="mt-1 text-sm text-slate-500">
              {receipt?.receipt_no ?? "Goods Receipt"} ·{" "}
              {supplier ?? "Supplier"} · {store ?? "Store"}
            </p>
          </div>
          <button
            onClick={close}
            className="rounded-xl bg-slate-100 p-2"
            aria-label="Tutup"
          >
            <X className="h-5 w-5" />
          </button>
        </div>
        <div className="mt-5 grid gap-3 sm:grid-cols-4">
          <Info
            label="Status"
            value={
              document.status === "DRAFT"
                ? document.review_status
                : document.status
            }
          />
          <Info label="Tanggal retur" value={document.return_date} />
          <Info label="Gudang asal" value={warehouse ?? "Gudang"} />
          <Info
            label="Dibuat oleh"
            value={actors.get(document.created_by) ?? "User"}
          />
        </div>
        <div className="mt-5 rounded-2xl bg-amber-50 p-4 text-sm text-amber-950">
          <strong>Alasan:</strong> {document.return_reason}
          {document.supplier_document_no && (
            <p className="mt-1">
              <strong>Dokumen supplier:</strong> {document.supplier_document_no}
            </p>
          )}
        </div>
        <div className="mt-5 overflow-x-auto rounded-2xl border border-slate-200">
          <table className="w-full min-w-[760px] text-sm">
            <thead className="bg-slate-50 text-left text-xs uppercase text-slate-500">
              <tr>
                <th className="p-4">Barang</th>
                <th className="p-4">Kondisi asal</th>
                <th className="p-4 text-right">Jumlah</th>
                <th className="p-4 text-right">Base Qty</th>
                <th className="p-4 text-right">Nilai sementara</th>
              </tr>
            </thead>
            <tbody>
              {lines.map((line) => (
                <tr key={line.id} className="border-t">
                  <td className="p-4">
                    <strong>{line.product_name_snapshot}</strong>
                    <p className="text-xs text-slate-500">
                      {line.product_sku_snapshot}
                    </p>
                  </td>
                  <td className="p-4">
                    {line.source_condition_snapshot === "GOOD"
                      ? "Baik"
                      : "Rusak"}
                  </td>
                  <td className="p-4 text-right">
                    {qty(line.return_qty)} {line.return_uom_name_snapshot}
                  </td>
                  <td className="p-4 text-right">
                    {qty(line.return_base_qty)} {line.base_uom_name_snapshot}
                  </td>
                  <td className="p-4 text-right font-black">
                    {rupiah(line.provisional_return_value)}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <div className="mt-5 flex flex-wrap justify-between gap-4 rounded-2xl bg-slate-950 p-5 text-white">
          <div>
            <p className="text-xs uppercase text-slate-400">Total base qty</p>
            <p className="mt-1 text-xl font-black">
              {qty(document.total_return_base_qty)}
            </p>
          </div>
          <div className="text-right">
            <p className="text-xs uppercase text-slate-400">
              Penyesuaian provisional AP
            </p>
            <p className="mt-1 text-xl font-black">
              {rupiah(document.provisional_ap_adjustment_total)}
            </p>
          </div>
        </div>
        {document.notes && (
          <p className="mt-4 rounded-xl bg-slate-50 p-4 text-sm">
            <strong>Catatan:</strong> {document.notes}
          </p>
        )}
        {document.review_status === "APPROVED" && document.reviewed_by && (
          <p className="mt-4 text-sm text-slate-500">
            Disetujui oleh {actors.get(document.reviewed_by) ?? "Manager"} ·{" "}
            {dateTime(document.reviewed_at)}
          </p>
        )}
        <div className="mt-6 flex flex-wrap justify-end gap-3">
          <button
            onClick={close}
            className="min-h-11 rounded-xl border border-slate-200 px-5 font-black"
          >
            Tutup
          </button>
          {canReview &&
            document.status === "DRAFT" &&
            document.review_status === "PENDING" && (
              <>
                <button
                  onClick={() => act("reject")}
                  className="min-h-11 rounded-xl border border-rose-200 px-5 font-black text-rose-700"
                >
                  Tolak
                </button>
                <button
                  onClick={() => act("approve")}
                  className="min-h-11 rounded-xl bg-blue-600 px-5 font-black text-white"
                >
                  Setujui
                </button>
              </>
            )}
          {(canPost || canCancel) &&
            document.status === "DRAFT" &&
            document.review_status === "APPROVED" && (
              <>
                {canCancel && (
                  <button
                    onClick={() => act("cancel")}
                    className="min-h-11 rounded-xl border border-rose-200 px-5 font-black text-rose-700"
                  >
                    Batalkan
                  </button>
                )}
                {canPost && (
                  <button
                    onClick={() => act("post")}
                    className="inline-flex min-h-11 items-center gap-2 rounded-xl bg-emerald-600 px-5 font-black text-white"
                  >
                    <CheckCircle2 className="h-4 w-4" />
                    Post Retur
                  </button>
                )}
              </>
            )}
        </div>
      </div>
    </div>
  );
}
function Info({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-2xl border border-slate-200 p-4">
      <p className="text-xs font-black uppercase text-slate-400">{label}</p>
      <p className="mt-2 font-black">{value}</p>
    </div>
  );
}
function ActionDialog({
  session,
  action,
  close,
  complete,
}: {
  session: Session;
  action: { type: Action; document: Document };
  close: () => void;
  complete: () => Promise<void>;
}) {
  useEscapeClose(close);
  const [reason, setReason] = useState("");
  const [confirmed, setConfirmed] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const needsReason = action.type === "reject" || action.type === "cancel";
  async function run() {
    setBusy(true);
    setError("");
    try {
      const endpoint =
        action.type === "approve" || action.type === "reject"
          ? "review"
          : action.type;
      const body = {
        masterVersion: Number(action.document.master_version),
        ...(endpoint === "review"
          ? {
              decision: action.type.toUpperCase(),
              reason: needsReason ? reason : null,
            }
          : endpoint === "post"
            ? { idempotencyKey: crypto.randomUUID() }
            : { reason }),
      };
      const response = await fetch(
        `/api/purchase/returns/${action.document.id}/${endpoint}`,
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            ...authHeaders(session),
          },
          body: JSON.stringify(body),
        },
      );
      const result = (await response.json()) as { error?: string };
      if (!response.ok) throw new Error(friendly(result.error));
      await complete();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Tindakan gagal.");
    } finally {
      setBusy(false);
    }
  }
  const title =
    action.type === "approve"
      ? "Setujui Retur Pembelian?"
      : action.type === "post"
        ? "Post Retur Pembelian?"
        : action.type === "reject"
          ? "Tolak pengajuan retur?"
          : "Batalkan retur yang disetujui?";
  return (
    <div className="fixed inset-0 z-[85] grid place-items-center bg-slate-950/65 p-4">
      <section className="w-full max-w-xl rounded-3xl bg-white p-7 shadow-2xl">
        <div className="flex justify-between">
          <div>
            <p className="text-xs font-black uppercase tracking-wider text-amber-600">
              Konfirmasi Retur Pembelian
            </p>
            <h2 className="mt-2 text-xl font-black">{title}</h2>
            <p className="mt-1 text-sm text-slate-500">
              {action.document.return_no} ·{" "}
              {rupiah(action.document.provisional_ap_adjustment_total)}
            </p>
          </div>
          <button
            onClick={close}
            className="rounded-xl bg-slate-100 p-2"
            aria-label="Tutup"
          >
            <X className="h-4 w-4" />
          </button>
        </div>
        {needsReason ? (
          <label className="mt-5 block text-sm font-black">
            Alasan {action.type === "reject" ? "penolakan" : "pembatalan"}
            <textarea
              value={reason}
              onChange={(event) => setReason(event.target.value)}
              rows={4}
              maxLength={500}
              className="mt-2 w-full rounded-xl border border-slate-200 p-3 font-normal"
            />
          </label>
        ) : (
          <div className="mt-5 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-900">
            {action.type === "post"
              ? "Posting bersifat final: stok/FIFO akan berkurang dan penyesuaian provisional AP dicatat. Event Finance tetap HOLD sampai G6."
              : "Approval tidak mengubah stok. Setelah disetujui, dokumen masih harus diposting."}
          </div>
        )}
        <label className="mt-5 flex gap-3 rounded-2xl border border-slate-200 p-4 text-sm font-semibold">
          <input
            type="checkbox"
            checked={confirmed}
            onChange={(event) => setConfirmed(event.target.checked)}
            className="mt-0.5 h-4 w-4 accent-amber-600"
          />
          <span>
            Saya sudah memeriksa penerimaan asal, barang, kondisi, jumlah,
            gudang, dan nilai sementara.
          </span>
        </label>
        {error && (
          <p className="mt-4 rounded-xl bg-rose-50 p-3 text-sm font-semibold text-rose-700">
            {error}
          </p>
        )}
        <div className="mt-6 flex justify-end gap-3">
          <button
            onClick={close}
            disabled={busy}
            className="min-h-11 rounded-xl border border-slate-200 px-5 font-black"
          >
            Kembali
          </button>
          <button
            onClick={() => void run()}
            disabled={
              busy || !confirmed || (needsReason && reason.trim().length < 3)
            }
            className={`inline-flex min-h-11 items-center gap-2 rounded-xl px-5 font-black text-white disabled:bg-slate-300 ${needsReason ? "bg-rose-600" : action.type === "post" ? "bg-emerald-600" : "bg-blue-600"}`}
          >
            {busy ? (
              <Loader2 className="h-4 w-4 animate-spin" />
            ) : needsReason ? (
              <Ban className="h-4 w-4" />
            ) : (
              <CheckCircle2 className="h-4 w-4" />
            )}
            {action.type === "approve"
              ? "Setujui"
              : action.type === "post"
                ? "Post Retur"
                : action.type === "reject"
                  ? "Tolak"
                  : "Batalkan"}
          </button>
        </div>
      </section>
    </div>
  );
}
