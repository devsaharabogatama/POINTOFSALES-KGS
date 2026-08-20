"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import {
  ArrowLeft,
  ArrowRightLeft,
  BadgePercent,
  Banknote,
  BanknoteArrowUp,
  BellRing,
  Boxes,
  Building2,
  ChevronDown,
  ChevronRight,
  CircleAlert,
  ClipboardCheck,
  ClipboardPenLine,
  ContactRound,
  CreditCard,
  DollarSign,
  FileSpreadsheet,
  House,
  ImageIcon,
  Landmark,
  LayoutDashboard,
  Loader2,
  LogOut,
  Menu,
  PackageSearch,
  PackagePlus,
  PackageMinus,
  ScrollText,
  ShoppingCart,
  RotateCcw,
  Search,
  Receipt,
  ShieldCheck,
  Settings2,
  Store,
  Tags,
  Truck,
  UserPlus,
  Users,
  WalletCards,
  X,
} from "lucide-react";
import { supabase } from "@/lib/supabase";
import { MasterDataView } from "@/components/MasterDataView";
import { CanonicalProductsView } from "@/components/CanonicalProductsView";
import { SupplierMasterView } from "@/components/SupplierMasterView";
import { CustomerMasterView } from "@/components/CustomerMasterView";
import { PricelistMasterView } from "@/components/PricelistMasterView";
import { PaymentMethodMasterView } from "@/components/PaymentMethodMasterView";
import { FinanceMasterView } from "@/components/FinanceMasterView";
import { TaxMasterView } from "@/components/TaxMasterView";
import { ModuleSettingsView } from "@/components/ModuleSettingsView";
import { CompanyBrandingView } from "@/components/CompanyBrandingView";
import { StaffAccessDetailModal } from "@/components/StaffAccessDetailModal";
import { DataExchangeView } from "@/components/DataExchangeView";
import { MinimumStockView } from "@/components/MinimumStockView";
import { OpeningStockView } from "@/components/OpeningStockView";
import { StockRealView } from "@/components/StockRealView";
import { StockMovementView } from "@/components/StockMovementView";
import { StockTransferView } from "@/components/StockTransferView";
import { StockAdjustmentView } from "@/components/StockAdjustmentView";
import { StockOpnameView } from "@/components/StockOpnameView";
import { BundleMasterView } from "@/components/BundleMasterView";
import { SalesReturnApprovalView } from "@/components/SalesReturnApprovalView";
import { SalesDocumentView } from "@/components/SalesDocumentView";
import { DeliveryDocumentView } from "@/components/DeliveryDocumentView";
import { ExpenseApprovalView } from "@/components/ExpenseApprovalView";
import { CashDepositApprovalView } from "@/components/CashDepositApprovalView";
import { DepositVarianceResolutionView } from "@/components/DepositVarianceResolutionView";
import { CustomerBalanceView } from "@/components/CustomerBalanceView";
import { SupplierOrderView } from "@/components/SupplierOrderView";
import { PurchaseReturnApprovalView } from "@/components/PurchaseReturnApprovalView";
import { SupplierInvoiceMatchingView } from "@/components/SupplierInvoiceMatchingView";
import SupplierPaymentView from "@/components/SupplierPaymentView";
import { FinanceOperationsView } from "@/components/FinanceOperationsView";
import { useEscapeClose } from "@/lib/use-escape-close";
import {
  FINANCE_ROLES,
  OWNER_ROLES,
  type NavigationCatalogModule,
  type NavigationIconKey,
  type NavigationViewId,
} from "@/lib/navigation-catalog";

type View = "dashboard" | NavigationViewId;

type CompanyContext = {
  id: string;
  company_code: string;
  company_name: string;
  status: string;
  roleCode: string;
  isDefault: boolean;
};

type UserContext = {
  profile: { id: string; name: string; email: string; role: string };
  isSuperAdmin: boolean;
  activeCompanyId: string | null;
  companies: CompanyContext[];
};

type StaffMembershipRow = {
  user_id: string;
  role_code: string;
  status: string;
  profiles: { name: string; email: string } | null;
};

type Staff = {
  id: string;
  name: string;
  email: string;
  role: string;
  status: string;
};

type StoreOption = { id: string; store_code: string; store_name: string };

type NavigationItem = {
  id: View;
  label: string;
  icon: typeof LayoutDashboard;
  moduleName?: string;
};

const iconByKey: Record<NavigationIconKey, typeof Boxes> = {
  "arrow-right-left": ArrowRightLeft,
  "badge-percent": BadgePercent,
  banknote: Banknote,
  "banknote-arrow-up": BanknoteArrowUp,
  "bell-ring": BellRing,
  boxes: Boxes,
  building: Building2,
  "circle-alert": CircleAlert,
  "clipboard-check": ClipboardCheck,
  "clipboard-pen": ClipboardPenLine,
  contact: ContactRound,
  "credit-card": CreditCard,
  dollar: DollarSign,
  "file-spreadsheet": FileSpreadsheet,
  landmark: Landmark,
  image: ImageIcon,
  "package-minus": PackageMinus,
  "package-plus": PackagePlus,
  "package-search": PackageSearch,
  receipt: Receipt,
  rotate: RotateCcw,
  scroll: ScrollText,
  settings: Settings2,
  "shopping-cart": ShoppingCart,
  tags: Tags,
  truck: Truck,
  users: Users,
  wallet: WalletCards,
};

const roleLabels: Record<string, string> = {
  SUPER_ADMIN: "Platform Super Admin",
  COMPANY_OWNER: "Pemilik Perusahaan",
  COMPANY_ADMIN: "Admin Perusahaan",
  STORE_MANAGER: "Manajer Toko",
  WAREHOUSE_ADMIN: "Admin Gudang",
  FINANCE: "Finance",
  ACCOUNTING: "Accounting",
  CASHIER: "Kasir",
};

function authHeaders(session: Session) {
  return { Authorization: `Bearer ${session.access_token}` };
}

function messageFromError(error: unknown, fallback: string) {
  if (error instanceof Error) return error.message;
  if (
    typeof error === "object" &&
    error !== null &&
    "message" in error &&
    typeof error.message === "string"
  ) {
    return error.message;
  }
  return fallback;
}

