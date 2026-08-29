import {
  ApiRouteError,
  apiError,
  requireActiveCompany,
  requireCaller,
  requirePermissionCapability,
} from "@/lib/server-auth";
import {
  enumValue,
  optionalText,
  readJsonObject,
  requiredVersion,
  throwDatabaseError,
  uuidValue,
} from "@/lib/master-data";

const actions = ["VERIFY", "REJECT"] as const;

function paymentVerificationError(error: {
  code?: string;
  message?: string;
} | null): never {
  const message = error?.message ?? "PAYMENT_VERIFICATION_OPERATION_FAILED";
  const known = [
    "PAYMENT_VERIFICATION_NOT_FOUND",
    "PAYMENT_VERIFICATION_FINAL",
    "MASTER_VERSION_CONFLICT",
    "MAKER_CHECKER_REQUIRED",
    "CASH_PAYMENT_REJECTION_REQUIRES_OPEN_SESSION",
    "PAYMENT_TRANSACTION_CATEGORY_MISSING_OR_AMBIGUOUS",
    "ACTIVE_COMPANY_CONTEXT_MISMATCH",
    "CUSTOM_PERMISSION_DENIED",
  ].find((code) => message.includes(code));

  if (known) {
    const status = ["CUSTOM_PERMISSION_DENIED", "MAKER_CHECKER_REQUIRED"].includes(
      known,
    )
      ? 403
      : ["PAYMENT_VERIFICATION_FINAL", "MASTER_VERSION_CONFLICT"].includes(
            known,
          )
        ? 409
        : known === "PAYMENT_VERIFICATION_NOT_FOUND"
          ? 404
          : 400;
    throw new ApiRouteError(known, status);
  }
  throwDatabaseError(error);
}

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request);
    const companyId = await requireActiveCompany(caller);
    await requirePermissionCapability(
      caller,
      companyId,
      "finance.sales_payment_verification",
      "VIEW",
    );
    const { data, error } = await caller.client.rpc(
      "get_finance_sales_payment_verifications",
    );
    if (error) paymentVerificationError(error);
    return Response.json({
      paymentVerificationWorkspaceVersion: 1,
      ...(data as Record<string, unknown>),
    });
  } catch (error) {
    return apiError(error);
  }
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request);
    const companyId = await requireActiveCompany(caller);
    const body = await readJsonObject(request);
    const action = enumValue(body.action, actions, "REVIEW_ACTION_INVALID");
    await requirePermissionCapability(
      caller,
      companyId,
      "finance.sales_payment_verification",
      action === "VERIFY" ? "APPROVE" : "REVIEW",
    );
    const note = optionalText(body, "note", { maxLength: 500 }) ?? null;
    const { data, error } = await caller.client.rpc(
      "review_sales_payment_verification",
      {
        p_request_id: uuidValue(
          String(body.requestId ?? ""),
          "PAYMENT_VERIFICATION_ID_INVALID",
        ),
        p_master_version: requiredVersion(body),
        p_action: action,
        p_note: note,
        p_idempotency_key: uuidValue(
          String(body.idempotencyKey ?? ""),
          "IDEMPOTENCY_KEY_INVALID",
        ),
      },
    );
    if (error) paymentVerificationError(error);
    return Response.json({ data });
  } catch (error) {
    return apiError(error);
  }
}
