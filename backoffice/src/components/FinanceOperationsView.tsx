"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import {
  BarChart3,
  BookOpen,
  CalendarRange,
  CheckCircle2,
  ChevronDown,
  ChevronUp,
  CircleAlert,
  Download,
  FileClock,
  Landmark,
  Loader2,
  LockKeyhole,
  Play,
  RefreshCcw,
  RotateCcw,
  Search,
  ShieldAlert,
  BadgeCheck,
  Unlock,
  X,
} from "lucide-react";
import { useEscapeClose } from "@/lib/use-escape-close";
import { SalesPaymentVerificationPanel } from "@/components/SalesPaymentVerificationPanel";

type Period = {
  id: string;
  period_year: number;
  period_month: number;
  start_date: string;
  end_date: string;
  status: "OPEN" | "LOCKED" | "REOPENED";
  master_version: number | string;
  closed_at: string | null;
  reopened_at: string | null;
  reopen_reason: string | null;
};

type Journal = {
  id: string;
  journal_no: string;
  display_no: string;
  journal_type:
    | "AUTOMATIC"
    | "MANUAL"
    | "OPENING_BALANCE"
    | "REVERSAL"
    | "PRIOR_PERIOD_ADJUSTMENT";
  accounting_period_id: string;
  accounting_date: string;
  original_event_date: string | null;
  source_type: string;
  source_id: string;
  system_event_key: string | null;
  description: string;
  status: "DRAFT" | "POSTED" | "CANCELED";
  total_debit: number | string;
  total_credit: number | string;
  reversal_of_journal_id: string | null;
  master_version: number | string;
  created_at: string;
  posted_at: string | null;
};

type JournalLine = {
  id: string;
  journal_id: string;
  line_no: number;
  account_id: string;
  account_code_snapshot: string;
  account_name_snapshot: string;
  debit: number | string;
  credit: number | string;
  store_id: string | null;
  warehouse_id: string | null;
  customer_id: string | null;
  supplier_id: string | null;
  description: string | null;
};

type QueueRun = {
  id: string;
  queue_no: string;
  display_no: string;
  scope_system_key: string;
  status:
    | "PREVIEWED"
    | "APPROVED"
    | "PROCESSING"
    | "COMPLETED"
    | "COMPLETED_WITH_ERRORS";
  preview_limit: number;
  previewed_event_count: number;
  posted_count: number;
  failed_count: number;
  skipped_count: number;
  master_version: number | string;
  created_at: string;
  approved_at: string | null;
  processing_started_at: string | null;
  processed_at: string | null;
};

type QueueItem = {
  id: string;
  queue_run_id: string;
  line_no: number;
  event_code_snapshot: string;
  system_event_key_snapshot: string;
  event_date_snapshot: string;
  status: string;
  attempt_count: number;
  journal_id: string | null;
  error_code: string | null;
  error_message: string | null;
  processed_at: string | null;
};

type ExceptionRow = {
  id: string;
  display_no: string;
  reason_code: string;
  status: string;
  retry_count: number;
  last_error: string | null;
  created_at: string;
};

type Account = {
  id: string;
  account_code: string;
  account_name: string;
  account_type: string;
  is_active: boolean;
  is_postable: boolean;
};

type Workspace = {
  companyId: string;
  company: {
    company_name: string;
    company_code: string;
    timezone: string;
  };
  periods: Period[];
  journals: Journal[];
  journalLines: JournalLine[];
  reversedJournalIds: string[];
  queueRuns: QueueRun[];
  queueItems: QueueItem[];
  exceptions: ExceptionRow[];
  accounts: Account[];
  policy: {
    periodCreationMode: "MANUAL" | "AUTOMATIC";
    postingMode: "CONTROLLED" | "AUTOMATIC";
    masterVersion: number | string;
  };
};

type ReportCode =
  | "TRIAL_BALANCE"
  | "INCOME_STATEMENT"
  | "BALANCE_SHEET"
  | "PENDING_ANALYSIS"
  | "RECONCILIATION_SUMMARY";

type ReportData = Record<string, unknown>;
type Tab =
  | "overview"
  | "ledger"
  | "journals"
  | "periods"
  | "payments"
  | "queue"
  | "reports";
type DialogAction =
  | { type: "REVERSE"; journal: Journal }
  | { type: "LOCK"; period: Period }
  | { type: "REOPEN"; period: Period }
  | { type: "CREATE_PERIOD" }
  | { type: "PREVIEW_QUEUE" }
  | { type: "PROCESS_AUTOMATIC" }
  | { type: "APPROVE_QUEUE"; run: QueueRun }
  | { type: "PROCESS_QUEUE"; run: QueueRun };

type Props = {
  session: Session;
  companyId: string;
  canCreatePeriod: boolean;
  canLockPeriod: boolean;
  canReopenPeriod: boolean;
  canReverseJournal: boolean;
  canOperateQueue: boolean;
  canManagePostingPolicy: boolean;
  notify: (message: string) => void;
};

const reportLabels: Record<ReportCode, string> = {
  TRIAL_BALANCE: "Neraca Saldo",
  INCOME_STATEMENT: "Laba Rugi",
  BALANCE_SHEET: "Neraca",
  PENDING_ANALYSIS: "Transaksi Belum Masuk Laporan",
  RECONCILIATION_SUMMARY: "Ringkasan Rekonsiliasi",
};

const statusLabels: Record<string, string> = {
  OPEN: "Terbuka",
  LOCKED: "Dikunci",
  REOPENED: "Dibuka kembali",
  DRAFT: "Draft",
  POSTED: "Terposting",
  CANCELED: "Dibatalkan",
  PREVIEWED: "Sudah ditinjau",
  APPROVED: "Disetujui",
  PROCESSING: "Diproses",
  COMPLETED: "Selesai",
  COMPLETED_WITH_ERRORS: "Selesai dengan error",
  READY: "Siap",
  FAILED: "Gagal",
  SKIPPED: "Dilewati",
  MATCHED: "Sesuai",
  UNMATCHED: "Selisih",
  DEFERRED: "Ditunda",
};

const journalTypeLabels: Record<string, string> = {
  AUTOMATIC: "Otomatis",
  MANUAL: "Manual",
  OPENING_BALANCE: "Saldo Awal",
  REVERSAL: "Pembalik",
  PRIOR_PERIOD_ADJUSTMENT: "Koreksi Periode Sebelumnya",
};

const friendlyErrors: Record<string, string> = {
  MASTER_VERSION_CONFLICT:
    "Data sudah berubah. Muat ulang sebelum mencoba lagi.",
  REVERSAL_REASON_REQUIRED: "Alasan pembalikan wajib diisi.",
  OPEN_ACCOUNTING_PERIOD_REQUIRED:
    "Tanggal pembalikan harus berada pada periode terbuka.",
  SOURCE_DOCUMENT_REVERSAL_REQUIRED:
    "Jurnal otomatis harus dikoreksi melalui dokumen sumbernya.",
  JOURNAL_ALREADY_REVERSED: "Jurnal ini sudah mempunyai jurnal pembalik.",
  FINANCE_JOURNAL_REVERSAL_ROLE_REQUIRED:
    "Role ini tidak boleh membalik jurnal.",
  ACCOUNTING_PERIOD_HAS_DRAFT_JOURNAL: "Periode masih mempunyai jurnal Draft.",
  ACCOUNTING_PERIOD_HAS_UNPOSTED_EVENT:
    "Periode masih mempunyai transaksi Finance yang belum terposting.",
  ACCOUNTING_PERIOD_NOT_OPEN: "Periode ini tidak dalam keadaan terbuka.",
  ACCOUNTING_PERIOD_NOT_LOCKED:
    "Hanya periode yang dikunci yang dapat dibuka kembali.",
  REOPEN_REASON_REQUIRED: "Alasan membuka kembali periode wajib diisi.",
  ACCOUNTING_PERIOD_ALREADY_EXISTS: "Periode bulan tersebut sudah tersedia.",
  ACTIVE_FINANCE_POSTING_QUEUE_ALREADY_EXISTS:
    "Masih ada antrean Finance aktif.",
  ACTIVE_FINANCE_POSTING_QUEUE_EXISTS:
    "Selesaikan antrean Finance aktif sebelum mengganti mode posting.",
  FINANCE_POSTING_POLICY_ADMIN_REQUIRED:
    "Hanya Owner atau Admin Company yang dapat mengganti kebijakan posting.",
  FINANCE_AUTOMATIC_POSTING_DISABLED:
    "Mode posting otomatis belum aktif untuk Company ini.",
  CONTROLLED_QUEUE_DISABLED_IN_AUTOMATIC_MODE:
    "Controlled queue tidak digunakan ketika mode posting otomatis aktif.",
  NO_SUPPORTED_HOLD_EVENTS:
    "Tidak ada transaksi HOLD canonical yang dapat diproses.",
  QUEUE_PREVIEW_STALE:
    "Isi antrean berubah. Buat preview baru setelah kondisi diperiksa.",
  FINANCE_POSTING_QUEUE_NOT_PREVIEWED:
    "Antrean belum berada pada tahap preview.",
  FINANCE_POSTING_QUEUE_NOT_APPROVED: "Antrean belum disetujui.",
  HISTORICAL_SUBLEDGER_SNAPSHOT_UNAVAILABLE:
    "Rekonsiliasi saat ini hanya tersedia untuk tanggal hari ini.",
  INVALID_SESSION: "Sesi login kedaluwarsa. Silakan login kembali.",
};

