"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import {
  Activity,
  Building2,
  CheckCircle2,
  CircleAlert,
  Clock3,
  RefreshCw,
  Search,
  ShieldCheck,
  TriangleAlert,
} from "lucide-react";

type HealthStatus = "HEALTHY" | "WARNING" | "CRITICAL";

type CompanyMetrics = {
  openCashierSessions: number;
  staleCashierSessions: number;
  activeFinanceQueues: number;
  staleFinanceQueues: number;
  openFinanceExceptions: number;
  holdFinancialEvents: number;
  stuckImportJobs: number;
  recentImportFailures: number;
  stuckOfflineSubmissions: number;
  offlineSubmissionsNeedingAttention: number;
  openReservations: number;
  staleReservations: number;
  openDeliveries: number;
  staleDeliveries: number;
  openProcurementDemands: number;
  staleProcurementDemands: number;
  pendingPaymentVerifications: number;
  stalePaymentVerifications: number;
  openNegativeAllocations: number;
  openNegativeBaseQty: number;
  pendingCostAdjustments: number;
};

type CompanyHealth = {
  companyId: string;
  companyCode: string;
  companyName: string;
  companyStatus: string;
  healthStatus: HealthStatus;
  metrics: CompanyMetrics;
};

type HealthIssue = {
  companyId: string;
  companyCode: string;
  companyName: string;
  severity: "WARNING" | "CRITICAL";
  moduleCode: string;
  issueCode: string;
  count: number;
  oldestAt: string | null;
  nextAction: string;
};

type HealthPayload = {
  contractVersion: number;
  generatedAt: string;
  databaseMigrationVersion: string | null;
  refreshMode: "MANUAL";
  readOnly: true;
  summary: {
    companies: number;
    activeCompanies: number;
    healthyCompanies: number;
    warningCompanies: number;
    criticalCompanies: number;
    totalIssues: number;
  };
  companies: CompanyHealth[];
  issues: HealthIssue[];
};

const statusMeta: Record<HealthStatus, {
  label: string;
  badge: string;
  border: string;
  icon: typeof CheckCircle2;
}> = {
  HEALTHY: {
    label: "Sehat",
    badge: "bg-emerald-50 text-emerald-700",
    border: "border-emerald-200",
    icon: CheckCircle2,
  },
  WARNING: {
    label: "Perlu perhatian",
    badge: "bg-amber-50 text-amber-700",
    border: "border-amber-200",
    icon: TriangleAlert,
  },
  CRITICAL: {
    label: "Kritis",
    badge: "bg-rose-50 text-rose-700",
    border: "border-rose-200",
    icon: CircleAlert,
  },
};

const issueLabels: Record<string, string> = {
  OPEN_FINANCE_EXCEPTION: "Exception posting Finance",
  OFFLINE_SUBMISSION_NEEDS_ATTENTION: "Submission Offline bermasalah",
  STALE_FINANCE_QUEUE: "Queue Finance terlalu lama aktif",
  STALE_CASHIER_SESSION: "Sesi kasir terlalu lama terbuka",
  STUCK_IMPORT_JOB: "Import tidak bergerak",
  RECENT_IMPORT_FAILURE: "Import gagal atau selesai dengan error",
  STUCK_OFFLINE_SUBMISSION: "Submission Offline tertahan",
  STALE_RESERVATION: "Reserved Out belum ditindaklanjuti",
  STALE_DELIVERY: "Surat Jalan belum selesai",
  STALE_PROCUREMENT_DEMAND: "Demand pembelian belum selesai",
  STALE_PAYMENT_VERIFICATION: "Verifikasi pembayaran tertunda",
  HOLD_FINANCIAL_EVENT: "Event Finance masih HOLD",
  OPEN_NEGATIVE_STOCK_COST: "Biaya stok minus belum diselesaikan",
  PENDING_COST_ADJUSTMENT: "Penyesuaian biaya belum diposting",
};

function authHeaders(session: Session) {
  return { Authorization: `Bearer ${session.access_token}` };
}