export default function Home() {
  const [session, setSession] = useState<Session | null>(null);
  const [checkingSession, setCheckingSession] = useState(true);
  const [context, setContext] = useState<UserContext | null>(null);
  const [activeCompanyId, setActiveCompanyId] = useState("");
  const [switchingCompany, setSwitchingCompany] = useState(false);
  const [activeView, setActiveView] = useState<View>("dashboard");
  const [viewHistory, setViewHistory] = useState<View[]>([]);
  const [activeModuleId, setActiveModuleId] = useState<string | null>(null);
  const [navigationModules, setNavigationModules] = useState<
    NavigationCatalogModule[]
  >([]);
  const [navigationLoading, setNavigationLoading] = useState(false);
  const [companyLogoUrl, setCompanyLogoUrl] = useState<string | null>(null);
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [staff, setStaff] = useState<Staff[]>([]);
  const [stores, setStores] = useState<StoreOption[]>([]);
  const [notice, setNotice] = useState<string | null>(null);
  const [showStaff, setShowStaff] = useState(false);
  const [showExistingStaff, setShowExistingStaff] = useState(false);
  const [selectedStaff, setSelectedStaff] = useState<Staff | null>(null);
  const [showTenant, setShowTenant] = useState(false);

  useEffect(() => {
    void supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setCheckingSession(false);
    });
    const { data } = supabase.auth.onAuthStateChange((_event, nextSession) => {
      setSession(nextSession);
      if (!nextSession) {
        setContext(null);
        setActiveCompanyId("");
      }
      setCheckingSession(false);
    });
    return () => data.subscription.unsubscribe();
  }, []);

  const loadContext = useCallback(async (activeSession: Session) => {
    const response = await fetch("/api/me/context", {
      headers: authHeaders(activeSession),
    });
    const payload = (await response.json()) as UserContext & { error?: string };
    if (!response.ok)
      throw new Error(payload.error ?? "Gagal memuat konteks akun");

    const storageKey = `kgs-active-company:${activeSession.user.id}`;
    const savedCompany = localStorage.getItem(storageKey);
    const selected =
      payload.companies.find(
        (company) => company.id === payload.activeCompanyId,
      ) ??
      payload.companies.find((company) => company.id === savedCompany) ??
      payload.companies.find((company) => company.isDefault) ??
      payload.companies[0];
    const selectedId = selected?.id ?? "";
    if (selectedId && selectedId !== payload.activeCompanyId) {
      const selectResponse = await fetch("/api/me/active-company", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          ...authHeaders(activeSession),
        },
        body: JSON.stringify({
          companyId: selectedId,
          source: "BACKOFFICE_INIT",
        }),
      });
      const selectPayload = (await selectResponse.json()) as { error?: string };
      if (!selectResponse.ok) {
        throw new Error(
          selectPayload.error ?? "Gagal menyimpan konteks perusahaan",
        );
      }
    }

    if (selectedId) localStorage.setItem(storageKey, selectedId);
    setContext({ ...payload, activeCompanyId: selectedId || null });
    setActiveCompanyId(selectedId);
  }, []);

  useEffect(() => {
    if (!session) return;
    // eslint-disable-next-line react-hooks/set-state-in-effect -- account context follows the authenticated session
    void loadContext(session).catch(async (error: unknown) => {
      const code = error instanceof Error ? error.message : "";
      if (code === "INVALID_SESSION") {
        await supabase.auth.signOut({ scope: "local" });
        setSession(null);
        setContext(null);
        setActiveCompanyId("");
        setNotice("Sesi login sudah kedaluwarsa. Silakan masuk kembali.");
        return;
      }
      setNotice(messageFromError(error, "Gagal memuat akun"));
    });
  }, [session, loadContext]);

  const loadTenantData = useCallback(async () => {
    if (!session || !activeCompanyId) return;
    setNotice(null);
    try {
      const [
        { data: membershipRows, error: staffError },
        { data: storeRows, error: storeError },
      ] = await Promise.all([
        supabase
          .from("company_memberships")
          .select("user_id, role_code, status, profiles(name, email)")
          .eq("company_id", activeCompanyId)
          .order("created_at"),
        supabase
          .from("stores")
          .select("id, store_code, store_name")
          .eq("company_id", activeCompanyId)
          .eq("status", "ACTIVE")
          .order("store_name"),
      ]);
      if (staffError) throw staffError;
      if (storeError) throw storeError;

      setStaff(
        ((membershipRows ?? []) as unknown as StaffMembershipRow[]).map(
          (membership) => ({
            id: membership.user_id,
            name: membership.profiles?.name ?? "Pengguna",
            email: membership.profiles?.email ?? "-",
            role: membership.role_code,
            status: membership.status,
          }),
        ),
      );
      setStores((storeRows ?? []) as StoreOption[]);
    } catch (error) {
      setNotice(messageFromError(error, "Gagal memuat data perusahaan"));
    }
  }, [activeCompanyId, session]);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- data loading is synchronized to active tenant context
    void loadTenantData();
  }, [loadTenantData]);

  useEffect(() => {
    if (!session || !activeCompanyId) return;
    let canceled = false;
    async function loadNavigationCatalog() {
      setNavigationLoading(true);
      try {
        const response = await fetch("/api/me/navigation-catalog", {
          headers: authHeaders(session as Session),
        });
        const payload = (await response.json()) as {
          modules?: NavigationCatalogModule[];
          error?: string;
        };
        if (!response.ok)
          throw new Error(payload.error ?? "Gagal memuat akses aplikasi");
        if (!canceled) {
          setNavigationModules(payload.modules ?? []);
          setActiveModuleId((current) =>
            current &&
            (payload.modules ?? []).some((module) => module.id === current)
              ? current
              : null,
          );
        }
      } catch (error) {
        if (!canceled) {
          setNavigationModules([]);
          setNotice(messageFromError(error, "Gagal memuat akses aplikasi"));
        }
      } finally {
        if (!canceled) setNavigationLoading(false);
      }
    }
    void loadNavigationCatalog();
    return () => {
      canceled = true;
    };
  }, [activeCompanyId, session]);

  useEffect(() => {
    if (!session || !activeCompanyId) return;
    let canceled = false;
    async function loadCompanyLogo() {
      try {
        const response = await fetch("/api/platform/company-branding", {
          headers: authHeaders(session as Session),
          cache: "no-store",
        });
        const payload = (await response.json()) as {
          companyId?: string;
          data?: { companyId?: string; logoPublicUrl?: string | null };
        };
        if (
          !response.ok ||
          payload.companyId !== activeCompanyId ||
          payload.data?.companyId !== activeCompanyId
        ) {
          if (!canceled) setCompanyLogoUrl(null);
          return;
        }
        if (!canceled) setCompanyLogoUrl(payload.data.logoPublicUrl ?? null);
      } catch {
        if (!canceled) setCompanyLogoUrl(null);
      }
    }
    void loadCompanyLogo();
    return () => {
      canceled = true;
    };
  }, [activeCompanyId, session]);

  const activeCompany = context?.companies.find(
    (company) => company.id === activeCompanyId,
  );
  const canManage =
    context?.isSuperAdmin ||
    ["COMPANY_OWNER", "COMPANY_ADMIN"].includes(activeCompany?.roleCode ?? "");
  const masterNavigation = navigationModules
    .flatMap((module) => module.items)
    .find((item) => item.id === "masters");
  const canManageMaster =
    masterNavigation?.capabilities.includes("MANAGE") ?? false;
  const productNavigation = navigationModules
    .flatMap((module) => module.items)
    .find((item) => item.id === "products");
  const canManageProducts =
    productNavigation?.capabilities.includes("MANAGE") ?? false;
  const stockTransferNavigation = navigationModules
    .flatMap((module) => module.items)
    .find((item) => item.id === "stock-transfers");
  const stockAdjustmentNavigation = navigationModules
    .flatMap((module) => module.items)
    .find((item) => item.id === "stock-adjustments");
  const stockOpnameNavigation = navigationModules
    .flatMap((module) => module.items)
    .find((item) => item.id === "stock-opnames");
  const openingStockNavigation = navigationModules
    .flatMap((module) => module.items)
    .find((item) => item.id === "opening-stock");
  const customerNavigation = navigationModules
    .flatMap((module) => module.items)
    .find((item) => item.id === "customers");
  const supplierNavigation = navigationModules
    .flatMap((module) => module.items)
    .find((item) => item.id === "suppliers");
  const canManageSupplier =
    supplierNavigation?.capabilities.includes("MANAGE") ?? false;
  const canManageProductSupplier = canManageSupplier;
  const supplierOrderNavigation = navigationModules
    .flatMap((module) => module.items)
    .find((item) => item.id === "supplier-orders");
  const canCreateSupplierOrder =
    supplierOrderNavigation?.capabilities.includes("CREATE_DRAFT") ?? false;
  const canPostSupplierOrder =
    supplierOrderNavigation?.capabilities.includes("POST") ?? false;
  const canExportSupplierOrder =
    supplierOrderNavigation?.capabilities.includes("EXPORT") ?? false;
  const purchaseReturnNavigation = navigationModules
    .flatMap((module) => module.items)
    .find((item) => item.id === "purchase-returns");
  const canReviewPurchaseReturn =
    purchaseReturnNavigation?.capabilities.includes("REVIEW") ?? false;
  const canPostPurchaseReturn =
    purchaseReturnNavigation?.capabilities.includes("POST") ?? false;
  const canCancelPurchaseReturn =
    purchaseReturnNavigation?.capabilities.includes("CANCEL_FINAL") ?? false;
  const deliveryDocumentNavigation = navigationModules
    .flatMap((module) => module.items)
    .find((item) => item.id === "delivery-documents");
  const pricelistNavigation = navigationModules
    .flatMap((module) => module.items)
    .find((item) => item.id === "pricelists");
  const bundleNavigation = navigationModules
    .flatMap((module) => module.items)
    .find((item) => item.id === "bundles");
  const salesReturnNavigation = navigationModules
    .flatMap((module) => module.items)
    .find((item) => item.id === "sales-returns");
  const expenseNavigation = navigationModules
    .flatMap((module) => module.items)
    .find((item) => item.id === "expense-approvals");
  const cashDepositNavigation = navigationModules
    .flatMap((module) => module.items)
    .find((item) => item.id === "cash-deposits");
  const depositVarianceNavigation = navigationModules
    .flatMap((module) => module.items)
    .find((item) => item.id === "deposit-variances");
  const customerBalanceNavigation = navigationModules
    .flatMap((module) => module.items)
    .find((item) => item.id === "customer-balances");
  const supplierInvoiceNavigation = navigationModules
    .flatMap((module) => module.items)
    .find((item) => item.id === "supplier-invoices");
  const supplierPaymentNavigation = navigationModules
    .flatMap((module) => module.items)
    .find((item) => item.id === "supplier-payments");
  const paymentMethodNavigation = navigationModules
    .flatMap((module) => module.items)
    .find((item) => item.id === "payment-methods");
  const canManageCustomerIdentity =
    customerNavigation?.capabilities.includes("MANAGE") ?? false;
  const canManageCustomerCredit =
    context?.isSuperAdmin ||
    ["COMPANY_OWNER", "COMPANY_ADMIN", "FINANCE", "ACCOUNTING"].includes(
      activeCompany?.roleCode ?? "",
    );
  const canManagePricelist =
    pricelistNavigation?.capabilities.includes("MANAGE") ?? false;
  const canApproveSalesReturn =
    salesReturnNavigation?.capabilities.includes("POST") ?? false;
  const canCancelSalesReturn =
    salesReturnNavigation?.capabilities.includes("CANCEL_FINAL") ?? false;
  const canManageSalesDelivery =
    deliveryDocumentNavigation?.capabilities.includes("MANAGE") ?? false;
  const canApproveExpense =
    expenseNavigation?.capabilities.includes("APPROVE") ?? false;
  const canApproveCashDeposit =
    cashDepositNavigation?.capabilities.includes("APPROVE") ?? false;
  const canManageDepositVariance =
    depositVarianceNavigation?.capabilities.includes("MANAGE") ?? false;
  const canReviewDepositVariance =
    (depositVarianceNavigation?.capabilities.includes("APPROVE") ?? false) &&
    (depositVarianceNavigation?.capabilities.includes("REVIEW") ?? false);
  const canRequestCustomerBalance =
    customerBalanceNavigation?.capabilities.includes("MANAGE") ?? false;
  const canReviewCustomerBalance =
    (customerBalanceNavigation?.capabilities.includes("APPROVE") ?? false) &&
    (customerBalanceNavigation?.capabilities.includes("REVIEW") ?? false);
  const canCancelExpenseAdministrative =
    expenseNavigation?.capabilities.includes("CANCEL_FINAL") ?? false;
  const canDisburseExpenseNonCash =
    expenseNavigation?.capabilities.includes("POST") ?? false;
  const canManagePaymentMethod =
    paymentMethodNavigation?.capabilities.includes("MANAGE") ?? false;
  const canManageFinanceMaster =
    context?.isSuperAdmin ||
    ["COMPANY_OWNER", "COMPANY_ADMIN", "FINANCE", "ACCOUNTING"].includes(
      activeCompany?.roleCode ?? "",
    );
  const financeRole = activeCompany?.roleCode ?? "";
  const canCreateFinancePeriod =
    context?.isSuperAdmin || FINANCE_ROLES.includes(financeRole);
  const canLockFinancePeriod =
    context?.isSuperAdmin ||
    ["COMPANY_OWNER", "COMPANY_ADMIN", "FINANCE"].includes(financeRole);
  const canReopenFinancePeriod =
    context?.isSuperAdmin || OWNER_ROLES.includes(financeRole);
  const canReverseFinanceJournal =
    context?.isSuperAdmin ||
    ["COMPANY_OWNER", "COMPANY_ADMIN", "FINANCE"].includes(financeRole);
  const canOperateFinanceQueue =
    context?.isSuperAdmin || FINANCE_ROLES.includes(financeRole);

  const navigateTo = useCallback(
    (nextView: View) => {
      if (nextView === activeView) return;
      if (
        nextView !== "dashboard" &&
        !navigationModules.some((module) =>
          module.items.some((item) => item.id === nextView),
        )
      ) {
        setNotice("Menu tidak tersedia untuk akses Company yang sedang aktif.");
        return;
      }
      setViewHistory((current) => [...current, activeView].slice(-20));
      setActiveView(nextView);
    },
    [activeView, navigationModules],
  );

  const goBack = useCallback(() => {
    const previousView = viewHistory.at(-1) ?? "dashboard";
    setViewHistory((current) => current.slice(0, -1));
    setActiveView(previousView);
  }, [viewHistory]);

  const goHome = useCallback(() => {
    setViewHistory([]);
    setActiveView("dashboard");
    setActiveModuleId(null);
  }, []);

  const openModule = useCallback((moduleId: string) => {
    setViewHistory([]);
    setActiveView("dashboard");
    setActiveModuleId(moduleId);
  }, []);

  async function changeCompany(companyId: string) {
    if (!session || companyId === activeCompanyId || switchingCompany) return;
    setSwitchingCompany(true);
    setNotice(null);
    try {
      const response = await fetch("/api/me/active-company", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          ...authHeaders(session),
        },
        body: JSON.stringify({ companyId, source: "BACKOFFICE_SELECTOR" }),
      });
      const payload = (await response.json()) as {
        activeCompanyId?: string;
        error?: string;
      };
      if (!response.ok || payload.activeCompanyId !== companyId) {
        throw new Error(payload.error ?? "Gagal mengganti perusahaan aktif");
      }

      localStorage.setItem(`kgs-active-company:${session.user.id}`, companyId);
      setCompanyLogoUrl(null);
      setContext((current) =>
        current ? { ...current, activeCompanyId: companyId } : current,
      );
      setActiveCompanyId(companyId);
      goHome();
    } catch (error) {
      setNotice(messageFromError(error, "Gagal mengganti perusahaan aktif"));
    } finally {
      setSwitchingCompany(false);
    }
  }

  async function logout() {
    // Keep POS and Backoffice sessions independent when the same operator uses
    // both apps. Global sign-out would revoke the other app's refresh token.
    await supabase.auth.signOut({ scope: "local" });
    setSession(null);
    setContext(null);
    setActiveCompanyId("");
    setCompanyLogoUrl(null);
  }

  if (checkingSession)
    return <FullScreenLoader label="Menyiapkan backoffice" />;
  if (!session) return <LoginScreen />;

  if (!context) {
    return <FullScreenLoader label="Memuat akses perusahaan" notice={notice} />;
  }

  if (!activeCompany) {
    return (
      <div className="min-h-screen bg-slate-50 grid place-items-center p-6">
        <div className="max-w-md rounded-3xl border border-slate-200 bg-white p-8 text-center shadow-sm">
          <CircleAlert className="mx-auto h-10 w-10 text-amber-500" />
          <h1 className="mt-4 text-xl font-bold text-slate-950">
            Belum ada akses perusahaan
          </h1>
          <p className="mt-2 text-sm leading-6 text-slate-500">
            Akun ini tidak memiliki akses ke perusahaan mana pun. Minta
            platform admin menambahkan kembali akses perusahaan.
          </p>
          <button
            onClick={logout}
            className="mt-6 rounded-xl bg-slate-950 px-5 py-2.5 text-sm font-semibold text-white"
          >
            Keluar
          </button>
        </div>
      </div>
    );
  }

  const availableNavigation: NavigationItem[] = [
    { id: "dashboard", label: "Aplikasi", icon: LayoutDashboard },
    ...navigationModules.flatMap((module) =>
      module.items.map((item) => ({
        id: item.id,
        label: item.label,
        icon: iconByKey[item.iconKey],
        moduleName: module.name,
      })),
    ),
  ];

  return (
    <div className="min-h-screen bg-[#f6f7f9] text-slate-900">
      <Sidebar
        view={activeView}
        navigate={(view) => {
          setActiveModuleId(null);
          navigateTo(view);
        }}
        goHome={goHome}
        items={availableNavigation}
        open={sidebarOpen}
        close={() => setSidebarOpen(false)}
      />

      <div>
        <header className="sticky top-0 z-30 flex h-20 items-center gap-4 border-b border-slate-200/80 bg-white/95 px-4 backdrop-blur md:px-8">
          <button
            onClick={() => setSidebarOpen((current) => !current)}
            className="rounded-xl border border-slate-200 p-2.5"
            aria-label={sidebarOpen ? "Tutup fast link" : "Buka fast link"}
            aria-expanded={sidebarOpen}
          >
            <Menu className="h-5 w-5" />
          </button>

          <button
            type="button"
            onClick={goHome}
            className="grid h-12 w-12 shrink-0 place-items-center overflow-hidden rounded-xl border border-slate-200 bg-slate-50 text-slate-500 shadow-sm transition hover:border-emerald-300 hover:ring-4 hover:ring-emerald-500/10 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-emerald-500"
            aria-label={`Kembali ke Beranda ${activeCompany.company_name}`}
            title="Kembali ke Beranda"
          >
            {companyLogoUrl ? (
              <span
                role="img"
                aria-label={`Logo ${activeCompany.company_name}`}
                className="h-full w-full bg-contain bg-center bg-no-repeat"
                style={{
                  backgroundImage: `url(${JSON.stringify(companyLogoUrl)})`,
                }}
              />
            ) : (
              <Building2 className="h-5 w-5" />
            )}
          </button>

          <div className="min-w-0 flex-1">
            <p className="text-xs font-semibold uppercase tracking-[0.16em] text-emerald-600">
              Workspace aktif
            </p>
            {context.companies.length > 1 ? (
              <div className="relative mt-1 inline-flex max-w-full items-center">
                <Building2 className="pointer-events-none absolute left-3 h-4 w-4 text-slate-400" />
                <select
                  value={activeCompanyId}
                  onChange={(event) => void changeCompany(event.target.value)}
                  disabled={switchingCompany}
                  className="max-w-full appearance-none rounded-xl border border-slate-200 bg-slate-50 py-2 pl-9 pr-9 text-sm font-bold text-slate-800 outline-none transition focus:border-emerald-500"
                >
                  {context.companies.map((company) => (
                    <option key={company.id} value={company.id}>
                      {company.company_name} ({company.company_code})
                    </option>
                  ))}
                </select>
                <ChevronDown className="pointer-events-none absolute right-3 h-4 w-4 text-slate-400" />
              </div>
            ) : (
              <p className="mt-1 truncate text-sm font-bold text-slate-800">
                {activeCompany.company_name}
              </p>
            )}
          </div>

          <div className="hidden text-right sm:block">
            <p className="text-sm font-bold text-slate-900">
              {context.profile.name}
            </p>
            <p className="text-xs text-slate-500">
              {roleLabels[activeCompany.roleCode] ?? activeCompany.roleCode}
            </p>
          </div>
          <button
            onClick={logout}
            className="rounded-xl border border-slate-200 p-2.5 text-slate-500 transition hover:border-rose-200 hover:bg-rose-50 hover:text-rose-600"
            aria-label="Keluar"
          >
            <LogOut className="h-5 w-5" />
          </button>
        </header>

        <main className="p-4 md:p-8">
          {activeView !== "dashboard" && (
            <WorkspaceNavigation
              view={activeView}
              canGoBack={viewHistory.length > 0}
              goBack={goBack}
              goHome={goHome}
              items={availableNavigation}
              modules={navigationModules}
              openModule={openModule}
            />
          )}

          {notice && (
            <div className="mb-6 flex items-start gap-3 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-900">
              <CircleAlert className="mt-0.5 h-5 w-5 shrink-0" />
              <span className="flex-1">{notice}</span>
              <button onClick={() => setNotice(null)} aria-label="Tutup">
                <X className="h-4 w-4" />
              </button>
            </div>
          )}

          {activeView === "dashboard" &&
            (activeModuleId ? (
              <ModuleLauncher
                module={
                  navigationModules.find(
                    (module) => module.id === activeModuleId,
                  ) ?? null
                }
                loading={navigationLoading}
                goHome={goHome}
                openView={navigateTo}
              />
            ) : (
              <AppLauncher
                modules={navigationModules}
                loading={navigationLoading}
                openModule={openModule}
              />
            ))}

          {activeView === "products" && (
            <CanonicalProductsView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              canManage={canManageProducts}
              notify={setNotice}
              onChanged={loadTenantData}
            />
          )}

          {activeView === "bundles" && (
            <BundleMasterView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              canManage={bundleNavigation?.capabilities.includes("MANAGE") ?? false}
              notify={setNotice}
            />
          )}

          {activeView === "sales-returns" && (
            <SalesReturnApprovalView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              canApprove={Boolean(canApproveSalesReturn)}
              canCancel={Boolean(canCancelSalesReturn)}
              notify={setNotice}
            />
          )}

          {activeView === "sales-documents" && (
            <SalesDocumentView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              notify={setNotice}
            />
          )}

          {activeView === "delivery-documents" && (
            <DeliveryDocumentView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              canManage={Boolean(canManageSalesDelivery)}
              notify={setNotice}
            />
          )}

          {activeView === "expense-approvals" && (
            <ExpenseApprovalView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              canApprove={Boolean(canApproveExpense)}
              canCancelAdministrative={Boolean(canCancelExpenseAdministrative)}
              canDisburseNonCash={Boolean(canDisburseExpenseNonCash)}
              notify={setNotice}
            />
          )}

          {activeView === "cash-deposits" && (
            <CashDepositApprovalView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              canApprove={Boolean(canApproveCashDeposit)}
              notify={setNotice}
            />
          )}

          {activeView === "deposit-variances" && (
            <DepositVarianceResolutionView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              canManage={Boolean(canManageDepositVariance)}
              canReview={Boolean(canReviewDepositVariance)}
              notify={setNotice}
            />
          )}

          {activeView === "customer-balances" && (
            <CustomerBalanceView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              canRequest={Boolean(canRequestCustomerBalance)}
              canReview={Boolean(canReviewCustomerBalance)}
              notify={setNotice}
            />
          )}

          {activeView === "stock-real" && (
            <StockRealView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
            />
          )}

          {activeView === "stock-movements" && (
            <StockMovementView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
            />
          )}

          {activeView === "stock-transfers" && (
            <StockTransferView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              capabilities={stockTransferNavigation?.capabilities ?? []}
              notify={setNotice}
            />
          )}

          {activeView === "stock-adjustments" && (
            <StockAdjustmentView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              capabilities={stockAdjustmentNavigation?.capabilities ?? []}
              notify={setNotice}
            />
          )}

          {activeView === "stock-opnames" && (
            <StockOpnameView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              capabilities={stockOpnameNavigation?.capabilities ?? []}
              notify={setNotice}
            />
          )}

          {activeView === "masters" && (
            <MasterDataView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              stores={stores}
              canManage={Boolean(canManageMaster)}
              notify={setNotice}
            />
          )}

          {activeView === "minimum-stock" && (
            <MinimumStockView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              canManage={Boolean(canManageMaster)}
              notify={setNotice}
            />
          )}

          {activeView === "opening-stock" && (
            <OpeningStockView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              capabilities={openingStockNavigation?.capabilities ?? []}
              notify={setNotice}
            />
          )}

          {activeView === "data-exchange" && (
            <DataExchangeView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              companyName={activeCompany.company_name}
              notify={setNotice}
            />
          )}

          {activeView === "suppliers" && (
            <SupplierMasterView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              canManageSupplier={Boolean(canManageSupplier)}
              canManageRelation={Boolean(canManageProductSupplier)}
              notify={setNotice}
            />
          )}

          {activeView === "supplier-orders" && (
            <SupplierOrderView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              canCreate={canCreateSupplierOrder}
              canPost={canPostSupplierOrder}
              canExport={canExportSupplierOrder}
              notify={setNotice}
            />
          )}

          {activeView === "purchase-returns" && (
            <PurchaseReturnApprovalView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              canReview={canReviewPurchaseReturn}
              canPost={canPostPurchaseReturn}
              canCancel={canCancelPurchaseReturn}
              notify={setNotice}
            />
          )}

          {activeView === "staff" && (
            <StaffView
              staff={staff}
              canManage={Boolean(canManage)}
              canAssignExisting={context.isSuperAdmin}
              openCreate={() => setShowStaff(true)}
              openAssignExisting={() => setShowExistingStaff(true)}
              openDetail={setSelectedStaff}
            />
          )}

          {activeView === "customers" && (
            <CustomerMasterView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              canManageIdentity={Boolean(canManageCustomerIdentity)}
              canManageCredit={Boolean(canManageCustomerCredit)}
              notify={setNotice}
            />
          )}

          {activeView === "pricelists" && (
            <PricelistMasterView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              canManage={Boolean(canManagePricelist)}
              notify={setNotice}
            />
          )}

          {activeView === "payment-methods" && (
            <PaymentMethodMasterView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              canManage={Boolean(canManagePaymentMethod)}
              notify={setNotice}
            />
          )}

          {activeView === "finance-masters" && (
            <FinanceMasterView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              canManage={Boolean(canManageFinanceMaster)}
              notify={setNotice}
            />
          )}

          {activeView === "tax-rules" && (
            <TaxMasterView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              canManage={Boolean(canManageFinanceMaster)}
              notify={setNotice}
            />
          )}

          {activeView === "supplier-invoices" && (
            <SupplierInvoiceMatchingView
              key={activeCompanyId}
              session={session}
              canCreate={supplierInvoiceNavigation?.capabilities.includes("CREATE_DRAFT") ?? false}
              canEdit={supplierInvoiceNavigation?.capabilities.includes("EDIT_DRAFT") ?? false}
              canPost={supplierInvoiceNavigation?.capabilities.includes("POST") ?? false}
              canManagePolicy={supplierInvoiceNavigation?.capabilities.includes("APPROVE") ?? false}
            />
          )}

          {activeView === "supplier-payments" && (
            <SupplierPaymentView
              key={activeCompanyId}
              session={session}
              canCreate={supplierPaymentNavigation?.capabilities.includes("CREATE_DRAFT") ?? false}
              canEdit={supplierPaymentNavigation?.capabilities.includes("EDIT_DRAFT") ?? false}
              canPost={supplierPaymentNavigation?.capabilities.includes("POST") ?? false}
            />
          )}

          {activeView === "finance" && (
            <FinanceOperationsView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              canCreatePeriod={Boolean(canCreateFinancePeriod)}
              canLockPeriod={Boolean(canLockFinancePeriod)}
              canReopenPeriod={Boolean(canReopenFinancePeriod)}
              canReverseJournal={Boolean(canReverseFinanceJournal)}
              canOperateQueue={Boolean(canOperateFinanceQueue)}
              notify={setNotice}
            />
          )}

          {activeView === "companies" && context.isSuperAdmin && (
            <CompaniesView
              companies={context.companies}
              openCreate={() => setShowTenant(true)}
            />
          )}

          {activeView === "module-settings" && (
            <ModuleSettingsView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              companyName={activeCompany.company_name}
              isSuperAdmin={context.isSuperAdmin}
              notify={setNotice}
            />
          )}

          {activeView === "company-branding" && (
            <CompanyBrandingView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              companyName={activeCompany.company_name}
              canManage={Boolean(canManage)}
              notify={setNotice}
            />
          )}
        </main>
      </div>

      {showStaff && (
        <StaffModal
          session={session}
          company={activeCompany}
          stores={stores}
          close={() => setShowStaff(false)}
          complete={async () => {
            setShowStaff(false);
            setNotice("Anggota tim berhasil dibuat.");
            await loadTenantData();
          }}
        />
      )}

      {showExistingStaff && context.isSuperAdmin && (
        <ExistingStaffAssignmentModal
          session={session}
          company={activeCompany}
          stores={stores}
          close={() => setShowExistingStaff(false)}
          complete={async () => {
            setShowExistingStaff(false);
            setNotice(
              "Akun existing berhasil diberi akses ke perusahaan aktif.",
            );
            await loadTenantData();
          }}
        />
      )}

      {selectedStaff && (
        <StaffAccessDetailModal
          session={session}
          member={selectedStaff}
          close={() => setSelectedStaff(null)}
          complete={async () => {
            setNotice("Akses perusahaan user berhasil diperbarui.");
            await loadTenantData();
          }}
        />
      )}

      {showTenant && context.isSuperAdmin && (
        <TenantModal
          session={session}
          close={() => setShowTenant(false)}
          complete={async () => {
            setShowTenant(false);
            setNotice("Perusahaan dan akun owner berhasil dibuat.");
            await loadContext(session);
          }}
        />
      )}
    </div>
  );
}

