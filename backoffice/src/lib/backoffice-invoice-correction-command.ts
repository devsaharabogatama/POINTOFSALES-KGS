/**
 * Shared command contract for the future Invoice and Finance entry points.
 * NOT wired to a route yet. Syntax validation is not posting authorization.
 * The database must reload Company, Customer, allocation, period and amounts,
 * lock/recheck versions and commit source-linked effects atomically.
 */
export class InvoiceCorrectionCommandError extends Error {
  constructor(code: string) {
    super(code);
    this.name = "InvoiceCorrectionCommandError";
  }
}

type JsonObject = Record<string, unknown>;
type CommandBase = {
  invoiceId: string;
  operationId: string;
  masterVersion: number;
  revision: number;
  notes: string | null;
};
export type InvoiceRevisionCommand = CommandBase & {
  kind: "INVOICE_REVISION";
  customerId: string;
  invoiceDate: string;
  dueDate: { mode: "KEEP_TERM" } | { mode: "ADMIN_OVERRIDE"; date: string };
  lines: { invoiceLineId: string; unitPrice: string; discountAmount: string }[];
};
export type PaymentCorrectionCommand = CommandBase & {
  kind: "PAYMENT_CORRECTION";
  receiptId: string;
  receiptVersion: number;
  correction: { reason: "PAYMENT_NOT_RECEIVED" } |
    { reason: "WRONG_PAYMENT_DATE"; paymentDate: string };
};
export type InvoiceRefundCommand = CommandBase & {
  kind: "REFUND";
  creditId: string;
  creditVersion: number;
  refundDate: string;
  amount: string;
  paymentMethodId: string;
  referenceNo: string | null;
};
export type InvoiceCorrectionCommand = InvoiceRevisionCommand |
  PaymentCorrectionCommand | InvoiceRefundCommand;

function fail(code: string): never { throw new InvoiceCorrectionCommandError(code); }

function object(value: unknown): JsonObject {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    fail("INVOICE_CORRECTION_OBJECT_REQUIRED");
  }
  const prototype = Object.getPrototypeOf(value);
  if (prototype !== Object.prototype && prototype !== null) {
    fail("INVOICE_CORRECTION_OBJECT_REQUIRED");
  }
  return value as JsonObject;
}

function keys(value: JsonObject, allowed: string[]) {
  if (Object.keys(value).some((key) => !allowed.includes(key))) {
    fail("INVOICE_CORRECTION_UNKNOWN_FIELD");
  }
}

function uuid(value: unknown): string {
  // PostgreSQL accepts deterministic UUIDs, not only RFC v4/v5 IDs.
  if (typeof value !== "string" ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value) ||
    value === "00000000-0000-0000-0000-000000000000") {
    fail("INVOICE_CORRECTION_UUID_INVALID");
  }
  return value.toLowerCase();
}

function version(value: unknown, minimum: number): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < minimum) {
    fail("INVOICE_CORRECTION_VERSION_INVALID");
  }
  return value;
}

function nullableText(value: unknown, limit: number): string | null {
  if (value === undefined || value === null) return null;
  if (typeof value !== "string" || value.length > limit) {
    fail("INVOICE_CORRECTION_TEXT_INVALID");
  }
  return value.trim() || null;
}

export function correctionDate(value: unknown): string {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    fail("INVOICE_CORRECTION_DATE_INVALID");
  }
  const year = Number(value.slice(0, 4));
  const month = Number(value.slice(5, 7));
  const day = Number(value.slice(8, 10));
  const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  if (year < 1 || month < 1 || month > 12 || day < 1 || day > days[month - 1]) {
    fail("INVOICE_CORRECTION_DATE_INVALID");
  }
  return value;
}

function money(value: unknown, positive = false): string {
  // Keep numeric(24,4) precision. No null/boolean coercion or float calculation.
  if (typeof value !== "string" || !/^(0|[1-9]\d{0,19})(\.\d{1,4})?$/.test(value)) {
    fail("INVOICE_CORRECTION_MONEY_INVALID");
  }
  const [whole, fraction = ""] = value.split(".");
  const normalized = `${whole}.${fraction.padEnd(4, "0")}`;
  if (positive && normalized === "0.0000") fail("INVOICE_CORRECTION_AMOUNT_MUST_BE_POSITIVE");
  return normalized;
}

