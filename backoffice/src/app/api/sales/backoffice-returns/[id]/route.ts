import { apiError, requireActiveCompany, requireCaller } from "@/lib/server-auth";
import { readJsonObject, uuidValue } from "@/lib/master-data";
import { parseReturnDraft, returnExpectedVersion, returnOperationId, throwBackofficeReturnError } from "@/lib/backoffice-sales-return";

type Context = { params: Promise<{ id: string }> };
export async function GET(request: Request, { params }: Context) {
  try {
    const caller = await requireCaller(request); const companyId = await requireActiveCompany(caller);
    const { id } = await params; const returnId = uuidValue(id, "BACKOFFICE_SALES_RETURN_ID_INVALID");
    const detail = await caller.client.rpc("get_backoffice_sales_return", { p_return_id: returnId });
    if (detail.error) throwBackofficeReturnError(detail.error);
    const permissionKeys = ["sales.backoffice_returns", "inventory.customer_return_receipts", "finance.customer_credit_notes", "finance.customer_refunds"];
    const permissionResults = await Promise.all(permissionKeys.map((key) => caller.client.rpc("resolve_user_permission", {
      p_company_id: companyId, p_target_user_id: caller.user.id, p_permission_key: key,
    })));
    const capabilities = Object.fromEntries(permissionKeys.map((key, index) => [key, permissionResults[index].error ? [] : permissionResults[index].data?.effectiveCapabilities ?? []]));
    const activityResult = await caller.client.rpc("get_backoffice_sales_return_activity", { p_return_id: returnId });
    if (activityResult.error) throwBackofficeReturnError(activityResult.error);
    let reconciliation = null; let invoices = null;
    if ((capabilities["finance.customer_credit_notes"] as string[]).includes("VIEW")) {
      const [reconciliationResult, invoiceResult] = await Promise.all([
        caller.client.rpc("get_backoffice_sales_return_invoice_reconciliation", { p_return_id: returnId }),
        caller.client.rpc("get_backoffice_sales_invoice_workspace", { p_sales_order_id: detail.data?.data?.salesOrderId, p_status: null, p_search: null, p_limit: 100 }),
      ]);
      if (reconciliationResult.error) throwBackofficeReturnError(reconciliationResult.error);
      if (invoiceResult.error) throwBackofficeReturnError(invoiceResult.error);
      reconciliation = reconciliationResult.data; invoices = invoiceResult.data;
    }
    return Response.json({ ...detail.data, capabilities, reconciliation, invoices, activity: activityResult.data?.data ?? [] });
  } catch (error) { return apiError(error); }
}

export async function PUT(request: Request, { params }: Context) {
  try {
    const caller = await requireCaller(request); await requireActiveCompany(caller);
    const { id } = await params; const body = await readJsonObject(request);
    const result = await caller.client.rpc("save_backoffice_sales_return_draft", {
      p_return_id: uuidValue(id, "BACKOFFICE_SALES_RETURN_ID_INVALID"),
      p_expected_version: returnExpectedVersion(body), p_operation_id: returnOperationId(body),
      p_sales_order_id: uuidValue(String(body.salesOrderId ?? ""), "BACKOFFICE_SALES_ORDER_ID_INVALID"),
      p_payload: parseReturnDraft(body),
    });
    if (result.error) throwBackofficeReturnError(result.error);
    return Response.json(result.data);
  } catch (error) { return apiError(error); }
}