function formatDate(value: string | null) {
  if (!value) return "—";
  return new Intl.DateTimeFormat("id-ID", {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(new Date(value));
}

function number(value: number) {
  return new Intl.NumberFormat("id-ID", { maximumFractionDigits: 6 })
    .format(Number(value) || 0);
}

async function responseData(response: Response) {
  const contentType = response.headers.get("content-type") ?? "";
  if (!contentType.includes("application/json")) {
    throw new Error("PLATFORM_HEALTH_INVALID_RESPONSE");
  }
  const payload = await response.json() as {
    data?: HealthPayload;
    error?: string;
  };
  if (!response.ok) throw new Error(payload.error ?? "PLATFORM_HEALTH_LOAD_FAILED");
  if (!payload.data || payload.data.contractVersion !== 1) {
    throw new Error("PLATFORM_HEALTH_RUNTIME_NOT_READY");
  }
  return payload.data;
}

export function PlatformOperationalHealthView({
  session,
}: {
  session: Session;
}) {
  const [payload, setPayload] = useState<HealthPayload | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [query, setQuery] = useState("");
  const [status, setStatus] = useState<"ALL" | HealthStatus>("ALL");
  const [selectedCompanyId, setSelectedCompanyId] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const response = await fetch("/api/platform/operational-health", {
        headers: authHeaders(session),
        cache: "no-store",
      });
      setPayload(await responseData(response));
    } catch (loadError) {
      setError(loadError instanceof Error
        ? loadError.message
        : "PLATFORM_HEALTH_LOAD_FAILED");
    } finally {
      setLoading(false);
    }
  }, [session]);

  useEffect(() => {
    let active = true;
    fetch("/api/platform/operational-health", {
      headers: authHeaders(session),
      cache: "no-store",
    })
      .then(responseData)
      .then((data) => {
        if (active) setPayload(data);
      })
      .catch((loadError: unknown) => {
        if (active) {
          setError(loadError instanceof Error
            ? loadError.message
            : "PLATFORM_HEALTH_LOAD_FAILED");
        }
      })
      .finally(() => {
        if (active) setLoading(false);
      });
    return () => { active = false; };
  }, [session]);

  const companies = useMemo(() => {
    const normalized = query.trim().toLocaleLowerCase("id-ID");
    return (payload?.companies ?? []).filter((company) =>
      (status === "ALL" || company.healthStatus === status)
      && (!normalized
        || company.companyName.toLocaleLowerCase("id-ID").includes(normalized)
        || company.companyCode.toLocaleLowerCase("id-ID").includes(normalized)));
  }, [payload, query, status]);

  const selectedIssues = useMemo(() => {
    if (!selectedCompanyId) return payload?.issues ?? [];
    return (payload?.issues ?? []).filter((issue) =>
      issue.companyId === selectedCompanyId);
  }, [payload, selectedCompanyId]);

  return (
    <div className="space-y-6">
      <header className="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
        <div>
          <div className="flex flex-wrap items-center gap-2">
            <p className="text-xs font-bold uppercase tracking-[.16em] text-emerald-600">
              Platform · Observability
            </p>
            <span className="inline-flex items-center gap-1 rounded-full bg-slate-100 px-2.5 py-1 text-[11px] font-bold text-slate-600">
              <ShieldCheck className="h-3.5 w-3.5" /> Read-only
            </span>
          </div>
          <h1 className="mt-2 text-2xl font-black tracking-tight text-slate-950 md:text-3xl">
            Health Operasional
          </h1>
          <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-500">
            Diagnosis lintas Company untuk Super Admin. Halaman ini tidak
            memperbaiki data otomatis dan tidak melakukan refresh di latar belakang.
          </p>
        </div>
        <button
          type="button"
          onClick={() => void load()}
          disabled={loading}
          className="inline-flex items-center justify-center gap-2 rounded-xl border border-slate-200 bg-white px-4 py-3 text-sm font-bold text-slate-700 shadow-sm disabled:opacity-50"
        >
          <RefreshCw className={`h-4 w-4 ${loading ? "animate-spin" : ""}`} />
          Muat ulang manual
        </button>
      </header>

      {error && (
        <div className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-700">
          <b>Dashboard tidak dapat dimuat.</b> {error}. Operasional lain tetap
          berjalan karena dashboard ini terisolasi dari mutation transaksi.
        </div>
      )}

      {payload && (
        <>
          <section className="grid gap-3 sm:grid-cols-2 xl:grid-cols-5">
            <SummaryCard label="Seluruh Company" value={payload.summary.companies}
              icon={Building2} tone="slate" />
            <SummaryCard label="Sehat" value={payload.summary.healthyCompanies}
              icon={CheckCircle2} tone="emerald" />
            <SummaryCard label="Perlu perhatian" value={payload.summary.warningCompanies}
              icon={TriangleAlert} tone="amber" />
            <SummaryCard label="Kritis" value={payload.summary.criticalCompanies}
              icon={CircleAlert} tone="rose" />
            <SummaryCard label="Total indikasi" value={payload.summary.totalIssues}
              icon={Activity} tone="blue" />
          </section>

          <section className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
            <div className="grid gap-3 lg:grid-cols-[1fr_auto]">
              <label className="relative block">
                <Search className="pointer-events-none absolute left-3 top-3.5 h-4 w-4 text-slate-400" />
                <input value={query} onChange={(event) => setQuery(event.target.value)}
                  placeholder="Cari nama atau kode Company"
                  className="w-full rounded-xl border border-slate-200 py-3 pl-10 pr-3 text-sm outline-none focus:border-emerald-500" />
              </label>
              <div className="flex flex-wrap gap-2">
                {(["ALL", "CRITICAL", "WARNING", "HEALTHY"] as const).map((item) => (
                  <button key={item} type="button" onClick={() => setStatus(item)}
                    className={`rounded-xl px-3 py-2.5 text-xs font-bold ${status === item
                      ? "bg-slate-950 text-white"
                      : "border border-slate-200 bg-white text-slate-600"}`}>
                    {item === "ALL" ? "Semua" : statusMeta[item].label}
                  </button>
                ))}
              </div>
            </div>
            <div className="mt-3 flex flex-wrap gap-x-5 gap-y-1 text-xs text-slate-400">
              <span>Snapshot: {formatDate(payload.generatedAt)}</span>
              <span>Migration DB: {payload.databaseMigrationVersion ?? "Tidak diketahui"}</span>
              <span>Refresh: manual</span>
            </div>
          </section>

          <section className="grid gap-4 xl:grid-cols-2">
            {companies.map((company) => (
              <CompanyCard key={company.companyId} company={company}
                issueCount={(payload.issues ?? []).filter((issue) =>
                  issue.companyId === company.companyId).length}
                selected={selectedCompanyId === company.companyId}
                select={() => setSelectedCompanyId((current) =>
                  current === company.companyId ? null : company.companyId)} />
            ))}
          </section>

          {!companies.length && (
            <div className="rounded-2xl border border-dashed border-slate-300 p-10 text-center text-sm text-slate-500">
              Tidak ada Company yang sesuai filter.
            </div>
          )}

          <section className="rounded-2xl border border-slate-200 bg-white shadow-sm">
            <div className="border-b border-slate-100 p-5">
              <h2 className="font-black text-slate-950">Daftar indikasi</h2>
              <p className="mt-1 text-sm text-slate-500">
                {selectedCompanyId
                  ? "Difilter mengikuti Company yang dipilih. Klik Company lagi untuk melihat semua."
                  : "Prioritas tracing lintas Company tanpa tindakan perbaikan otomatis."}
              </p>
            </div>
            <div className="divide-y divide-slate-100">
              {selectedIssues.map((issue, index) => (
                <IssueRow key={`${issue.companyId}-${issue.issueCode}-${index}`} issue={issue} />
              ))}
              {!selectedIssues.length && (
                <div className="p-8 text-center text-sm text-slate-500">
                  Tidak ada indikasi yang memenuhi threshold pada snapshot ini.
                </div>
              )}
            </div>
          </section>
        </>
      )}
    </div>
  );
}