/** Amounts are decimal strings. Server-computed totals/journal entries are forbidden. */
export function parseInvoiceCorrectionCommand(input: unknown): InvoiceCorrectionCommand {
  const body = object(input);
  const commonKeys = ["kind", "invoiceId", "operationId", "masterVersion", "revision", "notes"];
  const base: CommandBase = {
    invoiceId: uuid(body.invoiceId), operationId: uuid(body.operationId),
    masterVersion: version(body.masterVersion, 1), revision: version(body.revision, 0),
    notes: nullableText(body.notes, 1000),
  };
  if (body.kind === "INVOICE_REVISION") {
    keys(body, [...commonKeys, "customerId", "invoiceDate", "dueDate", "lines"]);
    const due = object(body.dueDate);
    let dueDate: InvoiceRevisionCommand["dueDate"];
    if (due.mode === "KEEP_TERM") {
      keys(due, ["mode"]); dueDate = { mode: "KEEP_TERM" };
    } else if (due.mode === "ADMIN_OVERRIDE") {
      keys(due, ["mode", "date"]);
      dueDate = { mode: "ADMIN_OVERRIDE", date: correctionDate(due.date) };
    } else fail("INVOICE_CORRECTION_DUE_DATE_MODE_INVALID");
    const invoiceDate = correctionDate(body.invoiceDate);
    if (dueDate.mode === "ADMIN_OVERRIDE" && dueDate.date < invoiceDate) {
      fail("INVOICE_CORRECTION_DUE_DATE_BEFORE_INVOICE");
    }
    if (!Array.isArray(body.lines) || body.lines.length < 1 || body.lines.length > 500) {
      fail("INVOICE_CORRECTION_LINES_REQUIRED");
    }
    const seen = new Set<string>();
    const lines = body.lines.map((raw) => {
      const line = object(raw);
      keys(line, ["invoiceLineId", "unitPrice", "discountAmount"]);
      const invoiceLineId = uuid(line.invoiceLineId);
      if (seen.has(invoiceLineId)) fail("INVOICE_CORRECTION_DUPLICATE_LINE");
      seen.add(invoiceLineId);
      return { invoiceLineId, unitPrice: money(line.unitPrice), discountAmount: money(line.discountAmount) };
    }).sort((a, b) => a.invoiceLineId.localeCompare(b.invoiceLineId));
    return { ...base, kind: body.kind, customerId: uuid(body.customerId), invoiceDate, dueDate, lines };
  }
  if (body.kind === "PAYMENT_CORRECTION") {
    keys(body, [...commonKeys, "receiptId", "receiptVersion", "correction"]);
    const data = object(body.correction);
    let correction: PaymentCorrectionCommand["correction"];
    if (data.reason === "PAYMENT_NOT_RECEIVED") {
      keys(data, ["reason"]); correction = { reason: data.reason };
    } else if (data.reason === "WRONG_PAYMENT_DATE") {
      keys(data, ["reason", "paymentDate"]);
      correction = { reason: data.reason, paymentDate: correctionDate(data.paymentDate) };
    } else fail("INVOICE_PAYMENT_CORRECTION_REASON_INVALID");
    return { ...base, kind: body.kind, receiptId: uuid(body.receiptId),
      receiptVersion: version(body.receiptVersion, 1), correction };
  }
  if (body.kind === "REFUND") {
    keys(body, [...commonKeys, "creditId", "creditVersion", "refundDate", "amount", "paymentMethodId", "referenceNo"]);
    return { ...base, kind: body.kind, creditId: uuid(body.creditId),
      creditVersion: version(body.creditVersion, 1), refundDate: correctionDate(body.refundDate),
      amount: money(body.amount, true), paymentMethodId: uuid(body.paymentMethodId),
      referenceNo: nullableText(body.referenceNo, 500) };
  }
  return fail("INVOICE_CORRECTION_KIND_INVALID");
}

/** Canonical comparison input, NOT an authorization token or a database lock. */
export function invoiceCorrectionPayloadIdentity(input: unknown): string {
  const parsed = parseInvoiceCorrectionCommand(input);
  const { operationId, ...payload } = parsed;
  void operationId;
  return JSON.stringify(payload);
}

export function resolveCorrectionDueDate(input: {
  previousInvoiceDate: string;
  previousDueDate: string;
  invoiceDate: string;
  dueDate: InvoiceRevisionCommand["dueDate"];
  adminOverrideAuthorized: boolean;
}): string {
  const before = correctionDate(input.previousInvoiceDate);
  const previousDue = correctionDate(input.previousDueDate);
  const after = correctionDate(input.invoiceDate);
  if (previousDue < before) fail("INVOICE_CORRECTION_SOURCE_TERM_INVALID");
  if (input.dueDate.mode === "ADMIN_OVERRIDE") {
    if (!input.adminOverrideAuthorized) fail("INVOICE_CORRECTION_DUE_DATE_OVERRIDE_FORBIDDEN");
    const date = correctionDate(input.dueDate.date);
    if (date < after) fail("INVOICE_CORRECTION_DUE_DATE_BEFORE_INVOICE");
    return date;
  }
  if (input.dueDate.mode !== "KEEP_TERM") fail("INVOICE_CORRECTION_DUE_DATE_MODE_INVALID");
  // UTC arithmetic avoids local DST/timezone changing the agreed day interval.
  const shifted = new Date(Date.parse(`${after}T00:00:00Z`) +
    Date.parse(`${previousDue}T00:00:00Z`) - Date.parse(`${before}T00:00:00Z`));
  return correctionDate(shifted.toISOString().slice(0, 10));
}
