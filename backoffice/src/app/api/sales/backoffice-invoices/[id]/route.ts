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
    return Response.json({ ...data, paymentContext });
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
