import {
  apiError,
  requireActiveCompany,
  requireCaller,
} from "@/lib/server-auth";
import { throwDatabaseError } from "@/lib/master-data";

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request);
    await requireActiveCompany(caller);
    const result = await caller.client.rpc("get_purchase_returns");
    if (result.error) throwDatabaseError(result.error);
    return Response.json(result.data);
  } catch (error) {
    return apiError(error);
  }
}