function SummaryCard({ label, value, icon: Icon, tone }: {
  label: string;
  value: number;
  icon: typeof Activity;
  tone: "slate" | "emerald" | "amber" | "rose" | "blue";
}) {
  const tones = {
    slate: "bg-slate-100 text-slate-700",
    emerald: "bg-emerald-50 text-emerald-700",
    amber: "bg-amber-50 text-amber-700",
    rose: "bg-rose-50 text-rose-700",
    blue: "bg-blue-50 text-blue-700",
  };
  return <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
    <div className={`grid h-10 w-10 place-items-center rounded-xl ${tones[tone]}`}>
      <Icon className="h-5 w-5" />
    </div>
    <p className="mt-4 text-2xl font-black text-slate-950">{number(value)}</p>
    <p className="mt-1 text-xs font-semibold text-slate-500">{label}</p>
  </div>;
}

function CompanyCard({ company, issueCount, selected, select }: {
  company: CompanyHealth;
  issueCount: number;
  selected: boolean;
  select: () => void;
}) {
  const meta = statusMeta[company.healthStatus];
  const Icon = meta.icon;
  const metricItems = [
    ["Sesi terbuka", company.metrics.openCashierSessions],
    ["Reserved Out", company.metrics.openReservations],
    ["Pengiriman aktif", company.metrics.openDeliveries],
    ["Demand pembelian", company.metrics.openProcurementDemands],
    ["Pembayaran pending", company.metrics.pendingPaymentVerifications],
    ["Finance HOLD", company.metrics.holdFinancialEvents],
    ["Stok minus terbuka", company.metrics.openNegativeAllocations],
    ["Qty minus terbuka", company.metrics.openNegativeBaseQty],
  ] as const;
  return <button type="button" onClick={select}
    className={`rounded-2xl border bg-white p-5 text-left shadow-sm transition hover:shadow-md ${selected
      ? "border-slate-950 ring-2 ring-slate-950/10"
      : meta.border}`}>
    <div className="flex items-start gap-3">
      <div className={`grid h-11 w-11 shrink-0 place-items-center rounded-xl ${meta.badge}`}>
        <Icon className="h-5 w-5" />
      </div>
      <div className="min-w-0 flex-1">
        <div className="flex flex-wrap items-center gap-2">
          <h3 className="font-black text-slate-950">{company.companyName}</h3>
          <span className={`rounded-full px-2.5 py-1 text-[11px] font-bold ${meta.badge}`}>
            {meta.label}
          </span>
        </div>
        <p className="mt-1 text-xs font-semibold text-slate-400">
          {company.companyCode} · Tenant {company.companyStatus}
        </p>
      </div>
      <span className="rounded-full bg-slate-100 px-2.5 py-1 text-xs font-bold text-slate-600">
        {issueCount} indikasi
      </span>
    </div>
    <div className="mt-5 grid grid-cols-2 gap-x-4 gap-y-3 sm:grid-cols-4">
      {metricItems.map(([label, value]) => <div key={label}>
        <p className="font-black text-slate-900">{number(value)}</p>
        <p className="mt-0.5 text-[11px] font-semibold leading-4 text-slate-400">{label}</p>
      </div>)}
    </div>
  </button>;
}

