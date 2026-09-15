import { apiError, requireActiveCompany, requireCaller } from "@/lib/server-auth";
import { readJsonObject, uuidValue } from "@/lib/master-data";
import {
  parsePurchaseCancellationBody,
  throwSupplierOrderError,
} from "@/lib/supplier-order";

export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
) {
  try {
    const caller = await requireCaller(request);
    await requireActiveCompany(caller);
    const { id } = await params;
    const input = parsePurchaseCancellationBody(await readJsonObject(request));
    const { data, error } = await caller.client.rpc(
      "cancel_purchase_daily_auto_ro",
      {
        p_batch_id: uuidValue(id, "PURCHASE_DAILY_BATCH_ID_INVALID"),
        p_master_version: input.masterVersion,
        p_operation_id: input.idempotencyKey,
        p_reason: input.reason,
      },
    );
    if (error) throwSupplierOrderError(error);
    return Response.json({ data });
  } catch (error) {
    return apiError(error);
  }
}
