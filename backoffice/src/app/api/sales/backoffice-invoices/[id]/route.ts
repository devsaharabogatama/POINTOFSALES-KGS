import { apiError, requireActiveCompany, requireCaller } from "@/lib/server-auth";
import { readJsonObject, uuidValue } from "@/lib/master-data";
import { invoiceExpectedVersion, invoiceOperationId, parseBackofficeInvoicePayload, throwBackofficeInvoiceError } from "@/lib/backoffice-sales-invoice";

type Context = { params: Promise<{ id: string }> };

export async function GET(request: Request, { params }: Context) {
  try {
    const caller = await requireCaller(request); const companyId = await requireActiveCompany(caller);
    const { id } = await params;
    const invoiceId = uuidValue(id, "BACKOFFICE_SALES_INVOICE_ID_INVALID");
    const { data, error } = await caller.client.rpc("get_backoffice_sales_invoice_ui", {
      p_invoice_id: invoiceId,
    });
    if (error) throwBackofficeInvoiceError(error);
    const returnLinks = await caller.client.rpc("get_backoffice_sales_return_links", {
      p_sales_order_id: data?.data?.salesOrderId,
    });
    if (returnLinks.error) throwBackofficeInvoiceError(returnLinks.error);
    const commercialRpc = await caller.client.rpc("get_sales_invoice_commercial_statuses");
    const commercialMissing = commercialRpc.error?.code === "PGRST202"
      || Boolean(commercialRpc.error?.message?.includes("get_sales_invoice_commercial_statuses"));
    if (commercialRpc.error && !commercialMissing) throwBackofficeInvoiceError(commercialRpc.error);
    const commercialPayload = commercialRpc.data as { data?: Array<Record<string, unknown>> } | null;
    const commercial = (commercialPayload?.data ?? []).find((row) =>
      row.sourceKind === "BACKOFFICE" && row.sourceId === invoiceId) ?? {};
    const { data: permission, error: permissionError } = await caller.client.rpc("resolve_user_permission", {
      p_company_id: companyId, p_target_user_id: caller.user.id,
      p_permission_key: "finance.customer_receipts",
    });
    if (permissionError) throwBackofficeInvoiceError(permissionError);
    const capabilities = Array.isArray(permission?.effectiveCapabilities) ? permission.effectiveCapabilities : [];
    let paymentContext = null;
    if (capabilities.includes("VIEW")) {
      const payment = await caller.client.rpc("get_backoffice_sales_invoice_payment_context", {
        p_invoice_id: invoiceId,
      });
      if (payment.error) throwBackofficeInvoiceError(payment.error);
      paymentContext = payment.data;
    }
    return Response.json({ ...data, data: { ...(data?.data ?? {}), ...commercial }, paymentContext,
      returnLinks: returnLinks.data?.data ?? [] });
  } catch (error) { return apiError(error); }
}

export async function PUT(request: Request, { params }: Context) {
  try {
    const caller = await requireCaller(request); await requireActiveCompany(caller);
    const { id } = await params; const body = await readJsonObject(request);
    const { data, error } = await caller.client.rpc("save_backoffice_sales_invoice_draft", {
      p_invoice_id: uuidValue(id, "BACKOFFICE_SALES_INVOICE_ID_INVALID"),
      p_expected_version: invoiceExpectedVersion(body), p_operation_id: invoiceOperationId(body),
      p_sales_order_id: uuidValue(String(body.salesOrderId), "BACKOFFICE_SALES_ORDER_ID_INVALID"),
      p_payload: parseBackofficeInvoicePayload(body),
    });
    if (error) throwBackofficeInvoiceError(error);
    return Response.json(data);
  } catch (error) { return apiError(error); }
}
