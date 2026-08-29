"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import {
  BadgeCheck,
  CircleAlert,
  ExternalLink,
  FileClock,
  Loader2,
  RefreshCcw,
  ShieldCheck,
  X,
} from "lucide-react";
import { useEscapeClose } from "@/lib/use-escape-close";

type VerificationStatus = "PENDING" | "VERIFIED" | "REJECTED";

type PaymentVerification = {
  id: string;
  salesId: string;
  invoiceNo: string;
  customerCode: string | null;
  customerName: string;
  storeName: string;
  paymentMethodName: string;
  paymentMethodType: string;
  settlementRoute: string;
  amount: number | string;
  proofUrl: string | null;
  status: VerificationStatus;
  receiptTiming: string | null;
  settlementTarget: string | null;
  requestedBy: string;
  requestedByName: string | null;
  requestedAt: string;
  reviewedByName: string | null;
  reviewedAt: string | null;
  reviewNote: string | null;
  effectiveDate: string | null;
  financialEventId: string | null;
  masterVersion: number | string;
};

type Workspace = {
  paymentVerificationWorkspaceVersion: number;
  companyId: string;
  currentUserId: string;
  effectiveCapabilities: string[];
  requests: PaymentVerification[];
};

type ReviewAction = {
  request: PaymentVerification;
  action: "VERIFY" | "REJECT";
  idempotencyKey: string;
};

const errors: Record<string, string> = {
  CUSTOM_PERMISSION_DENIED:
    "Anda tidak mempunyai izin untuk membuka atau memproses verifikasi pembayaran.",
  MAKER_CHECKER_REQUIRED:
    "Pembuat permintaan tidak boleh memverifikasi atau menolak permintaannya sendiri.",
  MASTER_VERSION_CONFLICT:
    "Permintaan sudah berubah. Muat ulang sebelum mencoba lagi.",
  PAYMENT_VERIFICATION_FINAL: "Permintaan ini sudah mempunyai keputusan final.",
  PAYMENT_VERIFICATION_NOT_FOUND: "Permintaan pembayaran tidak ditemukan.",
  CASH_PAYMENT_REJECTION_REQUIRES_OPEN_SESSION:
    "Pembayaran tunai hanya dapat ditolak saat sesi kasir sumber masih terbuka.",
  PAYMENT_TRANSACTION_CATEGORY_MISSING_OR_AMBIGUOUS:
    "Mapping kategori Finance untuk verifikasi pembayaran belum siap.",
  ACTIVE_COMPANY_CONTEXT_MISMATCH:
    "Company aktif berubah. Muat ulang workspace sebelum melanjutkan.",
};

function friendly(code: string | undefined) {
  if (!code) return "Workspace verifikasi pembayaran gagal diproses.";
  const match = Object.keys(errors).find((key) => code.includes(key));
  return match ? errors[match] : code;
}

async function readJson<T>(response: Response): Promise<T> {
  const text = await response.text();
  if (!text.trim()) throw new Error(`Respons kosong (HTTP ${response.status}).`);
  try {
    return JSON.parse(text) as T;
  } catch {
    throw new Error(`Respons server tidak valid (HTTP ${response.status}).`);
  }
}

function money(value: unknown) {
  return new Intl.NumberFormat("id-ID", {
    style: "currency",
    currency: "IDR",
    maximumFractionDigits: 0,
  }).format(Number(value) || 0);
}

