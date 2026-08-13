import {
  ApiRouteError,
  apiError,
  requireActiveCompany,
  requireCaller,
} from "@/lib/server-auth";
import { throwDatabaseError } from "@/lib/master-data";
import { createXlsx, type WorkbookCell, type WorkbookSheet } from "@/lib/xlsx";
import { requireDataExchangeAction } from "@/lib/data-exchange-server";

const monthPattern = /^\d{4}-(0[1-9]|1[0-2])$/;
const exportTypes = [
  "GENERAL_LEDGER",
  "JOURNAL_ENTRIES",
  "TRIAL_BALANCE",
  "INCOME_STATEMENT",
  "BALANCE_SHEET",
  "PENDING_ANALYSIS",
  "RECONCILIATION_SUMMARY",
  "CUSTOMER_BALANCES",
  "SUPPLIER_INVOICES",
  "SUPPLIER_PAYMENTS",
] as const;
type ExportType = (typeof exportTypes)[number];

type JournalRow = {
  id: string;
  display_no: string;
  journal_type: string;
  accounting_date: string;
  source_type: string;
  description: string;
  status: string;
  total_debit: number | string;
  total_credit: number | string;
};

type LineRow = {
  journal_id: string;
  line_no: number;
  account_id: string;
  account_code_snapshot: string;
  account_name_snapshot: string;
  description: string | null;
  debit: number | string;
  credit: number | string;
};