function LoginScreen() {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    setLoading(true);
    setError("");
    const result = await supabase.auth.signInWithPassword({ email, password });
    if (result.error) setError(result.error.message);
    setLoading(false);
  }

  return (
    <div className="min-h-screen bg-[#f4f6f8] p-4 lg:grid lg:grid-cols-[1.05fr_.95fr] lg:p-0">
      <div className="hidden bg-slate-950 p-14 text-white lg:flex lg:flex-col lg:justify-between">
        <div className="flex items-center gap-3 text-lg font-black tracking-tight">
          <span className="grid h-10 w-10 place-items-center rounded-xl bg-emerald-500">
            <Store className="h-5 w-5" />
          </span>
          MADS
        </div>
        <div className="max-w-xl">
          <span className="inline-flex items-center gap-2 rounded-full border border-white/10 bg-white/5 px-3 py-1.5 text-xs font-semibold text-emerald-300">
            <ShieldCheck className="h-4 w-4" /> Multi-company workspace
          </span>
          <h1 className="mt-6 text-5xl font-black leading-[1.08] tracking-tight">
            Operasional toko yang rapi, dari satu tempat.
          </h1>
          <p className="mt-5 max-w-lg text-base leading-7 text-slate-400">
            Pantau produk, stok, tim, dan aktivitas perusahaan dengan konteks
            tenant yang aman dan mudah dipindah.
          </p>
        </div>
        <p className="text-xs text-slate-600">Management Distribution System · Backoffice</p>
      </div>

      <div className="flex min-h-[calc(100vh-2rem)] items-center justify-center lg:min-h-screen">
        <form
          onSubmit={submit}
          className="w-full max-w-md rounded-3xl border border-slate-200 bg-white p-7 shadow-sm sm:p-10"
        >
          <div className="mb-8 lg:hidden">
            <span className="grid h-11 w-11 place-items-center rounded-2xl bg-emerald-500 text-white">
              <Store className="h-5 w-5" />
            </span>
          </div>
          <p className="text-sm font-semibold text-emerald-600">
            Selamat datang kembali
          </p>
          <h2 className="mt-2 text-3xl font-black tracking-tight text-slate-950">
            Masuk ke backoffice
          </h2>
          <p className="mt-2 text-sm leading-6 text-slate-500">
            Gunakan akun yang telah dibuat oleh platform admin atau pemilik
            perusahaan.
          </p>

          {error && (
            <div className="mt-5 rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-700">
              {error}
            </div>
          )}
          <label className="mt-7 block text-sm font-semibold text-slate-700">
            Email
          </label>
          <input
            value={email}
            onChange={(event) => setEmail(event.target.value)}
            type="email"
            required
            placeholder="nama@perusahaan.com"
            className="mt-2 w-full rounded-xl border border-slate-200 px-4 py-3 text-sm outline-none transition focus:border-emerald-500 focus:ring-4 focus:ring-emerald-500/10"
          />
          <label className="mt-5 block text-sm font-semibold text-slate-700">
            Password
          </label>
          <input
            value={password}
            onChange={(event) => setPassword(event.target.value)}
            type="password"
            required
            className="mt-2 w-full rounded-xl border border-slate-200 px-4 py-3 text-sm outline-none transition focus:border-emerald-500 focus:ring-4 focus:ring-emerald-500/10"
          />
          <button
            disabled={loading}
            className="mt-7 flex w-full items-center justify-center gap-2 rounded-xl bg-emerald-500 px-4 py-3.5 text-sm font-bold text-white transition hover:bg-emerald-600 disabled:opacity-60"
          >
            {loading && <Loader2 className="h-4 w-4 animate-spin" />}
            {loading ? "Memeriksa akun..." : "Masuk"}
          </button>
          <p className="mt-5 text-center text-xs leading-5 text-slate-400">
            Pendaftaran publik dinonaktifkan untuk menjaga keamanan data
            perusahaan.
          </p>
        </form>
      </div>
    </div>
  );
}

