import { apiError, requireActiveCompany, requireCaller } from "@/lib/server-auth";
import { readJsonObject, uuidValue } from "@/lib/master-data";
import { parseDailyRoStockMatchBody, throwSupplierOrderError } from "@/lib/supplier-order";

export async function GET(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
) {
  try {
    const caller = await requireCaller(request);
    await requireActiveCompany(caller);
    const { id } = await params;
    const { data, error } = await caller.client.rpc(
      "get_purchase_daily_auto_ro_stock_match",
      { p_batch_id: uuidValue(id, "PURCHASE_DAILY_BATCH_ID_INVALID") },
    );
    if (error) throwSupplierOrderError(error);
    return Response.json({ data });
  } catch (error) {
    return apiError(error);
  }
}

export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
) {
  try {
    const caller = await requireCaller(request);
    await requireActiveCompany(caller);
    const { id } = await params;
    const input = parseDailyRoStockMatchBody(await readJsonObject(request));
    const { data, error } = await caller.client.rpc(
      "reconcile_purchase_daily_auto_ro_stock",
      {
        p_batch_id: uuidValue(id, "PURCHASE_DAILY_BATCH_ID_INVALID"),
        p_master_version: input.masterVersion,
        p_operation_id: input.idempotencyKey,
      },
    );
    if (error) throwSupplierOrderError(error);
    return Response.json({ data });
  } catch (error) {
    return apiError(error);
  }
}