type TrialRow = {
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

function periodRange(month: string) {
  if (!monthPattern.test(month))
    throw new ApiRouteError("EXPORT_MONTH_INVALID", 400);
  const [year, monthNumber] = month.split("-").map(Number);
  const lastDay = new Date(Date.UTC(year, monthNumber, 0)).getUTCDate();
  return {
    dateFrom: `${month}-01`,
    asOf: `${month}-${String(lastDay).padStart(2, "0")}`,
  };
}

function exportType(value: string | null): ExportType {
  const normalized = value?.toUpperCase();
  if (!exportTypes.includes(normalized as ExportType)) {
    throw new ApiRouteError("FINANCE_EXPORT_TYPE_INVALID", 400);
  }
  return normalized as ExportType;
}

function number(value: number | string | null | undefined) {
  return Number(value) || 0;
}

function sourceLabel(value: string) {
  const labels: Record<string, string> = {
    opening_stock_documents: "Stok Awal",
    FINANCE_JOURNAL_REVERSAL: "Jurnal Pembalik",
    MANUAL: "Jurnal Manual",
  };
  return (
    labels[value] ??
    value
      .replaceAll("_", " ")
      .toLowerCase()
      .replace(/\b\w/g, (letter) => letter.toUpperCase())
  );
}

const reportLabels: Record<ExportType, string> = {
  GENERAL_LEDGER: "General Ledger",
  JOURNAL_ENTRIES: "Journal Entries",
  TRIAL_BALANCE: "Trial Balance",
  INCOME_STATEMENT: "Income Statement",
  BALANCE_SHEET: "Balance Sheet",
  PENDING_ANALYSIS: "Pending Analysis",
  RECONCILIATION_SUMMARY: "Reconciliation Summary",
  CUSTOMER_BALANCES: "Customer Balances",
  SUPPLIER_INVOICES: "Supplier Invoices",
  SUPPLIER_PAYMENTS: "Supplier Payments",
};

function workbookCell(value: unknown): WorkbookCell {
  if (
    value === null ||
    value === undefined ||
    typeof value === "string" ||
    typeof value === "number" ||
    typeof value === "boolean"
  ) {
    return value;
  }
  return JSON.stringify(value);
}

function reportSheets(
  type: ExportType,
  payload: Record<string, unknown>,
  metadata: WorkbookCell[][],
): WorkbookSheet[] {
  const rows = Array.isArray(payload.rows)
    ? (payload.rows.filter(
        (row): row is Record<string, unknown> =>
          Boolean(row) && typeof row === "object" && !Array.isArray(row),
      ))
    : [];
  const preferred = [
    "accountCode",
    "accountName",
    "accountType",
    "normalBalance",
    "systemEventKey",
    "sourceTable",
    "status",
    "reconciliationType",
    "description",
    "openingBalance",
    "periodDebit",
    "periodCredit",
    "closingBalance",
    "amount",
    "potentialAmount",
    "subledgerBalance",
    "ledgerBalance",
    "difference",
    "eventCount",
  ];
  const keySet = new Set(rows.flatMap((row) => Object.keys(row)));
  const columns = [
    ...preferred.filter((key) => keySet.delete(key)),
    ...[...keySet].sort(),
  ];
  const summary = Object.entries(payload)
    .filter(([key, value]) => key !== "rows" && !Array.isArray(value))
    .map(([key, value]) => [key, workbookCell(value)] as WorkbookCell[]);

  return [
    {
      name: reportLabels[type],
      widths: columns.map(() => 24),
      rows: [
        columns,
        ...rows.map((row) => columns.map((column) => workbookCell(row[column]))),
      ],
    },
    {
      name: "Summary",
      widths: [28, 48],
      rows: [["Field", "Value"], ...summary],
    },
    { name: "Metadata", widths: [24, 48], rows: metadata },
  ];
}

async function canonicalReport(
  caller: Awaited<ReturnType<typeof requireCaller>>,
  type: ExportType,
  dateFrom: string,
  asOf: string,
) {
  if (type === "TRIAL_BALANCE") {
    return caller.client.rpc("get_finance_trial_balance", {
      p_date_from: dateFrom,
      p_as_of: asOf,
      p_store_id: null,
      p_warehouse_id: null,
    });
  }
  if (type === "INCOME_STATEMENT") {
    return caller.client.rpc("get_finance_income_statement", {
      p_date_from: dateFrom,
      p_as_of: asOf,
      p_store_id: null,
      p_warehouse_id: null,
    });
  }
  if (type === "BALANCE_SHEET") {
    return caller.client.rpc("get_finance_balance_sheet", {
      p_as_of: asOf,
      p_store_id: null,
      p_warehouse_id: null,
    });
  }
  if (type === "PENDING_ANALYSIS") {
    return caller.client.rpc("get_finance_pending_analysis", {
      p_date_from: dateFrom,
      p_as_of: asOf,
      p_limit: 500,
      p_offset: 0,
    });
  }
  if (type === "CUSTOMER_BALANCES") {
    return caller.client.rpc("export_finance_customer_balances", {
      p_from: `${dateFrom}T00:00:00Z`,
      p_to: `${asOf}T23:59:59.999Z`,
    });
  }
  if (type === "SUPPLIER_INVOICES") {
    return caller.client.rpc("export_finance_supplier_invoices", {
      p_from: `${dateFrom}T00:00:00Z`,
      p_to: `${asOf}T23:59:59.999Z`,
    });
  }
  if (type === "SUPPLIER_PAYMENTS") {
    return caller.client.rpc("export_finance_supplier_payments", {
      p_from: `${dateFrom}T00:00:00Z`,
      p_to: `${asOf}T23:59:59.999Z`,
    });
  }
  return caller.client.rpc("get_finance_reconciliation_summary", {
    p_as_of: asOf,
  });
}

async function loadLines(
  caller: Awaited<ReturnType<typeof requireCaller>>,
  companyId: string,
  journalIds: string[],
) {
  const rows: LineRow[] = [];
  for (let index = 0; index < journalIds.length; index += 150) {
    const result = await caller.client
      .from("finance_journal_lines")
      .select(
        "journal_id,line_no,account_id,account_code_snapshot,account_name_snapshot,description,debit,credit",
      )
      .eq("company_id", companyId)
      .in("journal_id", journalIds.slice(index, index + 150))
      .order("line_no");
    if (result.error) throwDatabaseError(result.error);
    rows.push(...((result.data ?? []) as LineRow[]));
  }
  return rows;
}

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request);
    const companyId = await requireActiveCompany(caller);
    const params = new URL(request.url).searchParams;
    const type = exportType(params.get("type"));
    await requireDataExchangeAction(caller, companyId, type, "EXPORT");
    const month = params.get("month") ?? "";
    const { dateFrom, asOf } = periodRange(month);

    if (!["GENERAL_LEDGER", "JOURNAL_ENTRIES"].includes(type)) {
      const company = await caller.client
        .from("companies")
        .select("company_name,company_code,timezone")
        .eq("id", companyId)
        .single();
      if (company.error) throwDatabaseError(company.error);
      const report = await canonicalReport(caller, type, dateFrom, asOf);
      if (report.error) throwDatabaseError(report.error);
      const payload = (report.data ?? {}) as Record<string, unknown>;
      const metadata: WorkbookCell[][] = [
        ["Field", "Value"],
        ["Company", company.data.company_name],
        ["Company Code", company.data.company_code],
        ["Timezone", company.data.timezone],
        ["Period", month],
        ["Date From", dateFrom],
        ["As Of", asOf],
        ["Generated At", new Date().toISOString()],
        ["Report Version", workbookCell(payload.reportVersion ?? "-")],
        ["Accounting Basis", "Canonical POSTED report"],
      ];
      const workbook = createXlsx(reportSheets(type, payload, metadata));
      const companyCode = String(company.data.company_code ?? "COMPANY").replace(
        /[^A-Z0-9_-]+/gi,
        "-",
      );
      return new Response(Buffer.from(workbook), {
        headers: {
          "Content-Type":
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
          "Content-Disposition": `attachment; filename="${reportLabels[type].replaceAll(" ", "-")}_${companyCode}_${month}.xlsx"`,
          "Cache-Control": "private, no-store",
        },
      });
    }

    const [company, journals, trial] = await Promise.all([
      caller.client
        .from("companies")
        .select("company_name,company_code,timezone")
        .eq("id", companyId)
        .single(),
      caller.client
        .from("finance_journals")
        .select(
          "id,display_no,journal_type,accounting_date,source_type,description,status,total_debit,total_credit",
        )
        .eq("company_id", companyId)
        .gte("accounting_date", dateFrom)
        .lte("accounting_date", asOf)
        .order("accounting_date")
        .order("created_at")
        .limit(5001),
      caller.client.rpc("get_finance_trial_balance", {
        p_date_from: dateFrom,
        p_as_of: asOf,
        p_store_id: null,
        p_warehouse_id: null,
      }),
    ]);
    if (company.error) throwDatabaseError(company.error);
    if (journals.error) throwDatabaseError(journals.error);
    if (trial.error) throwDatabaseError(trial.error);
    if ((journals.data ?? []).length > 5000) {
      throw new ApiRouteError("FINANCE_EXPORT_LIMIT_EXCEEDED", 400);
    }

    const journalRows = (journals.data ?? []) as JournalRow[];
    const detailJournalRows =
      type === "GENERAL_LEDGER"
        ? journalRows.filter((row) => row.status === "POSTED")
        : journalRows;
    const lines = await loadLines(
      caller,
      companyId,
      detailJournalRows.map((row) => row.id),
    );
    if (lines.length > 20000) {
      throw new ApiRouteError("FINANCE_EXPORT_LIMIT_EXCEEDED", 400);
    }
    const trialPayload = trial.data as {
      reportVersion?: number;
      rows?: TrialRow[];
    };
    const trialRows = trialPayload.rows ?? [];
    const journalsById = new Map(detailJournalRows.map((row) => [row.id, row]));
    const accountById = new Map(trialRows.map((row) => [row.accountId, row]));
    const generatedAt = new Date().toISOString();
    const metadata: WorkbookCell[][] = [
      ["Field", "Value"],
      ["Company", company.data.company_name],
      ["Company Code", company.data.company_code],
      ["Period", month],
      ["Date From", dateFrom],
      ["As Of", asOf],
      ["Timezone", company.data.timezone],
      ["Generated At", generatedAt],
      ["Report Version", trialPayload.reportVersion ?? "-"],
      ["Export Type", type],
      [
        "Accounting Basis",
        type === "GENERAL_LEDGER"
          ? "POSTED journal only"
          : "All journal document statuses",
      ],
    ];
    let sheets: WorkbookSheet[];

    if (type === "JOURNAL_ENTRIES") {
      sheets = [
        {
          name: "Journal Entries",
          widths: [24, 14, 22, 24, 48, 14, 18, 18],
          rows: [
            [
              "Nomor Jurnal",
              "Tanggal",
              "Jenis",
              "Sumber",
              "Keterangan",
              "Status",
              "Total Debit",
              "Total Kredit",
            ],
            ...journalRows.map((journal) => [
              journal.display_no,
              journal.accounting_date,
              journal.journal_type,
              sourceLabel(journal.source_type),
              journal.description,
              journal.status,
              number(journal.total_debit),
              number(journal.total_credit),
            ]),
          ],
        },
        {
          name: "Journal Lines",
          widths: [24, 10, 18, 34, 48, 18, 18],
          rows: [
            [
              "Nomor Jurnal",
              "Baris",
              "Kode Akun",
              "Nama Akun",
              "Keterangan",
              "Debit",
              "Kredit",
            ],
            ...lines.map((line) => [
              journalsById.get(line.journal_id)?.display_no ?? "-",
              line.line_no,
              line.account_code_snapshot,
              line.account_name_snapshot,
              line.description ?? "-",
              number(line.debit),
              number(line.credit),
            ]),
          ],
        },
        { name: "Metadata", widths: [24, 48], rows: metadata },
      ];
    } else {
      const runningByAccount = new Map(
        trialRows.map((account) => [
          account.accountId,
          number(account.openingBalance),
        ]),
      );
      const detailRows: WorkbookCell[][] = [];
      const sortedLines = [...lines].sort((left, right) => {
        const leftJournal = journalsById.get(left.journal_id);
        const rightJournal = journalsById.get(right.journal_id);
        return `${left.account_code_snapshot}|${leftJournal?.accounting_date}|${leftJournal?.display_no}|${left.line_no}`.localeCompare(
          `${right.account_code_snapshot}|${rightJournal?.accounting_date}|${rightJournal?.display_no}|${right.line_no}`,
        );
      });
      for (const line of sortedLines) {
        const journal = journalsById.get(line.journal_id);
        const account = accountById.get(line.account_id);
        const current = runningByAccount.get(line.account_id) ?? 0;
        const next =
          account?.normalBalance === "CREDIT"
            ? current + number(line.credit) - number(line.debit)
            : current + number(line.debit) - number(line.credit);
        runningByAccount.set(line.account_id, next);
        detailRows.push([
          line.account_code_snapshot,
          line.account_name_snapshot,
          journal?.accounting_date ?? "-",
          journal?.display_no ?? "-",
          sourceLabel(journal?.source_type ?? "-"),
          line.description ?? journal?.description ?? "-",
          number(line.debit),
          number(line.credit),
          next,
        ]);
      }
      sheets = [
        {
          name: "Account Summary",
          widths: [18, 36, 20, 20, 20, 20, 20],
          rows: [
            [
              "Kode Akun",
              "Nama Akun",
              "Tipe",
              "Saldo Awal",
              "Debit",
              "Kredit",
              "Saldo Akhir",
            ],
            ...trialRows.map((account) => [
              account.accountCode,
              account.accountName,
              account.accountType,
              number(account.openingBalance),
              number(account.periodDebit),
              number(account.periodCredit),
              number(account.closingBalance),
            ]),
          ],
        },
        {
          name: "Ledger Detail",
          widths: [18, 34, 14, 24, 24, 48, 18, 18, 20],
          rows: [
            [
              "Kode Akun",
              "Nama Akun",
              "Tanggal",
              "Nomor Jurnal",
              "Sumber",
              "Keterangan",
              "Debit",
              "Kredit",
              "Saldo Berjalan",
            ],
            ...detailRows,
          ],
        },
        { name: "Metadata", widths: [24, 48], rows: metadata },
      ];
    }

    const workbook = createXlsx(sheets);
    const companyCode = String(company.data.company_code ?? "COMPANY").replace(
      /[^A-Z0-9_-]+/gi,
      "-",
    );
    const prefix =
      type === "GENERAL_LEDGER" ? "General-Ledger" : "Journal-Entries";
    return new Response(Buffer.from(workbook), {
      headers: {
        "Content-Type":
          "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "Content-Disposition": `attachment; filename="${prefix}_${companyCode}_${month}.xlsx"`,
        "Cache-Control": "private, no-store",
      },
    });
  } catch (error) {
    return apiError(error);
  }
}