function Sidebar({
  view,
  navigate,
  goHome,
  items,
  open,
  close,
}: {
  view: View;
  navigate: (view: View) => void;
  goHome: () => void;
  items: NavigationItem[];
  open: boolean;
  close: () => void;
}) {
  const [query, setQuery] = useState("");
  const normalizedQuery = query.trim().toLocaleLowerCase("id-ID");
  const visibleItems = useMemo(
    () =>
      normalizedQuery
        ? items.filter((item) =>
            `${item.label} ${item.moduleName ?? ""}`
              .toLocaleLowerCase("id-ID")
              .includes(normalizedQuery),
          )
        : items,
    [items, normalizedQuery],
  );
  return (
    <>
      {open && (
        <button
          onClick={close}
          className="fixed inset-0 z-40 bg-slate-950/40 lg:hidden"
          aria-label="Tutup fast link"
        />
      )}
      <aside
        aria-hidden={!open}
        className={`fixed inset-y-0 left-0 z-50 flex h-dvh w-72 flex-col border-r border-slate-800 bg-slate-950 text-white shadow-2xl shadow-slate-950/30 transition-transform duration-200 ${open ? "translate-x-0" : "-translate-x-full"}`}
      >
        <div className="flex h-20 shrink-0 items-center justify-between border-b border-white/5 px-6">
          <button
            type="button"
            onClick={() => {
              goHome();
              close();
            }}
            className="flex items-center gap-3 rounded-xl text-left font-black tracking-tight outline-none transition hover:text-emerald-300 focus-visible:ring-2 focus-visible:ring-emerald-400 focus-visible:ring-offset-2 focus-visible:ring-offset-slate-950"
            aria-label="Kembali ke halaman awal"
            title="Kembali ke halaman awal"
          >
            <span className="grid h-10 w-10 place-items-center rounded-xl bg-emerald-500">
              <Store className="h-5 w-5" />
            </span>
            MADS
          </button>
          <button
            onClick={close}
            className="rounded-lg p-2 text-slate-400 hover:bg-white/5 hover:text-white"
            aria-label="Tutup fast link"
          >
            <X className="h-5 w-5" />
          </button>
        </div>
        <div className="shrink-0 border-b border-white/5 px-4 py-4">
          <label className="relative block">
            <span className="sr-only">Cari menu yang tersedia</span>
            <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-500" />
            <input
              type="search"
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              placeholder="Cari menu..."
              className="w-full rounded-xl border border-white/10 bg-white/[.05] py-2.5 pl-10 pr-9 text-sm text-white outline-none placeholder:text-slate-500 focus:border-emerald-400 focus:ring-2 focus:ring-emerald-400/20"
            />
            {query && (
              <button
                type="button"
                onClick={() => setQuery("")}
                className="absolute right-2 top-1/2 -translate-y-1/2 rounded-lg p-1 text-slate-500 hover:bg-white/10 hover:text-white"
                aria-label="Hapus pencarian"
              >
                <X className="h-3.5 w-3.5" />
              </button>
            )}
          </label>
          <p className="mt-2 px-1 text-[10px] leading-4 text-slate-500">
            Pencarian hanya mencakup menu yang diizinkan untuk role dan Company
            aktif.
          </p>
        </div>
        <nav className="min-h-0 flex-1 overflow-y-auto overscroll-contain px-3 py-5">
          <p className="px-3 text-[10px] font-bold uppercase tracking-[.18em] text-slate-500">
            Fast link
          </p>
          <div className="mt-3 space-y-1">
            {visibleItems.map((item) => {
              const Icon = item.icon;
              const active = view === item.id;
              return (
                <button
                  key={item.id}
                  onClick={() => {
                    if (item.id === "dashboard") goHome();
                    else navigate(item.id);
                    close();
                  }}
                  className={`flex w-full items-center gap-3 rounded-xl px-3 py-3 text-sm font-semibold transition ${active ? "bg-emerald-500 text-white shadow-lg shadow-emerald-500/15" : "text-slate-400 hover:bg-white/5 hover:text-white"}`}
                >
                  <Icon className="h-4 w-4" />
                  {item.label}
                </button>
              );
            })}
            {visibleItems.length === 0 && (
              <div className="rounded-xl border border-dashed border-white/10 px-4 py-8 text-center text-xs leading-5 text-slate-500">
                Menu tidak ditemukan pada akses Anda.
              </div>
            )}
          </div>
        </nav>
        <div className="m-3 shrink-0 rounded-2xl border border-white/5 bg-white/[.03] p-4">
          <div className="flex items-center gap-2 text-xs font-bold text-emerald-300">
            <ShieldCheck className="h-4 w-4" /> Tenant protection
          </div>
          <p className="mt-2 text-[11px] leading-5 text-slate-500">
            Fast link hanya menampilkan menu sesuai role. API dan RLS tetap
            menjadi pengaman utama.
          </p>
        </div>
      </aside>
    </>
  );
}