function dateTime(value: string | null) {
  if (!value) return "-";
  return new Date(value).toLocaleString("id-ID", {
    day: "2-digit",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function isHttps(value: string | null): value is string {
  return Boolean(value && /^https:\/\//i.test(value));
}

export function SalesPaymentVerificationPanel({
  session,
  companyId,
  notify,
  openQueue,
}: {
  session: Session;
  companyId: string;
  notify: (message: string) => void;
  openQueue: () => void;
}) {
  const [workspace, setWorkspace] = useState<Workspace | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [filter, setFilter] = useState<"ALL" | VerificationStatus>("PENDING");
  const [review, setReview] = useState<ReviewAction | null>(null);
  const [note, setNote] = useState("");
  const [saving, setSaving] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      const response = await fetch(
        "/api/finance/sales-payment-verifications",
        {
          headers: { Authorization: `Bearer ${session.access_token}` },
          cache: "no-store",
        },
      );
      const result = await readJson<Workspace & { error?: string }>(response);
      if (!response.ok) throw new Error(friendly(result.error));
      if (result.paymentVerificationWorkspaceVersion !== 1) {
        throw new Error("PAYMENT_VERIFICATION_WORKSPACE_VERSION_UNSUPPORTED");
      }
      setWorkspace(result);
    } catch (caught) {
      setWorkspace(null);
      setError(caught instanceof Error ? caught.message : "Workspace gagal dimuat.");
    } finally {
      setLoading(false);
    }
  }, [session.access_token]);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- remote workspace follows active tenant
    void load();
  }, [companyId, load]);

  const requests = useMemo(
    () =>
      (workspace?.requests ?? []).filter(
        (request) => filter === "ALL" || request.status === filter,
      ),
    [filter, workspace?.requests],
  );
  const capabilities = new Set(workspace?.effectiveCapabilities ?? []);

  function beginReview(
    request: PaymentVerification,
    action: "VERIFY" | "REJECT",
  ) {
    setNote("");
    setReview({ request, action, idempotencyKey: crypto.randomUUID() });
  }

  async function submitReview() {
    if (!review || saving) return;
    setSaving(true);
    try {
      const response = await fetch(
        "/api/finance/sales-payment-verifications",
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${session.access_token}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            requestId: review.request.id,
            masterVersion: Number(review.request.masterVersion),
            action: review.action,
            note,
            idempotencyKey: review.idempotencyKey,
          }),
        },
      );
      const result = await readJson<{ data?: { status?: string }; error?: string }>(
        response,
      );
      if (!response.ok) throw new Error(friendly(result.error));
      setReview(null);
      notify(
        review.action === "VERIFY"
          ? "Pembayaran terverifikasi dan masuk event HOLD. Proses melalui Posting Queue."
          : "Permintaan pembayaran ditolak.",
      );
      await load();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Keputusan gagal disimpan.");
    } finally {
      setSaving(false);
    }
  }

  if (loading && !workspace) {
    return (
      <div className="grid min-h-72 place-items-center rounded-3xl border border-slate-200 bg-white">
        <div className="text-center">
          <Loader2 className="mx-auto h-7 w-7 animate-spin text-violet-600" />
          <p className="mt-3 text-sm font-bold text-slate-600">
            Memuat verifikasi pembayaran...
          </p>
        </div>
      </div>
    );
  }

  return (
    <>
      <section className="rounded-3xl border border-slate-200 bg-white shadow-sm">
        <div className="flex flex-col gap-4 border-b border-slate-200 p-6 lg:flex-row lg:items-center lg:justify-between">
          <div>
            <p className="text-xs font-black uppercase tracking-[.16em] text-violet-600">
              Maker-checker
            </p>
            <h2 className="mt-1 text-xl font-black text-slate-950">
              Verifikasi pembayaran Sales Order
            </h2>
            <p className="mt-1 max-w-3xl text-sm leading-6 text-slate-500">
              Verifikasi membuat event Finance HOLD. Jurnal baru terbentuk setelah
              event diproses melalui Posting Queue.
            </p>
          </div>
          <div className="flex flex-wrap gap-2">
            <button
              onClick={openQueue}
              className="inline-flex min-h-10 items-center gap-2 rounded-xl border border-violet-200 bg-violet-50 px-4 text-sm font-black text-violet-700"
            >
              <FileClock className="h-4 w-4" /> Posting Queue
            </button>
            <button
              onClick={() => void load()}
              disabled={loading}
              className="inline-flex min-h-10 items-center gap-2 rounded-xl border border-slate-200 px-4 text-sm font-black text-slate-700 disabled:opacity-60"
            >
              <RefreshCcw className={`h-4 w-4 ${loading ? "animate-spin" : ""}`} />
              Muat ulang
            </button>
          </div>
        </div>

        {error && (
          <div className="m-5 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-bold text-rose-700">
            {error}
          </div>
        )}

        <div className="flex gap-2 overflow-x-auto px-5 pt-5">
          {(["PENDING", "VERIFIED", "REJECTED", "ALL"] as const).map(
            (status) => (
              <button
                key={status}
                onClick={() => setFilter(status)}
                className={`min-h-10 shrink-0 rounded-xl px-4 text-sm font-black ${filter === status ? "bg-slate-950 text-white" : "bg-slate-100 text-slate-600"}`}
              >
                {status === "PENDING"
                  ? "Menunggu"
                  : status === "VERIFIED"
                    ? "Terverifikasi"
                    : status === "REJECTED"
                      ? "Ditolak"
                      : "Semua"}{" "}
                ({
                  workspace?.requests.filter(
                    (request) => status === "ALL" || request.status === status,
                  ).length ?? 0
                })
              </button>
            ),
          )}
        </div>

        <div className="space-y-4 p-5">
          {!requests.length && (
            <div className="rounded-2xl border border-dashed border-slate-300 p-10 text-center">
              <ShieldCheck className="mx-auto h-8 w-8 text-slate-400" />
              <p className="mt-3 font-black text-slate-700">
                Tidak ada permintaan pada status ini
              </p>
            </div>
          )}
          {requests.map((request) => {
            const ownRequest = request.requestedBy === workspace?.currentUserId;
            return (
              <article
                key={request.id}
                className="rounded-2xl border border-slate-200 p-5"
              >
                <div className="flex flex-col gap-4 xl:flex-row xl:items-start xl:justify-between">
                  <div>
                    <div className="flex flex-wrap items-center gap-2">
                      <p className="text-lg font-black text-slate-950">
                        {request.invoiceNo}
                      </p>
                      <span
                        className={`rounded-full px-3 py-1 text-xs font-black ${request.status === "PENDING" ? "bg-amber-100 text-amber-800" : request.status === "VERIFIED" ? "bg-emerald-100 text-emerald-800" : "bg-rose-100 text-rose-700"}`}
                      >
                        {request.status === "PENDING"
                          ? "Menunggu"
                          : request.status === "VERIFIED"
                            ? "Terverifikasi"
                            : "Ditolak"}
                      </span>
                    </div>
                    <p className="mt-1 text-sm font-bold text-slate-700">
                      {request.customerName}
                      {request.customerCode ? ` - ${request.customerCode}` : ""}
                    </p>
                    <p className="mt-1 text-sm text-slate-500">
                      {request.storeName} - {request.paymentMethodName} - {request.settlementRoute}
                    </p>
                  </div>
                  <p className="text-2xl font-black text-slate-950">
                    {money(request.amount)}
                  </p>
                </div>

                <dl className="mt-5 grid gap-3 rounded-2xl bg-slate-50 p-4 text-sm sm:grid-cols-2 xl:grid-cols-4">
                  <div>
                    <dt className="font-bold text-slate-500">Diajukan oleh</dt>
                    <dd className="mt-1 font-black text-slate-800">
                      {request.requestedByName ?? "User"}
                    </dd>
                  </div>
                  <div>
                    <dt className="font-bold text-slate-500">Waktu pengajuan</dt>
                    <dd className="mt-1 font-black text-slate-800">
                      {dateTime(request.requestedAt)}
                    </dd>
                  </div>
                  <div>
                    <dt className="font-bold text-slate-500">Timing / target</dt>
                    <dd className="mt-1 font-black text-slate-800">
                      {request.receiptTiming ?? "Menunggu verifikasi"}
                      {request.settlementTarget
                        ? ` / ${request.settlementTarget}`
                        : ""}
                    </dd>
                  </div>
                  <div>
                    <dt className="font-bold text-slate-500">Bukti</dt>
                    <dd className="mt-1">
                      {isHttps(request.proofUrl) ? (
                        <a
                          href={request.proofUrl}
                          target="_blank"
                          rel="noopener noreferrer"
                          className="inline-flex items-center gap-1 font-black text-violet-700 underline"
                        >
                          Buka bukti <ExternalLink className="h-3.5 w-3.5" />
                        </a>
                      ) : (
                        <span className="font-bold text-slate-500">Tidak ada</span>
                      )}
                    </dd>
                  </div>
                </dl>

                {request.status !== "PENDING" && (
                  <p className="mt-4 text-sm text-slate-600">
                    Diputuskan oleh {request.reviewedByName ?? "User"} pada {" "}
                    {dateTime(request.reviewedAt)}
                    {request.reviewNote ? ` - ${request.reviewNote}` : ""}
                  </p>
                )}

                {request.status === "PENDING" && (
                  <div className="mt-4 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
                    <p className={`text-sm font-bold ${ownRequest ? "text-amber-700" : "text-slate-500"}`}>
                      {ownRequest
                        ? "Maker-checker: permintaan Anda harus diputuskan user lain."
                        : "Periksa nominal, metode, customer, dan bukti sebelum memutuskan."}
                    </p>
                    <div className="flex gap-2">
                      {capabilities.has("REVIEW") && (
                        <button
                          onClick={() => beginReview(request, "REJECT")}
                          disabled={ownRequest}
                          className="min-h-10 rounded-xl border border-rose-200 px-4 text-sm font-black text-rose-700 disabled:cursor-not-allowed disabled:opacity-40"
                        >
                          Tolak
                        </button>
                      )}
                      {capabilities.has("APPROVE") && (
                        <button
                          onClick={() => beginReview(request, "VERIFY")}
                          disabled={ownRequest}
                          className="inline-flex min-h-10 items-center gap-2 rounded-xl bg-emerald-600 px-4 text-sm font-black text-white disabled:cursor-not-allowed disabled:opacity-40"
                        >
                          <BadgeCheck className="h-4 w-4" /> Verifikasi
                        </button>
                      )}
                    </div>
                  </div>
                )}
              </article>
            );
          })}
        </div>
      </section>

      {review && (
        <ReviewDialog
          review={review}
          note={note}
          setNote={setNote}
          saving={saving}
          close={() => !saving && setReview(null)}
          submit={() => void submitReview()}
        />
      )}
    </>
  );
}

