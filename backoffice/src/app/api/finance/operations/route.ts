import {
  ApiRouteError,
  apiError,
  requireActiveCompany,
  requireCaller,
} from "@/lib/server-auth";
import {
  integerValue,
  readJsonObject,
  requiredText,
  requiredVersion,
  throwDatabaseError,
  uuidValue,
} from "@/lib/master-data";
import { requireDataExchangeAction } from "@/lib/data-exchange-server";

const datePattern = /^\d{4}-\d{2}-\d{2}$/;

function dateValue(value: unknown, code: string): string {
  if (typeof value !== "string" || !datePattern.test(value)) {
    throw new ApiRouteError(code, 400);
  }
  const parsed = new Date(`${value}T00:00:00Z`);
  if (
    Number.isNaN(parsed.valueOf()) ||
    parsed.toISOString().slice(0, 10) !== value
  ) {
    throw new ApiRouteError(code, 400);
  }
  return value;
}

function nullableUuid(value: string | null, code: string): string | null {
  return value ? uuidValue(value, code) : null;
}

function rpcError(error: { code?: string; message?: string } | null): never {
  const message = error?.message ?? "FINANCE_OPERATION_FAILED";
  if (error?.code === "42501" || message.includes("ROLE_REQUIRED")) {
    throw new ApiRouteError(message, 403);
  }
  if (
    message.includes("MASTER_VERSION_CONFLICT") ||
    message.includes("ALREADY_EXISTS") ||
    message.includes("ALREADY_REVERSED") ||
    message.includes("ACTIVE_FINANCE_POSTING_QUEUE_ALREADY_EXISTS")
  ) {
    throw new ApiRouteError(message, 409);
  }
  if (
    message.includes("_REQUIRED") ||
    message.includes("_INVALID") ||
    message.includes("_NOT_FOUND") ||
    message.includes("_NOT_OPEN") ||
    message.includes("_NOT_LOCKED") ||
    message.includes("_NOT_APPROVED") ||
    message.includes("_NOT_PREVIEWED") ||
    message.includes("_LOCKED") ||
    message.includes("_STALE") ||
    message.includes("SOURCE_DOCUMENT_REVERSAL_REQUIRED") ||
    message.includes("HISTORICAL_SUBLEDGER_SNAPSHOT_UNAVAILABLE") ||
    message.includes("NO_SUPPORTED_HOLD_EVENTS")
  ) {
    throw new ApiRouteError(message, 400);
  }
  throwDatabaseError(error);
}

async function reportResponse(request: Request, report: string) {
  const caller = await requireCaller(request);
  const companyId = await requireActiveCompany(caller);
  await requireDataExchangeAction(caller, companyId, report, "EXPORT");
  const params = new URL(request.url).searchParams;
  const asOf = dateValue(params.get("asOf"), "REPORT_AS_OF_INVALID");
  const dateFrom = params.get("dateFrom")
    ? dateValue(params.get("dateFrom"), "REPORT_DATE_FROM_INVALID")
    : asOf;
  const storeId = nullableUuid(params.get("storeId"), "REPORT_STORE_INVALID");
  const warehouseId = nullableUuid(
    params.get("warehouseId"),
    "REPORT_WAREHOUSE_INVALID",
  );

  let result;
  if (report === "TRIAL_BALANCE") {
    result = await caller.client.rpc("get_finance_trial_balance", {
      p_date_from: dateFrom,
      p_as_of: asOf,
      p_store_id: storeId,
      p_warehouse_id: warehouseId,
    });
  } else if (report === "INCOME_STATEMENT") {
    result = await caller.client.rpc("get_finance_income_statement", {
      p_date_from: dateFrom,
      p_as_of: asOf,
      p_store_id: storeId,
      p_warehouse_id: warehouseId,
    });
  } else if (report === "BALANCE_SHEET") {
    result = await caller.client.rpc("get_finance_balance_sheet", {
      p_as_of: asOf,
      p_store_id: storeId,
      p_warehouse_id: warehouseId,
    });
  } else if (report === "PENDING_ANALYSIS") {
    result = await caller.client.rpc("get_finance_pending_analysis", {
      p_date_from: dateFrom,
      p_as_of: asOf,
      p_limit: 200,
      p_offset: 0,
    });
  } else if (report === "RECONCILIATION_SUMMARY") {
    result = await caller.client.rpc("get_finance_reconciliation_summary", {
      p_as_of: asOf,
    });
  } else if (report === "GENERAL_LEDGER") {
    const accountId = uuidValue(
      params.get("accountId") ?? "",
      "REPORT_ACCOUNT_INVALID",
    );
    result = await caller.client.rpc("get_finance_general_ledger", {
      p_account_id: accountId,
      p_date_from: dateFrom,
      p_as_of: asOf,
      p_store_id: storeId,
      p_warehouse_id: warehouseId,
      p_limit: 300,
      p_offset: 0,
    });
  } else {
    throw new ApiRouteError("FINANCE_REPORT_INVALID", 400);
  }

  if (result.error) rpcError(result.error);
  if (report === "GENERAL_LEDGER" && result.data) {
    const payload = result.data as {
      rows?: Array<Record<string, unknown> & { journalNo?: string }>;
    };
    const journalNos = [
      ...new Set(
        (payload.rows ?? []).map((row) => row.journalNo).filter(Boolean),
      ),
    ] as string[];
    if (journalNos.length) {
      const journals = await caller.client
        .from("finance_journals")
        .select("journal_no,display_no,description")
        .eq("company_id", companyId)
        .in("journal_no", journalNos);
      if (journals.error) throwDatabaseError(journals.error);
      const journalByNumber = new Map(
        (journals.data ?? []).map((row) => [row.journal_no, row]),
      );
      payload.rows = (payload.rows ?? []).map((row) => {
        const journal = journalByNumber.get(row.journalNo ?? "");
        return {
          ...row,
          journalDisplayNo: journal?.display_no ?? null,
          journalDescription: journal?.description ?? null,
        };
      });
    }
  }
  return Response.json({ data: result.data });
}