function WorkspaceNavigation({
  view,
  canGoBack,
  goBack,
  goHome,
  items,
  modules,
  openModule,
}: {
  view: View;
  canGoBack: boolean;
  goBack: () => void;
  goHome: () => void;
  items: NavigationItem[];
  modules: NavigationCatalogModule[];
  openModule: (moduleId: string) => void;
}) {
  const page = items.find((item) => item.id === view);
  const appModule = modules.find((module) =>
    module.items.some((item) => item.id === view),
  );

  return (
    <div className="mb-6 flex min-w-0 items-center gap-3">
      <button
        type="button"
        onClick={goBack}
        className="inline-flex h-10 shrink-0 items-center gap-2 rounded-xl border border-slate-200 bg-white px-3 text-sm font-bold text-slate-700 shadow-sm transition hover:border-emerald-200 hover:bg-emerald-50 hover:text-emerald-700 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-emerald-500 disabled:cursor-not-allowed disabled:opacity-45"
        aria-label={
          canGoBack
            ? "Kembali ke halaman sebelumnya"
            : "Kembali ke halaman aplikasi"
        }
        title={
          canGoBack
            ? "Kembali ke halaman sebelumnya"
            : "Kembali ke halaman aplikasi"
        }
      >
        <ArrowLeft className="h-4 w-4" />
        <span className="hidden sm:inline">Kembali</span>
      </button>

      <nav
        aria-label="Lokasi halaman"
        className="flex min-w-0 flex-1 items-center gap-1.5 overflow-x-auto rounded-xl border border-slate-200 bg-white px-3 py-2.5 text-sm shadow-sm"
      >
        <button
          type="button"
          onClick={goHome}
          className="inline-flex shrink-0 items-center gap-1.5 font-semibold text-slate-500 transition hover:text-emerald-700"
        >
          <House className="h-4 w-4" />
          <span>Beranda</span>
        </button>
        {appModule && (
          <>
            <ChevronRight className="h-4 w-4 shrink-0 text-slate-300" />
            <button
              type="button"
              onClick={() => openModule(appModule.id)}
              className="shrink-0 font-semibold text-slate-500 transition hover:text-emerald-700"
            >
              {appModule.name}
            </button>
          </>
        )}
        <ChevronRight className="h-4 w-4 shrink-0 text-slate-300" />
        <span className="truncate font-bold text-slate-900" aria-current="page">
          {page?.label ?? view}
        </span>
      </nav>
    </div>
  );
}

