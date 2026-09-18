import { apiError, requireActiveCompany, requireCaller } from "@/lib/server-auth";
import { readJsonObject, uuidValue } from "@/lib/master-data";
import { invoiceOperationId, parseBackofficeInvoicePayload, throwBackofficeInvoiceError } from "@/lib/backoffice-sales-invoice";

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request);
    const companyId = await requireActiveCompany(caller);
    const url = new URL(request.url);
    const salesOrderId = url.searchParams.get("salesOrderId");
    const { data, error } = await caller.client.rpc("get_backoffice_sales_invoice_workspace", {
      p_sales_order_id: salesOrderId ? uuidValue(salesOrderId, "BACKOFFICE_SALES_ORDER_ID_INVALID") : null,
      p_status: url.searchParams.get("status") || null,
      p_search: url.searchParams.get("search") || null,
      p_limit: 100,
    });
    if (error) throwBackofficeInvoiceError(error);
    const commercialRpc = await caller.client.rpc("get_sales_invoice_commercial_statuses");
    const commercialMissing = commercialRpc.error?.code === "PGRST202"
      || Boolean(commercialRpc.error?.message?.includes("get_sales_invoice_commercial_statuses"));
    if (commercialRpc.error && !commercialMissing) throwBackofficeInvoiceError(commercialRpc.error);
    const commercialPayload = commercialRpc.data as { data?: Array<Record<string, unknown>> } | null;
    const commercial = new Map((commercialPayload?.data ?? [])
      .filter((row) => row.sourceKind === "BACKOFFICE" && typeof row.sourceId === "string")
      .map((row) => [row.sourceId as string, row]));
    const workspace = data as { invoices?: Array<Record<string, unknown>> } | null;
    const enriched = workspace ? { ...workspace, invoices: (workspace.invoices ?? []).map((invoice) => ({
      ...invoice, ...(typeof invoice.id === "string" ? commercial.get(invoice.id) ?? {} : {}),
    })) } : data;
    const { data: permission } = await caller.client.rpc("resolve_user_permission", {
      p_company_id: companyId, p_target_user_id: caller.user.id,
      p_permission_key: "finance.journals_reports",
    });
    const capabilities = Array.isArray(permission?.effectiveCapabilities) ? permission.effectiveCapabilities : [];
    return Response.json({ ...enriched, permissions: { canPost: capabilities.includes("POST") } });
  } catch (error) { return apiError(error); }
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request);
    await requireActiveCompany(caller);
    const body = await readJsonObject(request);
    const salesOrderId = typeof body.salesOrderId === "string"
      ? uuidValue(body.salesOrderId, "BACKOFFICE_SALES_ORDER_ID_INVALID")
      : (() => { throw new Error("BACKOFFICE_SALES_ORDER_ID_REQUIRED"); })();
    const { data, error } = await caller.client.rpc("save_backoffice_sales_invoice_draft", {
      p_invoice_id: null, p_expected_version: null,
      p_operation_id: invoiceOperationId(body), p_sales_order_id: salesOrderId,
      p_payload: parseBackofficeInvoicePayload(body),
    });
    if (error) throwBackofficeInvoiceError(error);
    return Response.json(data, { status: 201 });
  } catch (error) { return apiError(error); }
}
