import {
  apiError,
  requireActiveCompany,
  requireCaller,
} from "@/lib/server-auth";
import { readJsonObject, uuidValue } from "@/lib/master-data";
import {
  parseBackofficePurchaseReturnDraft,
  throwPurchaseReturnRpcError,
} from "@/lib/purchase-return";

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request);
    await requireActiveCompany(caller);
    const orderId = new URL(request.url).searchParams.get("supplierOrderId");
    const [documents, workspace, finance] = await Promise.all([
      caller.client.rpc("get_purchase_returns"),
      caller.client.rpc("get_backoffice_purchase_return_workspace", {
        p_supplier_order_id: orderId ? uuidValue(orderId) : null,
      }),
      caller.client.rpc("get_backoffice_purchase_return_finance"),
    ]);
    if (documents.error) throwPurchaseReturnRpcError(documents.error);
    if (workspace.error) throwPurchaseReturnRpcError(workspace.error);
    if (finance.error) throwPurchaseReturnRpcError(finance.error);
    return Response.json({
      ...((documents.data ?? {}) as Record<string, unknown>),
      workspace: workspace.data ?? {},
      finance: finance.data ?? {},
    });
  } catch (error) {
    return apiError(error);
  }
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request);
    await requireActiveCompany(caller);
    const input = parseBackofficePurchaseReturnDraft(
      await readJsonObject(request),
    );
    const { data, error } = await caller.client.rpc(
      "save_backoffice_purchase_return_draft",
      {
        p_document_id: input.documentId,
        p_master_version: input.masterVersion,
        p_operation_id: input.operationId,
        p_source_receipt_id: input.sourceReceiptId,
        p_source_warehouse_id: input.sourceWarehouseId,
        p_return_date: input.returnDate,
        p_return_reason: input.returnReason,
        p_supplier_document_no: input.supplierDocumentNo,
        p_notes: input.notes,
        p_lines: input.lines,
      },
    );
    if (error) throwPurchaseReturnRpcError(error);
    return Response.json({ data });
  } catch (error) {
    return apiError(error);
  }
}