function PageTitle({
  eyebrow,
  title,
  description,
  action,
}: {
  eyebrow: string;
  title: string;
  description: string;
  action?: React.ReactNode;
}) {
  return (
    <div className="mb-7 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
      <div>
        <p className="text-xs font-bold uppercase tracking-[.16em] text-emerald-600">
          {eyebrow}
        </p>
        <h1 className="mt-2 text-2xl font-black tracking-tight text-slate-950 md:text-3xl">
          {title}
        </h1>
        <p className="mt-2 text-sm text-slate-500">{description}</p>
      </div>
      {action}
    </div>
  );
}

function AppLauncher({
  modules,
  loading,
  openModule,
}: {
  modules: NavigationCatalogModule[];
  loading: boolean;
  openModule: (moduleId: string) => void;
}) {
  if (loading) return <LauncherLoading />;
  return modules.length > 0 ? (
    <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
      {modules.map((module) => {
        const ModuleIcon = iconByKey[module.iconKey];
        return (
          <button
            key={module.id}
            type="button"
            onClick={() => openModule(module.id)}
            className="group rounded-3xl border border-slate-200 bg-white p-6 text-left shadow-sm transition hover:-translate-y-0.5 hover:border-slate-300 hover:shadow-lg focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-emerald-500"
          >
            <span
              className={`grid h-14 w-14 place-items-center rounded-2xl text-white shadow-sm ${module.color}`}
            >
              <ModuleIcon className="h-6 w-6" />
            </span>
            <span className="mt-6 flex items-center gap-3">
              <span className="flex-1 text-lg font-black text-slate-950">
                {module.name}
              </span>
              <ChevronRight className="h-5 w-5 text-slate-300 transition group-hover:translate-x-1 group-hover:text-emerald-600" />
            </span>
            <span className="mt-2 block text-sm leading-6 text-slate-500">
              {module.description}
            </span>
          </button>
        );
      })}
    </div>
  ) : (
    <div className="rounded-3xl border border-dashed border-slate-300 bg-white p-12 text-center">
      <ShieldCheck className="mx-auto h-8 w-8 text-slate-300" />
      <h3 className="mt-4 font-bold text-slate-700">
        Belum ada aplikasi Backoffice untuk role ini
      </h3>
      <p className="mt-2 text-sm text-slate-500">
        Hubungi Company Admin bila akses kerja perlu ditambahkan.
      </p>
    </div>
  );
}

function ModuleLauncher({
  module,
  loading,
  goHome,
  openView,
}: {
  module: NavigationCatalogModule | null;
  loading: boolean;
  goHome: () => void;
  openView: (view: View) => void;
}) {
  if (loading) return <LauncherLoading />;
  if (!module) return null;
  const ModuleIcon = iconByKey[module.iconKey];
  return (
    <>
      <div className="mb-6 flex items-center gap-3">
        <button
          type="button"
          onClick={goHome}
          className="inline-flex h-10 items-center gap-2 rounded-xl border border-slate-200 bg-white px-3 text-sm font-bold text-slate-700 shadow-sm hover:bg-slate-50"
        >
          <ArrowLeft className="h-4 w-4" /> Aplikasi
        </button>
        <span
          className={`grid h-10 w-10 shrink-0 place-items-center rounded-xl text-white ${module.color}`}
        >
          <ModuleIcon className="h-5 w-5" />
        </span>
        <div className="min-w-0">
          <h1 className="truncate text-xl font-black text-slate-950">
            {module.name}
          </h1>
          <p className="truncate text-sm text-slate-500">
            Pilih menu kerja yang ingin dibuka.
          </p>
        </div>
      </div>
      <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
        {module.items.map((item) => {
          const ItemIcon = iconByKey[item.iconKey];
          return (
            <button
              key={item.id}
              type="button"
              onClick={() => openView(item.id)}
              className="group flex min-h-36 items-start gap-4 rounded-2xl border border-slate-200 bg-white p-5 text-left shadow-sm transition hover:-translate-y-0.5 hover:border-slate-300 hover:shadow-md focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-emerald-500"
            >
              <span className="grid h-11 w-11 shrink-0 place-items-center rounded-xl bg-slate-100 text-slate-700 transition group-hover:bg-emerald-50 group-hover:text-emerald-700">
                <ItemIcon className="h-5 w-5" />
              </span>
              <span className="min-w-0 flex-1">
                <span className="flex items-center gap-2 font-black text-slate-950">
                  {item.label}
                  <ChevronRight className="ml-auto h-4 w-4 text-slate-300" />
                </span>
                <span className="mt-2 block text-sm leading-6 text-slate-500">
                  {item.description}
                </span>
              </span>
            </button>
          );
        })}
      </div>
    </>
  );
}