function IssueRow({ issue }: { issue: HealthIssue }) {
  const critical = issue.severity === "CRITICAL";
  return <div className="grid gap-3 p-5 lg:grid-cols-[minmax(0,1fr)_170px_minmax(280px,1.2fr)] lg:items-center">
    <div className="flex items-start gap-3">
      <div className={`mt-0.5 grid h-9 w-9 shrink-0 place-items-center rounded-xl ${critical
        ? "bg-rose-50 text-rose-600"
        : "bg-amber-50 text-amber-600"}`}>
        {critical ? <CircleAlert className="h-4 w-4" /> : <TriangleAlert className="h-4 w-4" />}
      </div>
      <div>
        <div className="flex flex-wrap items-center gap-2">
          <p className="font-bold text-slate-950">
            {issueLabels[issue.issueCode] ?? issue.issueCode}
          </p>
          <span className="rounded-full bg-slate-100 px-2 py-0.5 text-[10px] font-bold text-slate-600">
            {issue.moduleCode}
          </span>
        </div>
        <p className="mt-1 text-xs text-slate-500">
          {issue.companyName} ({issue.companyCode}) · {number(issue.count)} item
        </p>
      </div>
    </div>
    <div className="flex items-center gap-2 text-xs text-slate-500">
      <Clock3 className="h-4 w-4 text-slate-400" />
      Terlama: {formatDate(issue.oldestAt)}
    </div>
    <p className="text-sm leading-6 text-slate-600">{issue.nextAction}</p>
  </div>;
}