function ReviewDialog({
  review,
  note,
  setNote,
  saving,
  close,
  submit,
}: {
  review: ReviewAction;
  note: string;
  setNote: (value: string) => void;
  saving: boolean;
  close: () => void;
  submit: () => void;
}) {
  useEscapeClose(close);
  const verify = review.action === "VERIFY";
  return (
    <div className="fixed inset-0 z-[80] grid place-items-center bg-slate-950/55 p-4">
      <div className="w-full max-w-lg rounded-3xl bg-white p-6 shadow-2xl">
        <div className="flex items-start justify-between gap-4">
          <div>
            <p className="text-xs font-black uppercase tracking-[.16em] text-violet-600">
              Keputusan Finance
            </p>
            <h3 className="mt-2 text-xl font-black text-slate-950">
              {verify ? "Verifikasi pembayaran" : "Tolak pembayaran"}
            </h3>
            <p className="mt-1 text-sm text-slate-500">
              {review.request.invoiceNo} - {money(review.request.amount)}
            </p>
          </div>
          <button
            onClick={close}
            disabled={saving}
            aria-label="Tutup"
            className="grid h-10 w-10 place-items-center rounded-xl bg-slate-100 disabled:opacity-50"
          >
            <X className="h-5 w-5" />
          </button>
        </div>

        <div className={`mt-5 rounded-2xl border p-4 text-sm leading-6 ${verify ? "border-emerald-200 bg-emerald-50 text-emerald-900" : "border-rose-200 bg-rose-50 text-rose-900"}`}>
          {verify ? (
            <><ShieldCheck className="mr-2 inline h-4 w-4" />Keputusan ini membuat event HOLD; jurnal belum terposting otomatis.</>
          ) : (
            <><CircleAlert className="mr-2 inline h-4 w-4" />Penolakan pembayaran tunai memerlukan sesi kasir sumber masih terbuka.</>
          )}
        </div>

        <label className="mt-5 block text-sm font-black text-slate-700">
          Catatan keputusan (opsional)
          <textarea
            value={note}
            onChange={(event) => setNote(event.target.value.slice(0, 500))}
            rows={4}
            className="mt-2 w-full rounded-2xl border border-slate-300 p-3 font-normal outline-none focus:border-violet-500"
            placeholder="Catatan pemeriksaan Finance"
          />
        </label>
        <p className="mt-1 text-right text-xs text-slate-400">{note.length}/500</p>

        <div className="mt-6 flex justify-end gap-3">
          <button
            onClick={close}
            disabled={saving}
            className="min-h-11 rounded-xl border border-slate-200 px-5 text-sm font-black text-slate-700 disabled:opacity-50"
          >
            Batal
          </button>
          <button
            onClick={submit}
            disabled={saving}
            className={`inline-flex min-h-11 items-center gap-2 rounded-xl px-5 text-sm font-black text-white disabled:opacity-50 ${verify ? "bg-emerald-600" : "bg-rose-600"}`}
          >
            {saving && <Loader2 className="h-4 w-4 animate-spin" />}
            {verify ? "Ya, verifikasi" : "Ya, tolak"}
          </button>
        </div>
      </div>
    </div>
  );
}