function LauncherLoading() {
  return (
    <div className="grid min-h-64 place-items-center">
      <Loader2 className="h-7 w-7 animate-spin text-emerald-500" />
    </div>
  );
}

function StaffView({
  staff,
  canManage,
  canAssignExisting,
  openCreate,
  openAssignExisting,
  openDetail,
}: {
  staff: Staff[];
  canManage: boolean;
  canAssignExisting: boolean;
  openCreate: () => void;
  openAssignExisting: () => void;
  openDetail: (member: Staff) => void;
}) {
  const action = canManage ? (
    <div className="flex flex-wrap justify-end gap-2">
      {canAssignExisting && (
        <button
          onClick={openAssignExisting}
          className="inline-flex items-center justify-center gap-2 rounded-xl border border-slate-200 bg-white px-4 py-3 text-sm font-bold text-slate-700 shadow-sm hover:bg-slate-50"
        >
          <ArrowRightLeft className="h-4 w-4" />
          Tambah akses akun existing
        </button>
      )}
      <button
        onClick={openCreate}
        className="inline-flex items-center justify-center gap-2 rounded-xl bg-emerald-500 px-4 py-3 text-sm font-bold text-white"
      >
        <UserPlus className="h-4 w-4" />
        Buat akun baru
      </button>
    </div>
  ) : undefined;
  return (
    <>
      <PageTitle
        eyebrow="Access control"
        title="Tim & akses"
        description="Kelola pengguna hanya pada company yang sedang aktif. Satu akun dapat memiliki role berbeda di beberapa company."
        action={action}
      />
      <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
        {staff.map((member) => (
          <button
            type="button"
            onClick={() => openDetail(member)}
            key={member.id}
            className="rounded-2xl border border-slate-200 bg-white p-5 text-left shadow-sm transition hover:-translate-y-0.5 hover:border-emerald-300 hover:shadow-md focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-emerald-500"
          >
            <div className="flex items-start gap-4">
              <div className="grid h-12 w-12 place-items-center rounded-2xl bg-slate-100 font-black text-slate-600">
                {member.name.slice(0, 2).toUpperCase()}
              </div>
              <div className="min-w-0 flex-1">
                <div className="flex items-start gap-2">
                  <div className="min-w-0 flex-1">
                    <p className="truncate font-bold text-slate-950">
                      {member.name}
                    </p>
                    <p className="truncate text-sm text-slate-500">
                      {member.email}
                    </p>
                  </div>
                  <ChevronRight className="mt-1 h-4 w-4 text-slate-300" />
                </div>
                <span className={`mt-3 inline-flex rounded-full px-2.5 py-1 text-[11px] font-bold ${member.status==='ACTIVE'?'bg-emerald-50 text-emerald-700':'bg-amber-50 text-amber-700'}`}>
                  {member.status==='ACTIVE'
                    ? roleLabels[member.role] ?? member.role
                    : 'Akses dicabut di Company ini'}
                </span>
                <p className="mt-3 text-xs font-semibold text-slate-400">
                  Klik untuk melihat detail akses
                </p>
              </div>
            </div>
          </button>
        ))}
        {!staff.length && (
          <div className="md:col-span-2 xl:col-span-3">
            <Empty label="Belum ada anggota yang dapat ditampilkan." />
          </div>
        )}
      </div>
    </>
  );
}

function CompaniesView({
  companies,
  openCreate,
}: {
  companies: CompanyContext[];
  openCreate: () => void;
}) {
  return (
    <>
      <PageTitle
        eyebrow="Platform control"
        title="Perusahaan"
        description="Daftar seluruh tenant aktif yang dapat dikelola super admin."
        action={
          <button
            onClick={openCreate}
            className="inline-flex items-center justify-center gap-2 rounded-xl bg-emerald-500 px-4 py-3 text-sm font-bold text-white"
          >
            <Building2 className="h-4 w-4" />
            Perusahaan baru
          </button>
        }
      />
      <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
        {companies.map((company) => (
          <div
            key={company.id}
            className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm"
          >
            <div className="flex items-center gap-4">
              <div className="grid h-12 w-12 place-items-center rounded-2xl bg-blue-50 text-blue-600">
                <Building2 className="h-5 w-5" />
              </div>
              <div>
                <p className="font-bold">{company.company_name}</p>
                <p className="mt-1 text-xs font-semibold text-slate-400">
                  {company.company_code}
                </p>
              </div>
            </div>
            <div className="mt-5 flex items-center justify-between border-t border-slate-100 pt-4 text-xs">
              <span className="text-slate-500">Status tenant</span>
              <span className="rounded-full bg-emerald-50 px-2.5 py-1 font-bold text-emerald-700">
                {company.status}
              </span>
            </div>
          </div>
        ))}
      </div>
    </>
  );
}

function StaffModal({
  session,
  company,
  stores,
  close,
  complete,
}: {
  session: Session;
  company: CompanyContext;
  stores: StoreOption[];
  close: () => void;
  complete: () => Promise<void>;
}) {
  useEscapeClose(close);
  const [form, setForm] = useState({
    name: "",
    email: "",
    password: "",
    role_code: "CASHIER",
    store_id: stores[0]?.id ?? "NONE",
  });
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  async function submit(event: React.FormEvent) {
    event.preventDefault();
    setLoading(true);
    setError("");
    try {
      const response = await fetch("/api/staff/create", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          ...authHeaders(session),
        },
        body: JSON.stringify({ ...form, company_id: company.id }),
      });
      const payload = (await response.json()) as { error?: string };
      if (!response.ok)
        throw new Error(payload.error ?? "Gagal membuat anggota");
      await complete();
    } catch (caught) {
      setError(
        caught instanceof Error ? caught.message : "Gagal membuat anggota",
      );
    } finally {
      setLoading(false);
    }
  }
  return (
    <Modal
      title="Tambah anggota tim"
      description={`Akun hanya akan mendapat akses ke ${company.company_name}. Kasir wajib ditugaskan ke satu Toko agar Terminal POS tersedia.`}
      close={close}
    >
      <form onSubmit={submit} className="space-y-4">
        <Field label="Nama">
          <input
            required
            value={form.name}
            onChange={(e) => setForm({ ...form, name: e.target.value })}
            className="input"
          />
        </Field>
        <Field label="Email">
          <input
            required
            type="email"
            value={form.email}
            onChange={(e) => setForm({ ...form, email: e.target.value })}
            className="input"
          />
        </Field>
        <Field label="Password sementara">
          <input
            required
            minLength={8}
            type="password"
            value={form.password}
            onChange={(e) => setForm({ ...form, password: e.target.value })}
            className="input"
          />
        </Field>
        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="Role">
            <select
              value={form.role_code}
              onChange={(e) => {
                const role = e.target.value;
                setForm({
                  ...form,
                  role_code: role,
                  store_id:
                    role === "CASHIER" && form.store_id === "NONE"
                      ? (stores[0]?.id ?? "NONE")
                      : form.store_id,
                });
              }}
              className="input"
            >
              {[
                "CASHIER",
                "STORE_MANAGER",
                "WAREHOUSE_ADMIN",
                "FINANCE",
                "ACCOUNTING",
                "COMPANY_ADMIN",
              ].map((role) => (
                <option key={role} value={role}>
                  {roleLabels[role]}
                </option>
              ))}
            </select>
          </Field>
          <Field
            label={
              form.role_code === "CASHIER"
                ? "Toko assignment Kasir (wajib)"
                : "Toko"
            }
          >
            <select
              required={form.role_code === "CASHIER"}
              value={form.store_id}
              onChange={(e) => setForm({ ...form, store_id: e.target.value })}
              className="input"
            >
              <option value="NONE" disabled={form.role_code === "CASHIER"}>
                Semua / tidak spesifik
              </option>
              {stores.map((store) => (
                <option key={store.id} value={store.id}>
                  {store.store_name}
                </option>
              ))}
            </select>
          </Field>
        </div>
        {form.role_code === "CASHIER" && stores.length === 0 && (
          <FormError message="Buat atau aktifkan Toko terlebih dahulu sebelum membuat akun Kasir." />
        )}
        {error && <FormError message={error} />}
        <ModalActions
          close={close}
          loading={
            loading || (form.role_code === "CASHIER" && stores.length === 0)
          }
          submit="Buat akun"
        />
      </form>
    </Modal>
  );
}

