import { ApiRouteError, apiError, requireActiveCompany, requireCaller } from "@/lib/server-auth";
import { readJsonObject, uuidValue } from "@/lib/master-data";
import { invoiceExpectedVersion, invoiceOperationId, throwBackofficeInvoiceError } from "@/lib/backoffice-sales-invoice";

type Context = { params: Promise<{ id: string }> };

export async function POST(request: Request, { params }: Context) {
  try {
    const caller = await requireCaller(request); await requireActiveCompany(caller);
    const { id } = await params; const body = await readJsonObject(request);
    const action = typeof body.action === "string" ? body.action.toUpperCase() : "";
    const invoiceId = uuidValue(id, "BACKOFFICE_SALES_INVOICE_ID_INVALID");
    let result;
    if (action === "POST") {
      result = await caller.client.rpc("post_backoffice_sales_invoice", {
        p_invoice_id: invoiceId, p_expected_version: invoiceExpectedVersion(body),
        p_operation_id: invoiceOperationId(body),
      });
    } else if (action === "CANCEL") {
      if (typeof body.reason !== "string" || !body.reason.trim()) throw new ApiRouteError("CANCEL_REASON_REQUIRED", 400);
      result = await caller.client.rpc("cancel_backoffice_sales_invoice_draft", {
        p_invoice_id: invoiceId, p_expected_version: invoiceExpectedVersion(body),
        p_operation_id: invoiceOperationId(body), p_reason: body.reason.trim().slice(0, 1000),
      });
    } else throw new ApiRouteError("BACKOFFICE_SALES_INVOICE_ACTION_INVALID", 400);
    if (result.error) throwBackofficeInvoiceError(result.error);
    return Response.json(result.data);
  } catch (error) { return apiError(error); }
}
