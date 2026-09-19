import { apiError, requireActiveCompany, requireCaller } from "@/lib/server-auth";
import { throwDatabaseError, uuidValue } from "@/lib/master-data";

export async function GET(
  request: Request,
  context: { params: Promise<{ id: string }> },
) {
  try {
    const caller = await requireCaller(request);
    await requireActiveCompany(caller);
    const { id } = await context.params;
    const { data, error } = await caller.client.rpc(
      "get_purchase_supplier_order_return_readiness",
      { p_order_id: uuidValue(id, "SUPPLIER_ORDER_ID_INVALID") },
    );
    if (error) throwDatabaseError(error);
    return Response.json({ data });
  } catch (error) {
    return apiError(error);
  }
}