function ExistingStaffAssignmentModal({
  session,
  company,
  stores,
  close,
  complete,
}: {
  session: Session;
  company: CompanyContext;
  stores: StoreOption[];
  close: () => void;
  complete: () => Promise<void>;
}) {
  useEscapeClose(close);
  const [form, setForm] = useState({
    email: "",
    role_code: "COMPANY_ADMIN",
    store_id: "NONE",
  });
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  async function submit(event: React.FormEvent) {
    event.preventDefault();
    setLoading(true);
    setError("");
    try {
      const response = await fetch("/api/staff/assign-existing", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          ...authHeaders(session),
        },
        body: JSON.stringify({ ...form, company_id: company.id }),
      });
      const payload = (await response.json()) as { error?: string };
      if (!response.ok)
        throw new Error(payload.error ?? "Gagal menambahkan akses akun");
      await complete();
    } catch (caught) {
      const code = caught instanceof Error ? caught.message : "";
      setError(
        {
          TARGET_USER_NOT_FOUND: "Akun dengan email tersebut tidak ditemukan.",
          CASHIER_STORE_ASSIGNMENT_REQUIRED:
            "Kasir wajib ditugaskan ke satu Toko.",
          STORE_NOT_IN_COMPANY:
            "Toko tidak aktif atau bukan milik perusahaan ini.",
          ROLE_NOT_ALLOWED: "Role tidak diizinkan.",
          SUPER_ADMIN_REQUIRED:
            "Hanya Super Admin yang dapat menambahkan akun existing lintas perusahaan.",
        }[code] ??
          code ??
          "Gagal menambahkan akses akun",
      );
    } finally {
      setLoading(false);
    }
  }
  const cashier = form.role_code === "CASHIER";
  return (
    <Modal
      title="Tambah akses akun existing"
      description={`Cari akun secara exact melalui email, lalu beri akses khusus ke ${company.company_name}. Akun dan password tidak dibuat ulang.`}
      close={close}
    >
      <form onSubmit={submit} className="space-y-4">
        <Field label="Email akun existing">
          <input
            required
            type="email"
            autoComplete="off"
            value={form.email}
            onChange={(event) =>
              setForm({ ...form, email: event.target.value })
            }
            className="input"
            placeholder="user@contoh.com"
          />
        </Field>
        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="Role di perusahaan ini">
            <select
              value={form.role_code}
              onChange={(event) => {
                const role = event.target.value;
                setForm({
                  ...form,
                  role_code: role,
                  store_id:
                    role === "CASHIER" && form.store_id === "NONE"
                      ? (stores[0]?.id ?? "NONE")
                      : form.store_id,
                });
              }}
              className="input"
            >
              {[
                "COMPANY_OWNER",
                "COMPANY_ADMIN",
                "STORE_MANAGER",
                "WAREHOUSE_ADMIN",
                "FINANCE",
                "ACCOUNTING",
                "CASHIER",
              ].map((role) => (
                <option key={role} value={role}>
                  {roleLabels[role]}
                </option>
              ))}
            </select>
          </Field>
          <Field
            label={
              cashier ? "Toko assignment Kasir (wajib)" : "Toko (opsional)"
            }
          >
            <select
              required={cashier}
              value={form.store_id}
              onChange={(event) =>
                setForm({ ...form, store_id: event.target.value })
              }
              className="input"
            >
              <option value="NONE" disabled={cashier}>
                Semua / tidak spesifik
              </option>
              {stores.map((store) => (
                <option key={store.id} value={store.id}>
                  {store.store_name}
                </option>
              ))}
            </select>
          </Field>
        </div>
        <p className="rounded-xl bg-blue-50 p-3 text-xs leading-5 text-blue-700">
          Role ini hanya berlaku pada perusahaan aktif. Default Company akun
          tidak akan diubah.
        </p>
        {cashier && stores.length === 0 && (
          <FormError message="Buat atau aktifkan Toko terlebih dahulu sebelum menambahkan Kasir." />
        )}
        {error && <FormError message={error} />}
        <ModalActions
          close={close}
          loading={loading || (cashier && stores.length === 0)}
          submit="Tambahkan akses"
        />
      </form>
    </Modal>
  );
}

function TenantModal({
  session,
  close,
  complete,
}: {
  session: Session;
  close: () => void;
  complete: () => Promise<void>;
}) {
  useEscapeClose(close);
  const [form, setForm] = useState({
    company_name: "",
    company_code: "",
    name: "",
    email: "",
    password: "",
  });
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  async function submit(event: React.FormEvent) {
    event.preventDefault();
    setLoading(true);
    setError("");
    try {
      const response = await fetch("/api/tenant/register", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          ...authHeaders(session),
        },
        body: JSON.stringify(form),
      });
      const payload = (await response.json()) as { error?: string };
      if (!response.ok)
        throw new Error(payload.error ?? "Gagal membuat perusahaan");
      await complete();
    } catch (caught) {
      setError(
        caught instanceof Error ? caught.message : "Gagal membuat perusahaan",
      );
    } finally {
      setLoading(false);
    }
  }
  return (
    <Modal
      title="Perusahaan baru"
      description="Sistem sekaligus membuat toko utama, gudang default, dan akun company owner."
      close={close}
    >
      <form onSubmit={submit} className="space-y-4">
        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="Nama perusahaan">
            <input
              required
              value={form.company_name}
              onChange={(e) =>
                setForm({ ...form, company_name: e.target.value })
              }
              className="input"
            />
          </Field>
          <Field label="Kode">
            <input
              required
              value={form.company_code}
              onChange={(e) =>
                setForm({ ...form, company_code: e.target.value.toUpperCase() })
              }
              className="input uppercase"
            />
          </Field>
        </div>
        <Field label="Nama owner">
          <input
            required
            value={form.name}
            onChange={(e) => setForm({ ...form, name: e.target.value })}
            className="input"
          />
        </Field>
        <Field label="Email owner">
          <input
            required
            type="email"
            value={form.email}
            onChange={(e) => setForm({ ...form, email: e.target.value })}
            className="input"
          />
        </Field>
        <Field label="Password sementara">
          <input
            required
            minLength={8}
            type="password"
            value={form.password}
            onChange={(e) => setForm({ ...form, password: e.target.value })}
            className="input"
          />
        </Field>
        {error && <FormError message={error} />}
        <ModalActions
          close={close}
          loading={loading}
          submit="Buat perusahaan"
        />
      </form>
    </Modal>
  );
}

function Modal({
  title,
  description,
  close,
  children,
}: {
  title: string;
  description: string;
  close: () => void;
  children: React.ReactNode;
}) {
  return (
    <div className="fixed inset-0 z-[70] grid place-items-center bg-slate-950/45 p-4 backdrop-blur-sm">
      <div className="max-h-[92vh] w-full max-w-xl overflow-y-auto rounded-3xl bg-white p-6 shadow-2xl sm:p-8">
        <div className="flex items-start justify-between gap-4">
          <div>
            <h2 className="text-xl font-black text-slate-950">{title}</h2>
            <p className="mt-2 text-sm leading-6 text-slate-500">
              {description}
            </p>
          </div>
          <button
            onClick={close}
            className="rounded-xl bg-slate-100 p-2 text-slate-500"
          >
            <X className="h-4 w-4" />
          </button>
        </div>
        <div className="mt-7">{children}</div>
      </div>
    </div>
  );
}
function Field({
  label,
  children,
}: {
  label: string;
  children: React.ReactNode;
}) {
  return (
    <label className="block text-sm font-semibold text-slate-700">
      {label}
      <span className="mt-2 block">{children}</span>
    </label>
  );
}
function FormError({ message }: { message: string }) {
  return (
    <div className="mt-4 rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-700">
      {message}
    </div>
  );
}
function ModalActions({
  close,
  loading,
  submit,
}: {
  close: () => void;
  loading: boolean;
  submit: string;
}) {
  return (
    <div className="mt-7 flex justify-end gap-3 border-t border-slate-100 pt-5">
      <button
        type="button"
        onClick={close}
        className="rounded-xl border border-slate-200 px-4 py-2.5 text-sm font-bold text-slate-600"
      >
        Batal
      </button>
      <button
        disabled={loading}
        className="inline-flex items-center gap-2 rounded-xl bg-emerald-500 px-5 py-2.5 text-sm font-bold text-white disabled:opacity-60"
      >
        {loading && <Loader2 className="h-4 w-4 animate-spin" />}
        {submit}
      </button>
    </div>
  );
}
function Empty({ label }: { label: string }) {
  return <div className="p-10 text-center text-sm text-slate-400">{label}</div>;
}
function FullScreenLoader({
  label,
  notice,
}: {
  label: string;
  notice?: string | null;
}) {
  return (
    <div className="min-h-screen bg-slate-50 grid place-items-center">
      <div className="text-center">
        <Loader2 className="mx-auto h-8 w-8 animate-spin text-emerald-500" />
        <p className="mt-4 text-sm font-semibold text-slate-600">{label}</p>
        {notice && <p className="mt-2 text-xs text-rose-600">{notice}</p>}
      </div>
    </div>
  );
}
