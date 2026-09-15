import { apiError, requireActiveCompany, requireCaller } from "@/lib/server-auth";
import { parseBackofficeSalesOrderPayload, throwBackofficeSalesOrderError } from "@/lib/backoffice-sales-order";

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request);
    await requireActiveCompany(caller);
    const payload = parseBackofficeSalesOrderPayload(await request.json());
    const { data, error } = await caller.client.rpc("preview_backoffice_sales_order_lines", {
      p_store_id: payload.storeId,
      p_customer_id: payload.customerId,
      p_pricelist_id: payload.selectedPricelistId,
      p_order_date: payload.orderDate,
      p_lines: payload.lines.map((line) => ({
        productUomId: line.productUomId,
        quantity: line.quantity,
      })),
    });
    if (error) throwBackofficeSalesOrderError(error);
    return Response.json(data);
  } catch (error) {
    return apiError(error);
  }
}
