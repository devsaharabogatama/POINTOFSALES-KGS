import {
  ApiRouteError,
  apiError,
  requireActiveCompany,
  requireCaller,
  requirePermissionCapability,
} from "@/lib/server-auth";
import { throwDatabaseError } from "@/lib/master-data";

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function uuid(value: unknown, code: string) {
  const normalized = String(value ?? "").trim();
  if (!uuidPattern.test(normalized)) throw new ApiRouteError(code, 400);
  return normalized;
}

function optionalUuid(value: unknown, code: string) {
  const normalized = String(value ?? "").trim();
  return normalized ? uuid(normalized, code) : null;
}

function text(value: unknown, code: string, max: number, optional = false) {
  const normalized = String(value ?? "").trim();
  if (!normalized) {
    if (optional) return null;
    throw new ApiRouteError(code, 400);
  }
  if (normalized.length > max) throw new ApiRouteError(code, 400);
  return normalized;
}

function version(value: unknown) {
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 1) {
    throw new ApiRouteError("MASTER_VERSION_INVALID", 400);
  }
  return parsed;
}

function date(value: unknown, code: string, optional = false) {
  const normalized = String(value ?? "").trim();
  if (!normalized && optional) return null;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(normalized)) {
    throw new ApiRouteError(code, 400);
  }
  const parsed = new Date(`${normalized}T00:00:00Z`);
  if (Number.isNaN(parsed.valueOf()) || parsed.toISOString().slice(0, 10) !== normalized) {
    throw new ApiRouteError(code, 400);
  }
  return normalized;
}

function money(value: unknown, code: string) {
  const parsed = Number(value ?? 0);
  if (!Number.isFinite(parsed) || parsed < 0) throw new ApiRouteError(code, 400);
  return Math.round(parsed * 10000) / 10000;
}

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request);
    await requireActiveCompany(caller);
    const result = await caller.client.rpc("get_opening_balance_workspace");
    if (result.error) throwDatabaseError(result.error);
    return Response.json({ data: result.data });
  } catch (error) {
    return apiError(error);
  }
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request);
    const companyId = await requireActiveCompany(caller);
    const body = (await request.json()) as Record<string, unknown>;
    const action = String(body.action ?? "").trim().toUpperCase();

    if (action === "SAVE_DRAFT") {
      const documentId = optionalUuid(body.documentId, "OPENING_BALANCE_ID_INVALID");
      await requirePermissionCapability(
        caller,
        companyId,
        "finance.manual_journals",
        documentId ? "EDIT_DRAFT" : "CREATE_DRAFT",
      );
      if (!Array.isArray(body.lines) || body.lines.length < 2 || body.lines.length > 500) {
        throw new ApiRouteError("OPENING_BALANCE_LINES_INVALID", 400);
      }
      const lines = body.lines.map((raw) => {
        if (!raw || typeof raw !== "object") {
          throw new ApiRouteError("OPENING_BALANCE_LINE_INVALID", 400);
        }
        const row = raw as Record<string, unknown>;
        const lineType = String(row.lineType ?? "").trim().toUpperCase();
        if (!["GL", "RECEIVABLE", "PAYABLE"].includes(lineType)) {
          throw new ApiRouteError("OPENING_BALANCE_LINE_TYPE_INVALID", 400);
        }
        return {
          lineType,
          accountId: uuid(row.accountId, "OPENING_BALANCE_ACCOUNT_INVALID"),
          customerId: optionalUuid(row.customerId, "OPENING_BALANCE_CUSTOMER_INVALID"),
          supplierId: optionalUuid(row.supplierId, "OPENING_BALANCE_SUPPLIER_INVALID"),
          sourceDocumentNo: null,
          sourceDocumentDate: null,
          dueDate: null,
          debit: money(row.debit, "OPENING_BALANCE_DEBIT_INVALID"),
          credit: money(row.credit, "OPENING_BALANCE_CREDIT_INVALID"),
          description: text(row.description, "OPENING_BALANCE_LINE_DESCRIPTION_INVALID", 500, true),
        };
      });
      const result = await caller.client.rpc("save_opening_balance_draft", {
        p_document_id: documentId,
        p_master_version: documentId ? version(body.masterVersion) : null,
        p_operation_key: uuid(body.operationKey, "OPERATION_KEY_INVALID"),
        p_effective_date: date(body.effectiveDate, "OPENING_BALANCE_DATE_INVALID"),
        p_external_reference: text(body.externalReference, "EXTERNAL_REFERENCE_INVALID", 200, true),
        p_description: text(body.description, "OPENING_BALANCE_DESCRIPTION_INVALID", 1000),
        p_lines: lines,
      });
      if (result.error) throwDatabaseError(result.error);
      return Response.json({ data: result.data });
    }

    if (action === "SUBMIT") {
      await requirePermissionCapability(caller, companyId, "finance.manual_journals", "EDIT_DRAFT");
      const result = await caller.client.rpc("submit_opening_balance", {
        p_document_id: uuid(body.documentId, "OPENING_BALANCE_ID_INVALID"),
        p_master_version: version(body.masterVersion),
      });
      if (result.error) throwDatabaseError(result.error);
      return Response.json({ data: result.data });
    }

    if (action === "POST") {
      await requirePermissionCapability(caller, companyId, "finance.manual_journals", "APPROVE");
      const result = await caller.client.rpc("post_opening_balance", {
        p_document_id: uuid(body.documentId, "OPENING_BALANCE_ID_INVALID"),
        p_master_version: version(body.masterVersion),
        p_idempotency_key: uuid(body.idempotencyKey, "IDEMPOTENCY_KEY_INVALID"),
      });
      if (result.error) throwDatabaseError(result.error);
      return Response.json({ data: result.data });
    }

    if (action === "CANCEL") {
      await requirePermissionCapability(caller, companyId, "finance.manual_journals", "EDIT_DRAFT");
      const result = await caller.client.rpc("cancel_opening_balance", {
        p_document_id: uuid(body.documentId, "OPENING_BALANCE_ID_INVALID"),
        p_master_version: version(body.masterVersion),
        p_reason: text(body.reason, "CANCEL_REASON_REQUIRED", 500),
      });
      if (result.error) throwDatabaseError(result.error);
      return Response.json({ data: result.data });
    }

    throw new ApiRouteError("ACTION_INVALID", 400);
  } catch (error) {
    return apiError(error);
  }
}