function authHeaders(session: Session) {
  return { Authorization: `Bearer ${session.access_token}` };
}

function money(value: unknown) {
  return new Intl.NumberFormat("id-ID", {
    style: "currency",
    currency: "IDR",
    maximumFractionDigits: 0,
  }).format(Number(value) || 0);
}

function localDate(value: string | null | undefined) {
  if (!value) return "-";
  return new Date(
    value.length === 10 ? `${value}T00:00:00` : value,
  ).toLocaleDateString("id-ID", {
    day: "2-digit",
    month: "short",
    year: "numeric",
  });
}

function today() {
  const now = new Date();
  return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}-${String(now.getDate()).padStart(2, "0")}`;
}

function monthStart() {
  return `${today().slice(0, 8)}01`;
}

function currentMonth() {
  return today().slice(0, 7);
}

function monthRange(month: string) {
  const [year, monthNumber] = month.split("-").map(Number);
  const lastDay = new Date(year, monthNumber, 0).getDate();
  return {
    dateFrom: `${month}-01`,
    asOf: `${month}-${String(lastDay).padStart(2, "0")}`,
  };
}

async function downloadFinanceExport(
  session: Session,
  type: "GENERAL_LEDGER" | "JOURNAL_ENTRIES",
  month: string,
) {
  const query = new URLSearchParams({ type, month });
  const response = await fetch(`/api/finance/operations/export?${query}`, {
    headers: authHeaders(session),
    cache: "no-store",
  });
  if (!response.ok) {
    const result = await readApiJson<{ error?: string }>(response);
    throw new Error(friendly(result.error));
  }
  const blob = await response.blob();
  const disposition = response.headers.get("content-disposition") ?? "";
  const filename =
    disposition.match(/filename="([^"]+)"/)?.[1] ?? `${type}_${month}.xlsx`;
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = filename;
  anchor.click();
  URL.revokeObjectURL(url);
}

function friendly(code: string | undefined) {
  if (!code) return "Operasi Finance gagal.";
  const exact = Object.keys(friendlyErrors).find((key) => code.includes(key));
  return exact ? friendlyErrors[exact] : code;
}

async function readApiJson<T>(response: Response): Promise<T> {
  const raw = await response.text();
  if (!raw.trim()) {
    throw new Error(
      `Server Backoffice tidak mengirim respons (HTTP ${response.status}).`,
    );
  }
  try {
    return JSON.parse(raw) as T;
  } catch {
    if (raw.trimStart().startsWith("<")) {
      throw new Error(
        `Endpoint Finance belum termuat oleh server Backoffice (HTTP ${response.status}). Restart proses Backoffice lalu muat ulang halaman.`,
      );
    }
    throw new Error(
      `Respons server Finance tidak valid (HTTP ${response.status}).`,
    );
  }
}

function Status({ value }: { value: string }) {
  const risk =
    value.includes("ERROR") || value === "FAILED" || value === "UNMATCHED";
  const warning = [
    "LOCKED",
    "PREVIEWED",
    "APPROVED",
    "DEFERRED",
    "DRAFT",
  ].includes(value);
  return (
    <span
      className={`inline-flex rounded-full px-2.5 py-1 text-[11px] font-black ${
        risk
          ? "bg-rose-50 text-rose-700"
          : warning
            ? "bg-amber-50 text-amber-700"
            : "bg-emerald-50 text-emerald-700"
      }`}
    >
      {statusLabels[value] ?? value}
    </span>
  );
}

export function FinanceOperationsView(props: Props) {
  const [data, setData] = useState<Workspace | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [tab, setTab] = useState<Tab>("overview");
  const [dialog, setDialog] = useState<DialogAction | null>(null);
  const [expandedJournal, setExpandedJournal] = useState<string | null>(null);
  const [expandedQueue, setExpandedQueue] = useState<string | null>(null);
  const [search, setSearch] = useState("");
  const [journalMonth, setJournalMonth] = useState(currentMonth());

  const load = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      const query = new URLSearchParams({ journalMonth });
      const response = await fetch(`/api/finance/operations?${query}`, {
        headers: authHeaders(props.session),
        cache: "no-store",
      });
      const result = await readApiJson<Workspace & { error?: string }>(
        response,
      );
      if (!response.ok) throw new Error(friendly(result.error));
      setData(result);
    } catch (caught) {
      setError(
        caught instanceof Error
          ? caught.message
          : "Workspace Finance gagal dimuat.",
      );
    } finally {
      setLoading(false);
    }
  }, [journalMonth, props.session]);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- remote Finance workspace follows active tenant
    void load();
  }, [load, props.companyId]);

  const reversedIds = useMemo(
    () => new Set(data?.reversedJournalIds ?? []),
    [data?.reversedJournalIds],
  );
  const journalLines = useMemo(() => {
    const grouped = new Map<string, JournalLine[]>();
    for (const line of data?.journalLines ?? []) {
      grouped.set(line.journal_id, [
        ...(grouped.get(line.journal_id) ?? []),
        line,
      ]);
    }
    return grouped;
  }, [data?.journalLines]);
  const queueItems = useMemo(() => {
    const grouped = new Map<string, QueueItem[]>();
    for (const item of data?.queueItems ?? []) {
      grouped.set(item.queue_run_id, [
        ...(grouped.get(item.queue_run_id) ?? []),
        item,
      ]);
    }
    return grouped;
  }, [data?.queueItems]);
  const filteredJournals = useMemo(() => {
    const query = search.trim().toLowerCase();
    return (data?.journals ?? []).filter(
      (journal) =>
        journal.accounting_date.startsWith(journalMonth) &&
        (!query ||
          [
            journal.display_no,
            journal.description,
            journal.source_type,
            journal.system_event_key,
          ]
            .filter(Boolean)
            .some((value) => String(value).toLowerCase().includes(query))),
    );
  }, [data?.journals, journalMonth, search]);

  if (loading && !data) {
    return (
      <div className="grid min-h-[420px] place-items-center rounded-3xl border border-slate-200 bg-white">
        <div className="text-center">
          <Loader2 className="mx-auto h-7 w-7 animate-spin text-violet-600" />
          <p className="mt-3 text-sm font-bold text-slate-600">
            Memuat Finance canonical…
          </p>
        </div>
      </div>
    );
  }

  const posted =
    data?.journals.filter((row) => row.status === "POSTED").length ?? 0;
  const activeQueue = data?.queueRuns.find((row) =>
    ["PREVIEWED", "APPROVED", "PROCESSING"].includes(row.status),
  );
  const openPeriods =
    data?.periods.filter((row) => ["OPEN", "REOPENED"].includes(row.status))
      .length ?? 0;

  return (
    <>
      <div className="mb-7 flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
        <div>
          <p className="text-xs font-black uppercase tracking-[.18em] text-violet-600">
            Finance · Company aktif
          </p>
          <h1 className="mt-2 text-3xl font-black text-slate-950">
            Operasi & laporan keuangan
          </h1>
          <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-500">
            Jurnal POSTED, periode, controlled posting queue, laporan, dan
            pembalikan resmi berada dalam satu workspace. Transaksi HOLD tidak
            masuk laporan sampai benar-benar terposting.
          </p>
        </div>
        <button
          onClick={() => void load()}
          disabled={loading}
          className="inline-flex min-h-11 items-center justify-center gap-2 rounded-xl border border-slate-200 bg-white px-4 text-sm font-black text-slate-700 shadow-sm disabled:opacity-60"
        >
          <RefreshCcw className={`h-4 w-4 ${loading ? "animate-spin" : ""}`} />
          Muat ulang
        </button>
      </div>

      <div className="mb-5 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm leading-6 text-amber-900">
        <b>Batas aman pilot:</b> controlled queue hanya mengambil event final
        yang didukung canonical Finance. Mode otomatis tidak mengubah dokumen
        sumber; kegagalan tetap HOLD dan masuk exception untuk diperbaiki.
      </div>
      {error && (
        <div className="mb-5 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-bold text-rose-700">
          {error}
        </div>
      )}

      <div className="mb-6 grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <Metric
          label="Jurnal POSTED bulan terpilih"
          value={posted.toLocaleString("id-ID")}
          note="Canonical journal"
          icon={BookOpen}
        />
        <Metric
          label="Periode terbuka"
          value={openPeriods.toLocaleString("id-ID")}
          note="OPEN / REOPENED"
          icon={CalendarRange}
        />
        <Metric
          label="Antrean aktif"
          value={activeQueue ? "1" : "0"}
          note={activeQueue ? activeQueue.display_no : "Tidak ada"}
          icon={FileClock}
        />
        <Metric
          label="Exception terbuka"
          value={(data?.exceptions.length ?? 0).toLocaleString("id-ID")}
          note="Perlu investigasi"
          icon={CircleAlert}
        />
      </div>

      <nav className="mb-6 flex gap-2 overflow-x-auto rounded-2xl border border-slate-200 bg-white p-2 shadow-sm">
        {(
          [
            ["overview", "Ringkasan", Landmark],
            ["ledger", "Buku Besar", Landmark],
            ["journals", "Journal Entries", BookOpen],
            ["periods", "Periode", CalendarRange],
            ["payments", "Verifikasi Bayar", BadgeCheck],
            ["queue", "Posting Queue", FileClock],
            ["reports", "Laporan", BarChart3],
          ] as [Tab, string, typeof Landmark][]
        ).map(([id, label, Icon]) => (
          <button
            key={id}
            onClick={() => setTab(id)}
            className={`inline-flex min-h-10 shrink-0 items-center gap-2 rounded-xl px-4 text-sm font-black ${tab === id ? "bg-violet-600 text-white shadow" : "text-slate-600 hover:bg-slate-100"}`}
          >
            <Icon className="h-4 w-4" />
            {label}
          </button>
        ))}
      </nav>

      {tab === "overview" && <Overview data={data} setTab={setTab} />}
      {tab === "ledger" && (
        <GeneralLedgerPanel
          session={props.session}
          onOpenJournal={(displayNo) => {
            setSearch(displayNo);
            setJournalMonth(displayNo.slice(4, 11).replace("/", "-"));
            setTab("journals");
          }}
        />
      )}
      {tab === "journals" && (
        <JournalPanel
          session={props.session}
          month={journalMonth}
          setMonth={setJournalMonth}
          journals={filteredJournals}
          lines={journalLines}
          expanded={expandedJournal}
          setExpanded={setExpandedJournal}
          search={search}
          setSearch={setSearch}
          reversedIds={reversedIds}
          canReverse={props.canReverseJournal}
          reverse={(journal) => setDialog({ type: "REVERSE", journal })}
        />
      )}
      {tab === "periods" && (
        <PeriodPanel
          session={props.session}
          periods={data?.periods ?? []}
          policy={data?.policy ?? null}
          canCreate={props.canCreatePeriod}
          canLock={props.canLockPeriod}
          canReopen={props.canReopenPeriod}
          action={setDialog}
          saved={async (message) => {
            props.notify(message);
            await load();
          }}
        />
      )}
      {tab === "payments" && (
        <SalesPaymentVerificationPanel
          session={props.session}
          companyId={props.companyId}
          notify={props.notify}
          openQueue={() => setTab("queue")}
        />
      )}
      {tab === "queue" && (
        <QueuePanel
          session={props.session}
          policy={data?.policy ?? null}
          runs={data?.queueRuns ?? []}
          items={queueItems}
          exceptions={data?.exceptions ?? []}
          expanded={expandedQueue}
          setExpanded={setExpandedQueue}
          canOperate={props.canOperateQueue}
          canManagePolicy={props.canManagePostingPolicy}
          action={setDialog}
          saved={async (message) => {
            props.notify(message);
            await load();
          }}
        />
      )}
      {tab === "reports" && <ReportsPanel session={props.session} />}

      {dialog && (
        <ActionDialog
          session={props.session}
          action={dialog}
          close={() => setDialog(null)}
          complete={async (message) => {
            setDialog(null);
            props.notify(message);
            await load();
          }}
        />
      )}
    </>
  );
}

function Metric({
  label,
  value,
  note,
  icon: Icon,
}: {
  label: string;
  value: string;
  note: string;
  icon: typeof BookOpen;
}) {
  return (
    <div className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
      <div className="flex items-start justify-between">
        <div>
          <p className="text-xs font-bold text-slate-500">{label}</p>
          <p className="mt-2 text-2xl font-black text-slate-950">{value}</p>
          <p className="mt-1 truncate text-xs text-slate-400">{note}</p>
        </div>
        <div className="grid h-10 w-10 place-items-center rounded-xl bg-violet-50 text-violet-600">
          <Icon className="h-5 w-5" />
        </div>
      </div>
    </div>
  );
}

function Overview({
  data,
  setTab,
}: {
  data: Workspace | null;
  setTab: (tab: Tab) => void;
}) {
  const lastJournal = data?.journals[0];
  const currentPeriod = data?.periods.find((row) =>
    ["OPEN", "REOPENED"].includes(row.status),
  );
  return (
    <div className="grid gap-5 lg:grid-cols-3">
      <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm lg:col-span-2">
        <h2 className="text-lg font-black">Kondisi Finance saat ini</h2>
        <div className="mt-5 grid gap-4 sm:grid-cols-2">
          <SummaryLine
            label="Jurnal terakhir"
            value={
              lastJournal
                ? `${lastJournal.display_no} · ${localDate(lastJournal.accounting_date)}`
                : "Belum ada"
            }
          />
          <SummaryLine
            label="Periode kerja"
            value={
              currentPeriod
                ? `${currentPeriod.period_year}-${String(currentPeriod.period_month).padStart(2, "0")} · ${statusLabels[currentPeriod.status]}`
                : "Belum ada periode terbuka"
            }
          />
          <SummaryLine
            label="Queue terakhir"
            value={
              data?.queueRuns[0]
                ? `${data.queueRuns[0].display_no} · ${statusLabels[data.queueRuns[0].status]}`
                : "Belum ada"
            }
          />
          <SummaryLine
            label="Reversal"
            value={`${data?.journals.filter((row) => row.journal_type === "REVERSAL").length ?? 0} jurnal pembalik`}
          />
        </div>
      </section>
      <section className="rounded-3xl bg-slate-950 p-6 text-white shadow-xl">
        <ShieldAlert className="h-7 w-7 text-amber-400" />
        <h2 className="mt-4 text-lg font-black">Yang belum masuk laporan</h2>
        <p className="mt-2 text-sm leading-6 text-slate-400">
          Event HOLD ditampilkan terpisah pada Pending Analysis. Selisih tidak
          boleh ditutup dengan jurnal tebakan.
        </p>
        <button
          onClick={() => setTab("reports")}
          className="mt-5 min-h-10 rounded-xl bg-white px-4 text-sm font-black text-slate-950"
        >
          Buka laporan
        </button>
      </section>
    </div>
  );
}

function SummaryLine({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-2xl bg-slate-50 p-4">
      <p className="text-xs font-bold text-slate-500">{label}</p>
      <p className="mt-2 text-sm font-black text-slate-900">{value}</p>
    </div>
  );
}

type LedgerAccount = {
  accountId: string;
  accountCode: string;
  accountName: string;
  accountType: string;
  normalBalance: "DEBIT" | "CREDIT";
  openingBalance: number | string;
  periodDebit: number | string;
  periodCredit: number | string;
  closingBalance: number | string;
};

type LedgerLine = {
  journalNo: string;
  journalDisplayNo?: string | null;
  accountingDate: string;
  sourceType: string;
  journalDescription?: string | null;
  debit: number | string;
  credit: number | string;
  runningBalance: number | string;
};

function GeneralLedgerPanel({
  session,
  onOpenJournal,
}: {
  session: Session;
  onOpenJournal: (displayNo: string) => void;
}) {
  const [month, setMonth] = useState(currentMonth());
  const [search, setSearch] = useState("");
  const [hideZero, setHideZero] = useState(false);
  const [accounts, setAccounts] = useState<LedgerAccount[]>([]);
  const [expanded, setExpanded] = useState<string | null>(null);
  const [lines, setLines] = useState(new Map<string, LedgerLine[]>());
  const [loading, setLoading] = useState(true);
  const [loadingAccount, setLoadingAccount] = useState<string | null>(null);
  const [exporting, setExporting] = useState(false);
  const [error, setError] = useState("");

  const loadAccounts = useCallback(async () => {
    setLoading(true);
    setError("");
    setExpanded(null);
    setLines(new Map());
    try {
      const range = monthRange(month);
      const query = new URLSearchParams({
        report: "TRIAL_BALANCE",
        dateFrom: range.dateFrom,
        asOf: range.asOf,
      });
      const response = await fetch(`/api/finance/operations?${query}`, {
        headers: authHeaders(session),
        cache: "no-store",
      });
      const result = await readApiJson<{
        data?: { rows?: LedgerAccount[] };
        error?: string;
      }>(response);
      if (!response.ok) throw new Error(friendly(result.error));
      setAccounts(result.data?.rows ?? []);
    } catch (caught) {
      setError(
        caught instanceof Error ? caught.message : "Buku Besar gagal dimuat.",
      );
    } finally {
      setLoading(false);
    }
  }, [month, session]);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- report follows selected month
    void loadAccounts();
  }, [loadAccounts]);

  async function toggleAccount(account: LedgerAccount) {
    if (expanded === account.accountId) {
      setExpanded(null);
      return;
    }
    setExpanded(account.accountId);
    if (lines.has(account.accountId)) return;
    setLoadingAccount(account.accountId);
    setError("");
    try {
      const range = monthRange(month);
      const query = new URLSearchParams({
        report: "GENERAL_LEDGER",
        accountId: account.accountId,
        dateFrom: range.dateFrom,
        asOf: range.asOf,
      });
      const response = await fetch(`/api/finance/operations?${query}`, {
        headers: authHeaders(session),
        cache: "no-store",
      });
      const result = await readApiJson<{
        data?: { rows?: LedgerLine[] };
        error?: string;
      }>(response);
      if (!response.ok) throw new Error(friendly(result.error));
      setLines((current) => {
        const next = new Map(current);
        next.set(account.accountId, result.data?.rows ?? []);
        return next;
      });
    } catch (caught) {
      setError(
        caught instanceof Error ? caught.message : "Detail akun gagal dimuat.",
      );
    } finally {
      setLoadingAccount(null);
    }
  }

  async function exportLedger() {
    setExporting(true);
    setError("");
    try {
      await downloadFinanceExport(session, "GENERAL_LEDGER", month);
    } catch (caught) {
      setError(
        caught instanceof Error ? caught.message : "Export Buku Besar gagal.",
      );
    } finally {
      setExporting(false);
    }
  }

  const visibleAccounts = accounts.filter((account) => {
    const query = search.trim().toLowerCase();
    const matches =
      !query ||
      `${account.accountCode} ${account.accountName}`
        .toLowerCase()
        .includes(query);
    const hasMovement = [
      account.openingBalance,
      account.periodDebit,
      account.periodCredit,
      account.closingBalance,
    ].some((value) => Number(value) !== 0);
    return matches && (!hideZero || hasMovement);
  });

  return (
    <section className="overflow-hidden rounded-3xl border border-slate-200 bg-white shadow-sm">
      <div className="border-b border-slate-100 p-5">
        <div className="flex flex-col gap-4 xl:flex-row xl:items-end xl:justify-between">
          <div>
            <h2 className="font-black">Buku Besar</h2>
            <p className="mt-1 max-w-2xl text-xs leading-5 text-slate-500">
              Semua akun ditampilkan sebagai ringkasan. Buka akun untuk melihat
              transaksi dan saldo berjalan tanpa memilih akun dari dropdown.
            </p>
          </div>
          <div className="grid gap-3 sm:grid-cols-[150px_260px_auto]">
            <label className="text-xs font-bold text-slate-500">
              Bulan
              <input
                type="month"
                value={month}
                onChange={(event) => setMonth(event.target.value)}
                className="mt-1 min-h-10 w-full rounded-xl border border-slate-200 px-3 text-sm font-normal"
              />
            </label>
            <label className="relative block self-end">
              <Search className="absolute left-3 top-3 h-4 w-4 text-slate-400" />
              <input
                value={search}
                onChange={(event) => setSearch(event.target.value)}
                placeholder="Cari kode atau nama akun"
                className="min-h-10 w-full rounded-xl border border-slate-200 pl-10 pr-3 text-sm outline-none focus:border-violet-400"
              />
            </label>
            <button
              onClick={() => void exportLedger()}
              disabled={exporting}
              className="inline-flex min-h-10 self-end items-center justify-center gap-2 rounded-xl bg-emerald-600 px-4 text-sm font-black text-white disabled:opacity-60"
            >
              {exporting ? (
                <Loader2 className="h-4 w-4 animate-spin" />
              ) : (
                <Download className="h-4 w-4" />
              )}
              Export Excel
            </button>
          </div>
        </div>
        <label className="mt-4 inline-flex cursor-pointer items-center gap-2 text-xs font-bold text-slate-600">
          <input
            type="checkbox"
            checked={hideZero}
            onChange={(event) => setHideZero(event.target.checked)}
            className="h-4 w-4 accent-violet-600"
          />
          Sembunyikan akun tanpa saldo dan pergerakan
        </label>
        {error && (
          <p className="mt-4 rounded-xl bg-rose-50 p-3 text-sm font-bold text-rose-700">
            {error}
          </p>
        )}
      </div>
      {loading ? (
        <div className="grid min-h-64 place-items-center">
          <Loader2 className="h-6 w-6 animate-spin text-violet-600" />
        </div>
      ) : (
        <div className="divide-y divide-slate-100">
          {visibleAccounts.map((account) => {
            const open = expanded === account.accountId;
            const accountLines = lines.get(account.accountId) ?? [];
            return (
              <article key={account.accountId}>
                <button
                  onClick={() => void toggleAccount(account)}
                  className="grid w-full gap-3 px-5 py-4 text-left hover:bg-slate-50 lg:grid-cols-[1.5fr_repeat(4,minmax(110px,.6fr))_auto] lg:items-center"
                >
                  <div>
                    <p className="font-black text-slate-950">
                      {account.accountCode} · {account.accountName}
                    </p>
                    <p className="mt-1 text-xs text-slate-400">
                      {account.accountType}
                    </p>
                  </div>
                  <LedgerAmount
                    label="Saldo awal"
                    value={account.openingBalance}
                  />
                  <LedgerAmount label="Debit" value={account.periodDebit} />
                  <LedgerAmount label="Kredit" value={account.periodCredit} />
                  <LedgerAmount
                    label="Saldo akhir"
                    value={account.closingBalance}
                    strong
                  />
                  {open ? (
                    <ChevronUp className="h-4 w-4" />
                  ) : (
                    <ChevronDown className="h-4 w-4" />
                  )}
                </button>
                {open && (
                  <div className="border-t border-slate-100 bg-slate-50/70 p-4">
                    {loadingAccount === account.accountId ? (
                      <div className="grid min-h-32 place-items-center">
                        <Loader2 className="h-5 w-5 animate-spin text-violet-600" />
                      </div>
                    ) : (
                      <div className="overflow-x-auto rounded-2xl border border-slate-200 bg-white">
                        <table className="w-full min-w-[900px] text-left text-sm">
                          <thead className="bg-slate-100 text-xs uppercase tracking-wide text-slate-500">
                            <tr>
                              <th className="px-4 py-3">Tanggal</th>
                              <th className="px-4 py-3">Nomor jurnal</th>
                              <th className="px-4 py-3">Sumber / keterangan</th>
                              <th className="px-4 py-3 text-right">Debit</th>
                              <th className="px-4 py-3 text-right">Kredit</th>
                              <th className="px-4 py-3 text-right">Saldo</th>
                            </tr>
                          </thead>
                          <tbody className="divide-y divide-slate-100">
                            {accountLines.map((line, index) => (
                              <tr key={`${line.journalNo}-${index}`}>
                                <td className="px-4 py-3">
                                  {localDate(line.accountingDate)}
                                </td>
                                <td className="px-4 py-3">
                                  {line.journalDisplayNo ? (
                                    <button
                                      onClick={() =>
                                        onOpenJournal(line.journalDisplayNo!)
                                      }
                                      className="font-black text-violet-700 hover:underline"
                                    >
                                      {line.journalDisplayNo}
                                    </button>
                                  ) : (
                                    <span className="text-slate-400">
                                      Jurnal
                                    </span>
                                  )}
                                </td>
                                <td className="px-4 py-3">
                                  <b>{line.journalDescription || "-"}</b>
                                  <p className="mt-1 text-xs text-slate-400">
                                    {line.sourceType}
                                  </p>
                                </td>
                                <td className="px-4 py-3 text-right font-bold">
                                  {Number(line.debit) ? money(line.debit) : "-"}
                                </td>
                                <td className="px-4 py-3 text-right font-bold">
                                  {Number(line.credit)
                                    ? money(line.credit)
                                    : "-"}
                                </td>
                                <td className="px-4 py-3 text-right font-black">
                                  {money(line.runningBalance)}
                                </td>
                              </tr>
                            ))}
                          </tbody>
                        </table>
                        {!accountLines.length && (
                          <Empty text="Tidak ada pergerakan pada bulan ini." />
                        )}
                      </div>
                    )}
                  </div>
                )}
              </article>
            );
          })}
          {!visibleAccounts.length && (
            <Empty text="Tidak ada akun yang sesuai filter." />
          )}
        </div>
      )}
    </section>
  );
}

function LedgerAmount({
  label,
  value,
  strong = false,
}: {
  label: string;
  value: number | string;
  strong?: boolean;
}) {
  return (
    <div>
      <p className="text-xs text-slate-400">{label}</p>
      <p className={`mt-1 text-sm ${strong ? "font-black" : "font-bold"}`}>
        {money(value)}
      </p>
    </div>
  );
}

function JournalPanel({
  session,
  month,
  setMonth,
  journals,
  lines,
  expanded,
  setExpanded,
  search,
  setSearch,
  reversedIds,
  canReverse,
  reverse,
}: {
  session: Session;
  month: string;
  setMonth: (value: string) => void;
  journals: Journal[];
  lines: Map<string, JournalLine[]>;
  expanded: string | null;
  setExpanded: (id: string | null) => void;
  search: string;
  setSearch: (value: string) => void;
  reversedIds: Set<string | null>;
  canReverse: boolean;
  reverse: (journal: Journal) => void;
}) {
  const [exporting, setExporting] = useState(false);
  const [exportError, setExportError] = useState("");
  async function exportEntries() {
    setExporting(true);
    setExportError("");
    try {
      await downloadFinanceExport(session, "JOURNAL_ENTRIES", month);
    } catch (caught) {
      setExportError(
        caught instanceof Error
          ? caught.message
          : "Export Journal Entries gagal.",
      );
    } finally {
      setExporting(false);
    }
  }
  return (
    <section className="overflow-hidden rounded-3xl border border-slate-200 bg-white shadow-sm">
      <div className="border-b border-slate-100 p-5">
        <div className="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
          <div>
            <h2 className="font-black">Journal Entries</h2>
            <p className="mt-1 text-xs text-slate-500">
              Satu baris adalah satu dokumen jurnal. Klik untuk melihat akun
              debit dan kreditnya.
            </p>
          </div>
          <div className="grid gap-3 sm:grid-cols-[150px_280px_auto]">
            <label className="text-xs font-bold text-slate-500">
              Bulan
              <input
                type="month"
                value={month}
                onChange={(event) => setMonth(event.target.value)}
                className="mt-1 min-h-10 w-full rounded-xl border border-slate-200 px-3 text-sm font-normal"
              />
            </label>
            <label className="relative block self-end">
              <Search className="absolute left-3 top-3 h-4 w-4 text-slate-400" />
              <input
                value={search}
                onChange={(event) => setSearch(event.target.value)}
                placeholder="Cari nomor, sumber, atau catatan"
                className="min-h-10 w-full rounded-xl border border-slate-200 pl-10 pr-3 text-sm outline-none focus:border-violet-400"
              />
            </label>
            <button
              onClick={() => void exportEntries()}
              disabled={exporting}
              className="inline-flex min-h-10 self-end items-center justify-center gap-2 rounded-xl bg-emerald-600 px-4 text-sm font-black text-white disabled:opacity-60"
            >
              {exporting ? (
                <Loader2 className="h-4 w-4 animate-spin" />
              ) : (
                <Download className="h-4 w-4" />
              )}
              Export Excel
            </button>
          </div>
        </div>
        {exportError && (
          <p className="mt-4 rounded-xl bg-rose-50 p-3 text-sm font-bold text-rose-700">
            {exportError}
          </p>
        )}
      </div>
      <div className="divide-y divide-slate-100">
        {journals.map((journal) => {
          const open = expanded === journal.id;
          const eligible =
            canReverse &&
            journal.status === "POSTED" &&
            ["MANUAL", "OPENING_BALANCE"].includes(journal.journal_type) &&
            !reversedIds.has(journal.id);
          return (
            <article key={journal.id}>
              <button
                onClick={() => setExpanded(open ? null : journal.id)}
                className="grid w-full gap-3 px-5 py-4 text-left hover:bg-slate-50 lg:grid-cols-[1.2fr_.8fr_.8fr_.8fr_auto] lg:items-center"
              >
                <div>
                  <p className="font-black text-slate-950">
                    {journal.display_no}
                  </p>
                  <p className="mt-1 text-xs text-slate-500">
                    {journal.description}
                  </p>
                </div>
                <div>
                  <p className="text-xs text-slate-400">Tanggal akuntansi</p>
                  <p className="mt-1 text-sm font-bold">
                    {localDate(journal.accounting_date)}
                  </p>
                </div>
                <div>
                  <p className="text-xs text-slate-400">Jenis</p>
                  <p className="mt-1 text-sm font-bold">
                    {journalTypeLabels[journal.journal_type]}
                  </p>
                </div>
                <div>
                  <p className="text-xs text-slate-400">Nilai</p>
                  <p className="mt-1 text-sm font-black">
                    {money(journal.total_debit)}
                  </p>
                </div>
                <div className="flex items-center gap-2">
                  <Status value={journal.status} />
                  {open ? (
                    <ChevronUp className="h-4 w-4" />
                  ) : (
                    <ChevronDown className="h-4 w-4" />
                  )}
                </div>
              </button>
              {open && (
                <div className="border-t border-slate-100 bg-slate-50/70 p-5">
                  <div className="mb-4 flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                    <div className="text-xs leading-5 text-slate-500">
                      <p>
                        Sumber:{" "}
                        <b className="text-slate-700">{journal.source_type}</b>
                      </p>
                      {journal.system_event_key && (
                        <p>
                          Event:{" "}
                          <b className="text-slate-700">
                            {journal.system_event_key}
                          </b>
                        </p>
                      )}
                      {journal.original_event_date && (
                        <p>
                          Tanggal sumber:{" "}
                          <b className="text-slate-700">
                            {localDate(journal.original_event_date)}
                          </b>
                        </p>
                      )}
                      {reversedIds.has(journal.id) && (
                        <p className="font-bold text-amber-700">
                          Jurnal ini sudah mempunyai pembalik.
                        </p>
                      )}
                    </div>
                    {eligible && (
                      <button
                        onClick={() => reverse(journal)}
                        className="inline-flex min-h-10 items-center justify-center gap-2 rounded-xl bg-rose-600 px-4 text-sm font-black text-white"
                      >
                        <RotateCcw className="h-4 w-4" />
                        Buat jurnal pembalik
                      </button>
                    )}
                  </div>
                  <div className="overflow-x-auto rounded-2xl border border-slate-200 bg-white">
                    <table className="w-full min-w-[760px] text-left text-sm">
                      <thead className="bg-slate-100 text-xs uppercase tracking-wide text-slate-500">
                        <tr>
                          <th className="px-4 py-3">Akun</th>
                          <th className="px-4 py-3">Keterangan</th>
                          <th className="px-4 py-3 text-right">Debit</th>
                          <th className="px-4 py-3 text-right">Kredit</th>
                        </tr>
                      </thead>
                      <tbody className="divide-y divide-slate-100">
                        {(lines.get(journal.id) ?? []).map((line) => (
                          <tr key={line.id}>
                            <td className="px-4 py-3">
                              <b>{line.account_name_snapshot}</b>
                              <p className="mt-1 text-xs text-slate-400">
                                {line.account_code_snapshot}
                              </p>
                            </td>
                            <td className="px-4 py-3 text-slate-500">
                              {line.description || "-"}
                            </td>
                            <td className="px-4 py-3 text-right font-bold">
                              {Number(line.debit) ? money(line.debit) : "-"}
                            </td>
                            <td className="px-4 py-3 text-right font-bold">
                              {Number(line.credit) ? money(line.credit) : "-"}
                            </td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                </div>
              )}
            </article>
          );
        })}
        {!journals.length && (
          <Empty text="Belum ada jurnal yang sesuai pencarian." />
        )}
      </div>
    </section>
  );
}

function PeriodPanel({
  session,
  periods,
  policy,
  canCreate,
  canLock,
  canReopen,
  action,
  saved,
}: {
  session: Session;
  periods: Period[];
  policy: Workspace["policy"] | null;
  canCreate: boolean;
  canLock: boolean;
  canReopen: boolean;
  action: (action: DialogAction) => void;
  saved: (message: string) => Promise<void>;
}) {
  const [savingPolicy, setSavingPolicy] = useState(false);
  const [policyError, setPolicyError] = useState("");
  async function changePeriodMode(mode: "MANUAL" | "AUTOMATIC") {
    if (!policy || mode === policy.periodCreationMode) return;
    setSavingPolicy(true);
    setPolicyError("");
    try {
      const response = await fetch("/api/finance/operations", {
        method: "POST",
        headers: { ...authHeaders(session), "Content-Type": "application/json" },
        body: JSON.stringify({
          action: "SAVE_PERIOD_POLICY",
          masterVersion: Number(policy.masterVersion),
          periodCreationMode: mode,
        }),
      });
      const result = await readApiJson<{ error?: string }>(response);
      if (!response.ok) throw new Error(friendly(result.error));
      await saved(
        mode === "AUTOMATIC"
          ? "Periode otomatis aktif. Bulan berjalan dan bulan berikutnya dipastikan tersedia."
          : "Pembuatan periode dikembalikan ke mode manual.",
      );
    } catch (caught) {
      setPolicyError(caught instanceof Error ? caught.message : "Kebijakan periode gagal disimpan.");
    } finally {
      setSavingPolicy(false);
    }
  }
  return (
    <section className="rounded-3xl border border-slate-200 bg-white shadow-sm">
      <div className="flex items-center justify-between gap-4 border-b border-slate-100 p-5">
        <div>
          <h2 className="font-black">Accounting period</h2>
          <p className="mt-1 text-xs text-slate-500">
            Finance dapat mengunci; hanya Owner/Admin dapat membuka kembali
            dengan alasan.
          </p>
        </div>
        {canCreate && (
          <button
            onClick={() => action({ type: "CREATE_PERIOD" })}
            className="min-h-10 rounded-xl bg-violet-600 px-4 text-sm font-black text-white"
          >
            Tambah periode
          </button>
        )}
      </div>
      {policy && (
        <div className="border-b border-slate-100 bg-slate-50 p-5">
          <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <p className="text-sm font-black text-slate-900">Pembuatan periode</p>
              <p className="mt-1 text-xs leading-5 text-slate-500">
                Otomatis memastikan bulan berjalan dan bulan berikutnya tersedia. Periode yang sudah dikunci tidak pernah dibuka kembali otomatis.
              </p>
            </div>
            <select
              value={policy.periodCreationMode}
              disabled={!canCreate || savingPolicy}
              onChange={(event) => void changePeriodMode(event.target.value as "MANUAL" | "AUTOMATIC")}
              className="min-h-11 rounded-xl border border-slate-200 bg-white px-3 text-sm font-black disabled:opacity-60"
            >
              <option value="MANUAL">Manual</option>
              <option value="AUTOMATIC">Otomatis</option>
            </select>
          </div>
          {policyError && <p className="mt-3 text-sm font-bold text-rose-700">{policyError}</p>}
        </div>
      )}
      <div className="divide-y divide-slate-100">
        {periods.map((period) => (
          <div
            key={period.id}
            className="flex flex-col gap-4 p-5 sm:flex-row sm:items-center sm:justify-between"
          >
            <div>
              <p className="font-black">
                {new Intl.DateTimeFormat("id-ID", {
                  month: "long",
                  year: "numeric",
                }).format(new Date(`${period.start_date}T00:00:00`))}
              </p>
              <p className="mt-1 text-xs text-slate-500">
                {localDate(period.start_date)} – {localDate(period.end_date)}
              </p>
              {period.reopen_reason && (
                <p className="mt-2 text-xs font-semibold text-amber-700">
                  Dibuka kembali: {period.reopen_reason}
                </p>
              )}
            </div>
            <div className="flex flex-wrap items-center gap-2">
              <Status value={period.status} />
              {canLock && ["OPEN", "REOPENED"].includes(period.status) && (
                <button
                  onClick={() => action({ type: "LOCK", period })}
                  className="inline-flex min-h-9 items-center gap-2 rounded-xl border border-slate-200 px-3 text-xs font-black"
                >
                  <LockKeyhole className="h-3.5 w-3.5" />
                  Kunci
                </button>
              )}
              {canReopen && period.status === "LOCKED" && (
                <button
                  onClick={() => action({ type: "REOPEN", period })}
                  className="inline-flex min-h-9 items-center gap-2 rounded-xl bg-amber-500 px-3 text-xs font-black text-white"
                >
                  <Unlock className="h-3.5 w-3.5" />
                  Buka kembali
                </button>
              )}
            </div>
          </div>
        ))}
        {!periods.length && <Empty text="Belum ada accounting period." />}
      </div>
    </section>
  );
}

function QueuePanel({
  session,
  policy,
  runs,
  items,
  exceptions,
  expanded,
  setExpanded,
  canOperate,
  canManagePolicy,
  action,
  saved,
}: {
  session: Session;
  policy: Workspace["policy"] | null;
  runs: QueueRun[];
  items: Map<string, QueueItem[]>;
  exceptions: ExceptionRow[];
  expanded: string | null;
  setExpanded: (id: string | null) => void;
  canOperate: boolean;
  canManagePolicy: boolean;
  action: (action: DialogAction) => void;
  saved: (message: string) => Promise<void>;
}) {
  const [savingPolicy, setSavingPolicy] = useState(false);
  const [policyError, setPolicyError] = useState("");
  const active = runs.some((run) =>
    ["PREVIEWED", "APPROVED", "PROCESSING"].includes(run.status),
  );
  async function changePostingMode(mode: "CONTROLLED" | "AUTOMATIC") {
    if (!policy || mode === policy.postingMode) return;
    setSavingPolicy(true);
    setPolicyError("");
    try {
      const response = await fetch("/api/finance/operations", {
        method: "POST",
        headers: { ...authHeaders(session), "Content-Type": "application/json" },
        body: JSON.stringify({
          action: "SAVE_POSTING_POLICY",
          masterVersion: Number(policy.masterVersion),
          postingMode: mode,
        }),
      });
      const result = await readApiJson<{ error?: string }>(response);
      if (!response.ok) throw new Error(friendly(result.error));
      await saved(
        mode === "AUTOMATIC"
          ? "Posting otomatis aktif untuk event baru. Event HOLD lama dapat diproses dari tombol backlog."
          : "Posting dikembalikan ke controlled queue.",
      );
    } catch (caught) {
      setPolicyError(
        caught instanceof Error
          ? caught.message
          : "Kebijakan posting gagal disimpan.",
      );
    } finally {
      setSavingPolicy(false);
    }
  }
  return (
    <div className="space-y-5">
      {policy && (
        <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
          <div className="flex flex-col gap-4 lg:flex-row lg:items-center lg:justify-between">
            <div>
              <h2 className="font-black">Kebijakan posting jurnal</h2>
              <p className="mt-1 max-w-3xl text-xs leading-5 text-slate-500">
                Controlled memerlukan preview, persetujuan, lalu proses. Otomatis
                memposting event final baru melalui dispatcher yang sama; error
                tidak membatalkan transaksi dan tetap masuk exception.
              </p>
            </div>
            <div className="flex flex-col gap-2 sm:flex-row">
              <select
                value={policy.postingMode}
                disabled={!canManagePolicy || savingPolicy || active}
                onChange={(event) =>
                  void changePostingMode(
                    event.target.value as "CONTROLLED" | "AUTOMATIC",
                  )
                }
                className="min-h-11 rounded-xl border border-slate-200 bg-white px-3 text-sm font-black disabled:opacity-60"
              >
                <option value="CONTROLLED">Controlled</option>
                <option value="AUTOMATIC">Otomatis</option>
              </select>
              {canOperate && policy.postingMode === "AUTOMATIC" && (
                <button
                  onClick={() => action({ type: "PROCESS_AUTOMATIC" })}
                  className="inline-flex min-h-11 items-center justify-center gap-2 rounded-xl bg-emerald-600 px-4 text-sm font-black text-white"
                >
                  <Play className="h-4 w-4" />
                  Proses backlog
                </button>
              )}
            </div>
          </div>
          {policyError && (
            <p className="mt-3 text-sm font-bold text-rose-700">{policyError}</p>
          )}
        </section>
      )}
      <section className="rounded-3xl border border-slate-200 bg-white shadow-sm">
        <div className="flex flex-col gap-4 border-b border-slate-100 p-5 sm:flex-row sm:items-center sm:justify-between">
          <div>
            <h2 className="font-black">Controlled posting queue</h2>
            <p className="mt-1 text-xs text-slate-500">
              Memproses seluruh event final yang didukung canonical Finance
              dengan snapshot preview dan audit approval.
            </p>
          </div>
          {canOperate && policy?.postingMode !== "AUTOMATIC" && !active && (
            <button
              onClick={() => action({ type: "PREVIEW_QUEUE" })}
              className="inline-flex min-h-10 items-center justify-center gap-2 rounded-xl bg-violet-600 px-4 text-sm font-black text-white"
            >
              <FileClock className="h-4 w-4" />
              Buat preview
            </button>
          )}
        </div>
        <div className="divide-y divide-slate-100">
          {runs.map((run) => {
            const open = expanded === run.id;
            return (
              <article key={run.id}>
                <button
                  onClick={() => setExpanded(open ? null : run.id)}
                  className="grid w-full gap-3 p-5 text-left hover:bg-slate-50 sm:grid-cols-[1fr_.7fr_.7fr_auto] sm:items-center"
                >
                  <div>
                    <p className="font-black">{run.display_no}</p>
                    <p className="mt-1 text-xs text-slate-400">
                      {run.scope_system_key} · {localDate(run.created_at)}
                    </p>
                  </div>
                  <p className="text-sm">
                    <b>{run.previewed_event_count}</b> event
                  </p>
                  <p className="text-sm text-slate-500">
                    Posted {run.posted_count} · Gagal {run.failed_count}
                  </p>
                  <div className="flex items-center gap-2">
                    <Status value={run.status} />
                    {open ? (
                      <ChevronUp className="h-4 w-4" />
                    ) : (
                      <ChevronDown className="h-4 w-4" />
                    )}
                  </div>
                </button>
                {open && (
                  <div className="border-t border-slate-100 bg-slate-50 p-5">
                    <div className="mb-4 flex flex-wrap justify-end gap-2">
                      {canOperate && run.status === "PREVIEWED" && (
                        <button
                          onClick={() => action({ type: "APPROVE_QUEUE", run })}
                          className="inline-flex min-h-10 items-center gap-2 rounded-xl bg-blue-600 px-4 text-sm font-black text-white"
                        >
                          <CheckCircle2 className="h-4 w-4" />
                          Setujui preview
                        </button>
                      )}
                      {canOperate && run.status === "APPROVED" && (
                        <button
                          onClick={() => action({ type: "PROCESS_QUEUE", run })}
                          className="inline-flex min-h-10 items-center gap-2 rounded-xl bg-emerald-600 px-4 text-sm font-black text-white"
                        >
                          <Play className="h-4 w-4" />
                          Proses posting
                        </button>
                      )}
                    </div>
                    <div className="space-y-2">
                      {(items.get(run.id) ?? []).map((item) => (
                        <div
                          key={item.id}
                          className="flex flex-col gap-2 rounded-xl border border-slate-200 bg-white p-3 text-sm sm:flex-row sm:items-center sm:justify-between"
                        >
                          <div>
                            <b>
                              {item.system_event_key_snapshot.replaceAll(
                                "_",
                                " ",
                              )}
                            </b>
                            <p className="mt-1 text-xs text-slate-400">
                              Transaksi Finance ·{" "}
                              {localDate(item.event_date_snapshot)}
                            </p>
                            {item.error_message && (
                              <p className="mt-2 text-xs font-semibold text-rose-700">
                                {item.error_code}: {item.error_message}
                              </p>
                            )}
                          </div>
                          <Status value={item.status} />
                        </div>
                      ))}
                      {!(items.get(run.id) ?? []).length && (
                        <p className="text-sm text-slate-400">
                          Tidak ada item.
                        </p>
                      )}
                    </div>
                  </div>
                )}
              </article>
            );
          })}
          {!runs.length && <Empty text="Belum ada riwayat posting queue." />}
        </div>
      </section>
      {exceptions.length > 0 && (
        <section className="rounded-3xl border border-rose-200 bg-rose-50 p-5">
          <h3 className="font-black text-rose-900">Exception terbuka</h3>
          <div className="mt-4 space-y-3">
            {exceptions.map((item) => (
              <div key={item.id} className="rounded-xl bg-white p-4 text-sm">
                <div className="flex items-center justify-between gap-3">
                  <b>
                    {item.display_no} · {item.reason_code}
                  </b>
                  <Status value={item.status} />
                </div>
                <p className="mt-2 text-xs text-slate-500">
                  Percobaan {item.retry_count} · {localDate(item.created_at)}
                </p>
                {item.last_error && (
                  <p className="mt-2 text-xs font-semibold text-rose-700">
                    {item.last_error}
                  </p>
                )}
              </div>
            ))}
          </div>
        </section>
      )}
    </div>
  );
}

function ReportsPanel({ session }: { session: Session }) {
  const [report, setReport] = useState<ReportCode>("TRIAL_BALANCE");
  const [dateFrom, setDateFrom] = useState(monthStart());
  const [asOf, setAsOf] = useState(today());
  const [data, setData] = useState<ReportData | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  async function run() {
    setLoading(true);
    setError("");
    try {
      const query = new URLSearchParams({ report, dateFrom, asOf });
      const response = await fetch(`/api/finance/operations?${query}`, {
        headers: authHeaders(session),
        cache: "no-store",
      });
      const result = await readApiJson<{ data?: ReportData; error?: string }>(
        response,
      );
      if (!response.ok) throw new Error(friendly(result.error));
      setData(result.data ?? null);
    } catch (caught) {
      setError(
        caught instanceof Error ? caught.message : "Laporan gagal dimuat.",
      );
    } finally {
      setLoading(false);
    }
  }
  return (
    <div className="space-y-5">
      <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
        <div className="grid gap-4 lg:grid-cols-[1.2fr_.8fr_.8fr_auto]">
          <label className="text-sm font-black">
            Jenis laporan
            <select
              value={report}
              onChange={(event) => {
                setReport(event.target.value as ReportCode);
                setData(null);
              }}
              className="mt-2 min-h-11 w-full rounded-xl border border-slate-200 bg-white px-3 font-normal"
            >
              {(Object.keys(reportLabels) as ReportCode[]).map((code) => (
                <option key={code} value={code}>
                  {reportLabels[code]}
                </option>
              ))}
            </select>
          </label>
          <label className="text-sm font-black">
            Dari tanggal
            <input
              type="date"
              value={dateFrom}
              onChange={(event) => setDateFrom(event.target.value)}
              disabled={["BALANCE_SHEET", "RECONCILIATION_SUMMARY"].includes(
                report,
              )}
              className="mt-2 min-h-11 w-full rounded-xl border border-slate-200 px-3 font-normal disabled:bg-slate-100"
            />
          </label>
          <label className="text-sm font-black">
            Sampai tanggal
            <input
              type="date"
              value={asOf}
              onChange={(event) => setAsOf(event.target.value)}
              className="mt-2 min-h-11 w-full rounded-xl border border-slate-200 px-3 font-normal"
            />
          </label>
          <button
            onClick={() => void run()}
            disabled={loading}
            className="mt-auto inline-flex min-h-11 items-center justify-center gap-2 rounded-xl bg-violet-600 px-5 text-sm font-black text-white disabled:bg-slate-300"
          >
            {loading ? (
              <Loader2 className="h-4 w-4 animate-spin" />
            ) : (
              <BarChart3 className="h-4 w-4" />
            )}
            Tampilkan
          </button>
        </div>
        {report === "RECONCILIATION_SUMMARY" && (
          <p className="mt-3 text-xs font-semibold text-amber-700">
            Rekonsiliasi hanya current-state. Pilih tanggal hari ini; sistem
            tidak membuat adjustment otomatis.
          </p>
        )}
        {error && (
          <p className="mt-4 rounded-xl bg-rose-50 p-3 text-sm font-bold text-rose-700">
            {error}
          </p>
        )}
      </section>
      {data ? (
        <ReportResult report={report} data={data} />
      ) : (
        <div className="rounded-3xl border border-dashed border-slate-300 bg-white p-12 text-center">
          <BarChart3 className="mx-auto h-8 w-8 text-slate-300" />
          <p className="mt-4 text-sm font-bold text-slate-500">
            Pilih filter lalu tampilkan laporan.
          </p>
        </div>
      )}
    </div>
  );
}

function ReportResult({
  report,
  data,
}: {
  report: ReportCode;
  data: ReportData;
}) {
  const rows = Array.isArray(data.rows)
    ? (data.rows as Record<string, unknown>[])
    : [];
  const cards =
    report === "TRIAL_BALANCE"
      ? [
          ["Total debit", data.periodDebit],
          ["Total kredit", data.periodCredit],
          ["Seimbang", data.balanced ? "Ya" : "Tidak"],
        ]
      : report === "INCOME_STATEMENT"
        ? [
            ["Pendapatan bersih", data.netRevenue],
            ["Laba kotor", data.grossProfit],
            ["Beban operasional", data.operatingExpense],
            ["Laba sebelum pajak", data.profitBeforeTax],
          ]
        : report === "BALANCE_SHEET"
          ? [
              ["Aset", data.assets],
              ["Liabilitas", data.liabilities],
              ["Ekuitas", data.equity],
              ["Seimbang", data.balanced ? "Ya" : "Tidak"],
            ]
          : report === "PENDING_ANALYSIS"
            ? [
                ["Status laporan", data.label],
                ["Kelompok pending", data.totalRows],
                [
                  "Masuk laporan keuangan",
                  data.financialStatementIncluded ? "Ya" : "Tidak",
                ],
              ]
            : [
                ["Mode valuasi", data.valuationMode],
                ["Adjustment otomatis", data.autoAdjustment ? "Ya" : "Tidak"],
                ["Tanggal", data.asOf],
              ];
  return (
    <section className="overflow-hidden rounded-3xl border border-slate-200 bg-white shadow-sm">
      <div className="border-b border-slate-100 p-5">
        <p className="text-xs font-black uppercase tracking-wider text-violet-600">
          POSTED only
        </p>
        <h2 className="mt-2 text-xl font-black">{reportLabels[report]}</h2>
        <p className="mt-1 text-xs text-slate-500">
          Versi laporan {String(data.reportVersion ?? "-")} ·{" "}
          {String(data.timezone ?? "-")}
        </p>
        <div className="mt-5 grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
          {cards.map(([label, value]) => (
            <div key={String(label)} className="rounded-xl bg-slate-50 p-4">
              <p className="text-xs font-bold text-slate-500">
                {String(label)}
              </p>
              <p className="mt-2 text-base font-black">
                {typeof value === "number" ||
                (typeof value === "string" && /^-?\d+(\.\d+)?$/.test(value))
                  ? money(value)
                  : String(value ?? "-")}
              </p>
            </div>
          ))}
        </div>
      </div>
      <div className="overflow-x-auto">
        <table className="w-full min-w-[900px] text-left text-sm">
          <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500">
            <tr>
              {report === "PENDING_ANALYSIS" ? (
                <>
                  <th className="px-4 py-3">Event</th>
                  <th className="px-4 py-3">Status</th>
                  <th className="px-4 py-3">Jumlah</th>
                  <th className="px-4 py-3 text-right">Potensi nilai</th>
                </>
              ) : report === "RECONCILIATION_SUMMARY" ? (
                <>
                  <th className="px-4 py-3">Jenis</th>
                  <th className="px-4 py-3 text-right">Subledger</th>
                  <th className="px-4 py-3 text-right">Ledger</th>
                  <th className="px-4 py-3 text-right">Selisih</th>
                  <th className="px-4 py-3">Status</th>
                </>
              ) : (
                <>
                  <th className="px-4 py-3">Akun / jurnal</th>
                  <th className="px-4 py-3">Keterangan</th>
                  <th className="px-4 py-3 text-right">Debit / nilai</th>
                  <th className="px-4 py-3 text-right">Kredit / saldo</th>
                </>
              )}
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {rows.map((row, index) =>
              report === "PENDING_ANALYSIS" ? (
                <tr key={index}>
                  <td className="px-4 py-3">
                    <b>{String(row.systemEventKey ?? "-")}</b>
                    <p className="text-xs text-slate-400">
                      {String(row.sourceTable ?? "-")}
                    </p>
                  </td>
                  <td className="px-4 py-3">
                    <Status value={String(row.status ?? "")} />
                  </td>
                  <td className="px-4 py-3">{String(row.eventCount ?? 0)}</td>
                  <td className="px-4 py-3 text-right font-bold">
                    {money(row.potentialAmount)}
                  </td>
                </tr>
              ) : report === "RECONCILIATION_SUMMARY" ? (
                <tr key={index}>
                  <td className="px-4 py-3 font-bold">
                    {String(row.reconciliationType ?? "-")}
                  </td>
                  <td className="px-4 py-3 text-right">
                    {row.subledgerBalance == null
                      ? "-"
                      : money(row.subledgerBalance)}
                  </td>
                  <td className="px-4 py-3 text-right">
                    {money(row.ledgerBalance)}
                  </td>
                  <td className="px-4 py-3 text-right font-bold">
                    {row.difference == null ? "-" : money(row.difference)}
                  </td>
                  <td className="px-4 py-3">
                    <Status value={String(row.status ?? "")} />
                  </td>
                </tr>
              ) : (
                <tr key={index}>
                  <td className="px-4 py-3">
                    <b>{String(row.accountName ?? row.journalNo ?? "-")}</b>
                    <p className="text-xs text-slate-400">
                      {String(row.accountCode ?? row.accountingDate ?? "")}
                    </p>
                  </td>
                  <td className="px-4 py-3 text-slate-500">
                    {String(row.description ?? row.accountType ?? "-")}
                  </td>
                  <td className="px-4 py-3 text-right font-bold">
                    {money(row.periodDebit ?? row.debit ?? row.amount ?? 0)}
                  </td>
                  <td className="px-4 py-3 text-right font-bold">
                    {money(
                      row.periodCredit ??
                        row.credit ??
                        row.closingBalance ??
                        row.runningBalance ??
                        0,
                    )}
                  </td>
                </tr>
              ),
            )}
          </tbody>
        </table>
        {!rows.length && (
          <Empty text="Laporan valid, tetapi belum mempunyai baris pada filter ini." />
        )}
      </div>
    </section>
  );
}

function ActionDialog({
  session,
  action,
  close,
  complete,
}: {
  session: Session;
  action: DialogAction;
  close: () => void;
  complete: (message: string) => Promise<void>;
}) {
  useEscapeClose(close);
  const now = new Date();
  const [reason, setReason] = useState("");
  const [date, setDate] = useState(today());
  const [year, setYear] = useState(now.getFullYear());
  const [month, setMonth] = useState(now.getMonth() + 1);
  const [limit, setLimit] = useState(100);
  const [confirmed, setConfirmed] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const needsReason = action.type === "REVERSE" || action.type === "REOPEN";
  const title =
    action.type === "REVERSE"
      ? "Buat jurnal pembalik?"
      : action.type === "LOCK"
        ? "Kunci accounting period?"
        : action.type === "REOPEN"
          ? "Buka kembali accounting period?"
          : action.type === "CREATE_PERIOD"
            ? "Tambah accounting period"
            : action.type === "PREVIEW_QUEUE"
              ? "Buat preview posting queue?"
              : action.type === "PROCESS_AUTOMATIC"
                ? "Proses backlog posting otomatis?"
                : action.type === "APPROVE_QUEUE"
                  ? "Setujui posting queue?"
                  : "Proses posting queue?";
  async function submit() {
    setBusy(true);
    setError("");
    try {
      const body: Record<string, unknown> = { action: action.type };
      if (action.type === "REVERSE")
        Object.assign(body, {
          action: "REVERSE_JOURNAL",
          journalId: action.journal.id,
          masterVersion: Number(action.journal.master_version),
          accountingDate: date,
          reason,
          idempotencyKey: crypto.randomUUID(),
        });
      if (action.type === "LOCK")
        Object.assign(body, {
          action: "LOCK_PERIOD",
          periodId: action.period.id,
          masterVersion: Number(action.period.master_version),
        });
      if (action.type === "REOPEN")
        Object.assign(body, {
          action: "REOPEN_PERIOD",
          periodId: action.period.id,
          masterVersion: Number(action.period.master_version),
          reason,
        });
      if (action.type === "CREATE_PERIOD")
        Object.assign(body, { action: "CREATE_PERIOD", year, month });
      if (action.type === "PREVIEW_QUEUE")
        Object.assign(body, { action: "PREVIEW_QUEUE", limit });
      if (action.type === "PROCESS_AUTOMATIC")
        Object.assign(body, { action: "PROCESS_AUTOMATIC", limit });
      if (action.type === "APPROVE_QUEUE")
        Object.assign(body, {
          action: "APPROVE_QUEUE",
          queueRunId: action.run.id,
          masterVersion: Number(action.run.master_version),
        });
      if (action.type === "PROCESS_QUEUE")
        Object.assign(body, {
          action: "PROCESS_QUEUE",
          queueRunId: action.run.id,
          masterVersion: Number(action.run.master_version),
        });
      const response = await fetch("/api/finance/operations", {
        method: "POST",
        headers: {
          ...authHeaders(session),
          "Content-Type": "application/json",
        },
        body: JSON.stringify(body),
      });
      const result = await readApiJson<{ error?: string }>(response);
      if (!response.ok) throw new Error(friendly(result.error));
      const message =
        action.type === "REVERSE"
          ? "Jurnal pembalik berhasil diposting."
          : action.type === "LOCK"
            ? "Accounting period berhasil dikunci."
            : action.type === "REOPEN"
              ? "Accounting period berhasil dibuka kembali."
              : action.type === "CREATE_PERIOD"
                ? "Accounting period berhasil dibuat."
                : action.type === "PREVIEW_QUEUE"
                  ? "Preview posting queue berhasil dibuat."
                  : action.type === "PROCESS_AUTOMATIC"
                    ? "Backlog posting otomatis selesai diproses."
                    : action.type === "APPROVE_QUEUE"
                      ? "Posting queue berhasil disetujui."
                      : "Posting queue selesai diproses.";
      await complete(message);
    } catch (caught) {
      setError(
        caught instanceof Error ? caught.message : "Operasi Finance gagal.",
      );
    } finally {
      setBusy(false);
    }
  }
  const valid = confirmed && (!needsReason || reason.trim().length >= 3);
  return (
    <div className="fixed inset-0 z-[90] grid place-items-center bg-slate-950/65 p-4 backdrop-blur-sm">
      <section className="max-h-[92vh] w-full max-w-xl overflow-y-auto rounded-3xl bg-white p-6 shadow-2xl sm:p-7">
        <div className="flex items-start justify-between gap-4">
          <div>
            <p className="text-xs font-black uppercase tracking-wider text-violet-600">
              Konfirmasi Finance
            </p>
            <h2 className="mt-2 text-xl font-black">{title}</h2>
          </div>
          <button
            onClick={close}
            disabled={busy}
            className="grid h-10 w-10 place-items-center rounded-xl bg-slate-100 text-slate-500"
            aria-label="Tutup"
          >
            <X className="h-4 w-4" />
          </button>
        </div>
        <div className="mt-5 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm leading-6 text-amber-900">
          Tindakan tercatat pada audit. Jurnal POSTED tidak diedit atau dihapus
          dan antrean tidak boleh dipakai untuk contract selain Stok Awal yang
          sudah didukung.
        </div>
        {action.type === "REVERSE" && (
          <label className="mt-5 block text-sm font-black">
            Tanggal jurnal pembalik
            <input
              type="date"
              value={date}
              onChange={(event) => setDate(event.target.value)}
              className="mt-2 min-h-11 w-full rounded-xl border border-slate-200 px-3 font-normal"
            />
          </label>
        )}
        {action.type === "CREATE_PERIOD" && (
          <div className="mt-5 grid grid-cols-2 gap-4">
            <label className="text-sm font-black">
              Tahun
              <input
                type="number"
                min="2000"
                max="9999"
                value={year}
                onChange={(event) => setYear(Number(event.target.value))}
                className="mt-2 min-h-11 w-full rounded-xl border border-slate-200 px-3 font-normal"
              />
            </label>
            <label className="text-sm font-black">
              Bulan
              <select
                value={month}
                onChange={(event) => setMonth(Number(event.target.value))}
                className="mt-2 min-h-11 w-full rounded-xl border border-slate-200 bg-white px-3 font-normal"
              >
                {Array.from({ length: 12 }, (_, index) => (
                  <option key={index + 1} value={index + 1}>
                    {new Intl.DateTimeFormat("id-ID", { month: "long" }).format(
                      new Date(2026, index, 1),
                    )}
                  </option>
                ))}
              </select>
            </label>
          </div>
        )}
        {(action.type === "PREVIEW_QUEUE" ||
          action.type === "PROCESS_AUTOMATIC") && (
          <label className="mt-5 block text-sm font-black">
            Maksimal event
            <input
              type="number"
              min="1"
              max="500"
              value={limit}
              onChange={(event) => setLimit(Number(event.target.value))}
              className="mt-2 min-h-11 w-full rounded-xl border border-slate-200 px-3 font-normal"
            />
            <span className="mt-2 block text-xs font-normal text-slate-500">
              {action.type === "PREVIEW_QUEUE"
                ? "Preview tidak memposting dan selalu dapat ditinjau dahulu."
                : "Hanya event HOLD yang didukung akan dicoba. Kegagalan tetap retryable."}
            </span>
          </label>
        )}
        {needsReason && (
          <label className="mt-5 block text-sm font-black">
            Alasan
            <textarea
              value={reason}
              onChange={(event) => setReason(event.target.value)}
              rows={4}
              maxLength={1000}
              placeholder={
                action.type === "REVERSE"
                  ? "Jelaskan mengapa jurnal harus dibalik"
                  : "Jelaskan mengapa periode perlu dibuka kembali"
              }
              className="mt-2 w-full rounded-xl border border-slate-200 p-3 font-normal"
            />
          </label>
        )}
        <label className="mt-5 flex cursor-pointer items-start gap-3 rounded-2xl border border-slate-200 p-4 text-sm font-semibold">
          <input
            type="checkbox"
            checked={confirmed}
            onChange={(event) => setConfirmed(event.target.checked)}
            className="mt-0.5 h-4 w-4 accent-violet-600"
          />
          <span>
            Saya sudah memeriksa Company aktif, periode, sumber, nominal, dan
            dampak tindakan ini.
          </span>
        </label>
        {error && (
          <p className="mt-4 rounded-xl bg-rose-50 p-3 text-sm font-bold text-rose-700">
            {error}
          </p>
        )}
        <div className="mt-6 flex justify-end gap-3 border-t border-slate-100 pt-5">
          <button
            onClick={close}
            disabled={busy}
            className="min-h-11 rounded-xl border border-slate-200 px-5 text-sm font-black text-slate-600"
          >
            Kembali
          </button>
          <button
            onClick={() => void submit()}
            disabled={busy || !valid}
            className="inline-flex min-h-11 items-center gap-2 rounded-xl bg-violet-600 px-5 text-sm font-black text-white disabled:bg-slate-300"
          >
            {busy ? (
              <Loader2 className="h-4 w-4 animate-spin" />
            ) : (
              <CheckCircle2 className="h-4 w-4" />
            )}
            Konfirmasi
          </button>
        </div>
      </section>
    </div>
  );
}

function Empty({ text }: { text: string }) {
  return (
    <div className="p-10 text-center text-sm font-semibold text-slate-400">
      {text}
    </div>
  );
}
