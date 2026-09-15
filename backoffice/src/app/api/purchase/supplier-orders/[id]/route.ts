import { apiError, requireActiveCompany, requireCaller } from "@/lib/server-auth";
import { readJsonObject, throwDatabaseError, uuidValue } from "@/lib/master-data";
import {
  parseSupplierOrderRevisionBody,
  throwSupplierOrderError,
} from "@/lib/supplier-order";

export async function PATCH(
  request: Request,
  context: { params: Promise<{ id: string }> },
) {
  try {
    const caller = await requireCaller(request);
    await requireActiveCompany(caller);
    const { id } = await context.params;
    const documentId = uuidValue(id, "SUPPLIER_ORDER_ID_INVALID");
    const input = parseSupplierOrderRevisionBody(await readJsonObject(request));
    const { data, error } = await caller.client.rpc(
      "revise_purchase_supplier_order",
      {
        p_document_id: documentId,
        p_master_version: input.masterVersion,
        p_operation_id: input.operationId,
        p_supplier_id: input.supplierId,
        p_expected_date: input.expectedDate,
        p_notes: input.notes,
        p_lines: input.lines,
      },
    );
    if (error) throwSupplierOrderError(error);
    if (!data)
      throwDatabaseError({ message: "SUPPLIER_ORDER_REVISION_RESULT_INVALID" });
    return Response.json({ data });
  } catch (error) {
    return apiError(error);
  }
}