export async function GET(request: Request) {
  try {
    const params = new URL(request.url).searchParams;
    const report = params.get("report");
    if (report) return await reportResponse(request, report.toUpperCase());

    const caller = await requireCaller(request);
    const companyId = await requireActiveCompany(caller);
    const journalMonth = params.get("journalMonth");
    if (journalMonth && !/^\d{4}-(0[1-9]|1[0-2])$/.test(journalMonth)) {
      throw new ApiRouteError("JOURNAL_MONTH_INVALID", 400);
    }
    let journalQuery = caller.client
      .from("finance_journals")
      .select(
        "id,journal_no,display_no,journal_type,accounting_period_id,accounting_date,original_event_date,source_type,source_id,system_event_key,description,status,total_debit,total_credit,reversal_of_journal_id,master_version,created_at,posted_at",
      )
      .eq("company_id", companyId);
    if (journalMonth) {
      const [year, month] = journalMonth.split("-").map(Number);
      const lastDay = new Date(Date.UTC(year, month, 0)).getUTCDate();
      journalQuery = journalQuery
        .gte("accounting_date", `${journalMonth}-01`)
        .lte(
          "accounting_date",
          `${journalMonth}-${String(lastDay).padStart(2, "0")}`,
        );
    }
    const journalsPromise = journalQuery
      .order("accounting_date", { ascending: false })
      .order("created_at", { ascending: false })
      .limit(journalMonth ? 5000 : 200);
    const [company, periods, journals, queueRuns, exceptions, accounts, policy] =
      await Promise.all([
        caller.client
          .from("companies")
          .select("company_name,company_code,timezone")
          .eq("id", companyId)
          .single(),
        caller.client
          .from("accounting_periods")
          .select(
            "id,period_year,period_month,start_date,end_date,status,master_version,closed_at,reopened_at,reopen_reason",
          )
          .eq("company_id", companyId)
          .order("start_date", { ascending: false })
          .limit(120),
        journalsPromise,
        caller.client
          .from("finance_posting_queue_runs")
          .select(
            "id,queue_no,display_no,scope_system_key,status,preview_limit,previewed_event_count,posted_count,failed_count,skipped_count,master_version,created_at,approved_at,processing_started_at,processed_at",
          )
          .eq("company_id", companyId)
          .order("created_at", { ascending: false })
          .limit(50),
        caller.client
          .from("finance_posting_exceptions")
          .select(
            "id,display_no,financial_event_id,source_table,system_key,reason_code,status,retry_count,last_error,created_at,updated_at",
          )
          .eq("company_id", companyId)
          .neq("status", "RESOLVED")
          .order("created_at", { ascending: false })
          .limit(100),
        caller.client
          .from("chart_of_accounts")
          .select(
            "id,account_code,account_name,account_type,is_active,is_postable",
          )
          .eq("company_id", companyId)
          .eq("is_postable", true)
          .order("account_code")
          .limit(1000),
        caller.client.rpc("get_finance_company_policy"),
      ]);
    for (const result of [
      company,
      periods,
      journals,
      queueRuns,
      exceptions,
      accounts,
      policy,
    ]) {
      if (result.error) throwDatabaseError(result.error);
    }

    const journalIds = (journals.data ?? []).map((row) => row.id);
    const queueIds = (queueRuns.data ?? []).map((row) => row.id);
    const [journalLines, queueItems, reversedJournals] = await Promise.all([
      journalIds.length
        ? caller.client
            .from("finance_journal_lines")
            .select(
              "id,journal_id,line_no,account_id,account_code_snapshot,account_name_snapshot,debit,credit,store_id,warehouse_id,customer_id,supplier_id,description",
            )
            .eq("company_id", companyId)
            .in("journal_id", journalIds)
            .order("line_no")
        : Promise.resolve({ data: [], error: null }),
      queueIds.length
        ? caller.client
            .from("finance_posting_queue_items")
            .select(
              "id,queue_run_id,line_no,event_code_snapshot,system_event_key_snapshot,event_date_snapshot,status,attempt_count,journal_id,error_code,error_message,processed_at",
            )
            .eq("company_id", companyId)
            .in("queue_run_id", queueIds)
            .order("line_no")
            .limit(1000)
        : Promise.resolve({ data: [], error: null }),
      caller.client
        .from("finance_journals")
        .select("reversal_of_journal_id")
        .eq("company_id", companyId)
        .not("reversal_of_journal_id", "is", null)
        .limit(5000),
    ]);
    if (journalLines.error) throwDatabaseError(journalLines.error);
    if (queueItems.error) throwDatabaseError(queueItems.error);
    if (reversedJournals.error) throwDatabaseError(reversedJournals.error);

    return Response.json({
      companyId,
      company: company.data,
      periods: periods.data ?? [],
      journals: journals.data ?? [],
      journalLines: journalLines.data ?? [],
      reversedJournalIds: (reversedJournals.data ?? []).map(
        (row) => row.reversal_of_journal_id,
      ),
      queueRuns: queueRuns.data ?? [],
      queueItems: queueItems.data ?? [],
      exceptions: exceptions.data ?? [],
      accounts: accounts.data ?? [],
      policy: policy.data,
    });
  } catch (error) {
    return apiError(error);
  }
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request);
    await requireActiveCompany(caller);
    const body = await readJsonObject(request);
    const action = requiredText(body, "action", {
      uppercase: true,
      maxLength: 40,
    });
    let result;

    if (action === "CREATE_PERIOD") {
      result = await caller.client.rpc("create_accounting_period", {
        p_period_year: integerValue(
          body.year,
          "PERIOD_YEAR_INVALID",
          2000,
          9999,
        ),
        p_period_month: integerValue(body.month, "PERIOD_MONTH_INVALID", 1, 12),
      });
    } else if (action === "SAVE_PERIOD_POLICY") {
      result = await caller.client.rpc("save_finance_company_policy", {
        p_master_version: requiredVersion(body),
        p_period_creation_mode: requiredText(body, "periodCreationMode", {
          uppercase: true,
          maxLength: 20,
        }),
      });
    } else if (action === "SAVE_POSTING_POLICY") {
      result = await caller.client.rpc("save_finance_posting_policy", {
        p_master_version: requiredVersion(body),
        p_posting_mode: requiredText(body, "postingMode", {
          uppercase: true,
          maxLength: 20,
        }),
      });
    } else if (action === "PROCESS_AUTOMATIC") {
      result = await caller.client.rpc("process_automatic_financial_events", {
        p_limit: integerValue(
          body.limit,
          "AUTOMATIC_POSTING_LIMIT_INVALID",
          1,
          500,
        ),
      });
    } else if (action === "LOCK_PERIOD") {
      result = await caller.client.rpc("lock_accounting_period", {
        p_period_id: uuidValue(
          String(body.periodId ?? ""),
          "PERIOD_ID_INVALID",
        ),
        p_master_version: requiredVersion(body),
      });
    } else if (action === "REOPEN_PERIOD") {
      result = await caller.client.rpc("reopen_accounting_period", {
        p_period_id: uuidValue(
          String(body.periodId ?? ""),
          "PERIOD_ID_INVALID",
        ),
        p_master_version: requiredVersion(body),
        p_reason: requiredText(body, "reason", { maxLength: 1000 }),
      });
    } else if (action === "REVERSE_JOURNAL") {
      result = await caller.client.rpc("reverse_finance_journal", {
        p_journal_id: uuidValue(
          String(body.journalId ?? ""),
          "JOURNAL_ID_INVALID",
        ),
        p_expected_master_version: requiredVersion(body),
        p_accounting_date: dateValue(
          body.accountingDate,
          "ACCOUNTING_DATE_INVALID",
        ),
        p_reason: requiredText(body, "reason", { maxLength: 1000 }),
        p_idempotency_key: uuidValue(
          String(body.idempotencyKey ?? ""),
          "IDEMPOTENCY_KEY_INVALID",
        ),
      });
    } else if (action === "PREVIEW_QUEUE") {
      result = await caller.client.rpc(
        "preview_financial_event_posting_queue",
        {
          p_limit: integerValue(
            body.limit,
            "QUEUE_PREVIEW_LIMIT_INVALID",
            1,
            500,
          ),
        },
      );
    } else if (action === "APPROVE_QUEUE") {
      result = await caller.client.rpc(
        "approve_financial_event_posting_queue",
        {
          p_queue_run_id: uuidValue(
            String(body.queueRunId ?? ""),
            "QUEUE_ID_INVALID",
          ),
          p_expected_master_version: requiredVersion(body),
        },
      );
    } else if (action === "PROCESS_QUEUE") {
      result = await caller.client.rpc(
        "process_financial_event_posting_queue",
        {
          p_queue_run_id: uuidValue(
            String(body.queueRunId ?? ""),
            "QUEUE_ID_INVALID",
          ),
          p_expected_master_version: requiredVersion(body),
        },
      );
    } else {
      throw new ApiRouteError("FINANCE_OPERATION_INVALID", 400);
    }

    if (result.error) rpcError(result.error);
    return Response.json({ data: result.data });
  } catch (error) {
    return apiError(error);
  }
}
