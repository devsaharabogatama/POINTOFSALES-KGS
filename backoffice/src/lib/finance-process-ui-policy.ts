import "server-only";

import { createAdminClient } from "@/lib/server-auth";

export type SalesProcessMode =
  | "RETAIL_CONFIRM_INVOICE"
  | "BACKOFFICE_DELIVERED_QTY_INVOICE";

export type FinanceProcessUiPolicy = {
  activeMode: SalesProcessMode | null;
  showRetailPaymentVerification: boolean;
  showRetailCashDeposits: boolean;
  showRetailDepositVariances: boolean;
  pendingRetailPaymentVerifications: number;
  openRetailCashDeposits: number;
  openRetailDepositVariances: number;
  policySource: "CANONICAL" | "CONSERVATIVE_FALLBACK";
};

const conservativePolicy: FinanceProcessUiPolicy = {
  activeMode: null,
  showRetailPaymentVerification: true,
  showRetailCashDeposits: true,
  showRetailDepositVariances: true,
  pendingRetailPaymentVerifications: 0,
  openRetailCashDeposits: 0,
  openRetailDepositVariances: 0,
  policySource: "CONSERVATIVE_FALLBACK",
};

export async function getFinanceProcessUiPolicy(
  companyId: string,
): Promise<FinanceProcessUiPolicy> {
  try {
    const admin = createAdminClient();
    const [setting, paymentVerifications, cashDeposits, depositVariances] =
      await Promise.all([
        admin
          .from("company_sales_process_settings")
          .select("active_mode")
          .eq("company_id", companyId)
          .maybeSingle(),
        admin
          .from("sales_payment_verification_requests")
          .select("id", { count: "exact", head: true })
          .eq("company_id", companyId)
          .eq("status", "PENDING")
          .neq("settlement_route_snapshot", "CASH_DRAWER"),
        admin
          .from("cash_deposit_documents")
          .select("id", { count: "exact", head: true })
          .eq("company_id", companyId)
          .in("status", ["DRAFT", "SUBMITTED"]),
        admin
          .from("deposit_variance_exceptions")
          .select("id", { count: "exact", head: true })
          .eq("company_id", companyId)
          .in("status", ["OPEN", "PARTIALLY_RESOLVED"]),
      ]);

    if (
      setting.error ||
      paymentVerifications.error ||
      cashDeposits.error ||
      depositVariances.error
    ) {
      return conservativePolicy;
    }

    const activeMode = (setting.data?.active_mode ?? null) as
      | SalesProcessMode
      | null;
    if (
      activeMode !== null &&
      activeMode !== "RETAIL_CONFIRM_INVOICE" &&
      activeMode !== "BACKOFFICE_DELIVERED_QTY_INVOICE"
    ) {
      return conservativePolicy;
    }

    const pendingRetailPaymentVerifications = paymentVerifications.count ?? 0;
    const openRetailCashDeposits = cashDeposits.count ?? 0;
    const openRetailDepositVariances = depositVariances.count ?? 0;
    const isOffice = activeMode === "BACKOFFICE_DELIVERED_QTY_INVOICE";

    return {
      activeMode,
      showRetailPaymentVerification:
        !isOffice || pendingRetailPaymentVerifications > 0,
      showRetailCashDeposits: !isOffice || openRetailCashDeposits > 0,
      showRetailDepositVariances:
        !isOffice || openRetailDepositVariances > 0,
      pendingRetailPaymentVerifications,
      openRetailCashDeposits,
      openRetailDepositVariances,
      policySource: "CANONICAL",
    };
  } catch {
    // Navigation must remain usable if the additive process-mode schema or
    // server-only credential is unavailable. Showing legacy controls is the
    // safe fallback because it cannot strand unresolved Retail work.
    return conservativePolicy;
  }
}
