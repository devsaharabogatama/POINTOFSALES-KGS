import { ApiRouteError, requirePermissionCapability, type CallerContext } from "@/lib/server-auth";

export type DataExchangeAction = "EXPORT" | "IMPORT";
export type DataExchangeFormat = "CSV" | "XLSX";
export type DataExchangeModule =
  | "INVENTORY"
  | "CONTACTS"
  | "PURCHASE"
  | "SALES"
  | "FINANCE";

export type DataExchangeCatalogItem = {
  moduleKey: DataExchangeModule;
  typeKey: string;
  label: string;
  description: string;
  allowedActions: DataExchangeAction[];
  formats: DataExchangeFormat[];
  scopeKind: "COMPANY" | "STORE" | "WAREHOUSE";
  exportOnly: boolean;
  filters: Array<"MONTH" | "DATE_RANGE">;
};

type CatalogDefinition = Omit<DataExchangeCatalogItem, "allowedActions"> & {
  exportRoles: string[];
  importRoles?: string[];
};

const ownerRoles = ["COMPANY_OWNER", "COMPANY_ADMIN"];
const inventoryRoles = [...ownerRoles, "STORE_MANAGER", "WAREHOUSE_ADMIN"];
const supplierRoles = [...inventoryRoles, "FINANCE", "ACCOUNTING"];
const salesRoles = [...ownerRoles, "STORE_MANAGER", "FINANCE", "ACCOUNTING"];
const financeRoles = [...ownerRoles, "FINANCE", "ACCOUNTING"];

const master = (
  moduleKey: DataExchangeModule,
  typeKey: string,
  label: string,
  description: string,
  exportRoles: string[],
): CatalogDefinition => ({
  moduleKey,
  typeKey,
  label,
  description,
  exportRoles,
  importRoles: ownerRoles,
  formats: ["CSV"],
  scopeKind: "COMPANY",
  exportOnly: false,
  filters: [],
});

const financeReport = (
  typeKey: string,
  label: string,
  description: string,
): CatalogDefinition => ({
  moduleKey: "FINANCE",
  typeKey,
  label,
  description,
  exportRoles: financeRoles,
  formats: ["XLSX"],
  scopeKind: "COMPANY",
  exportOnly: true,
  filters: ["MONTH"],
});

const financeCsv = (
  typeKey: string,
  label: string,
  description: string,
): CatalogDefinition => ({
  moduleKey: "FINANCE",
  typeKey,
  label,
  description,
  exportRoles: financeRoles,
  formats: ["CSV"],
  scopeKind: "COMPANY",
  exportOnly: true,
  filters: [],
});

const inventoryReport = (
  typeKey: string,
  label: string,
  description: string,
): CatalogDefinition => ({
  moduleKey: "INVENTORY",
  typeKey,
  label,
  description,
  exportRoles: [...inventoryRoles, "FINANCE", "ACCOUNTING"],
  formats: ["CSV"],
  scopeKind: "COMPANY",
  exportOnly: true,
  filters: [],
});

const salesInvoiceReport: CatalogDefinition = {
  moduleKey: "SALES",
  typeKey: "SALES_DOCUMENTS",
  label: "Invoice Penjualan",
  description: "Daftar Invoice dan detail produk berdasarkan rentang tanggal Invoice.",
  exportRoles: salesRoles,
  formats: ["XLSX"],
  scopeKind: "COMPANY",
  exportOnly: true,
  filters: ["DATE_RANGE"],
};

const salesPricelistExchange: CatalogDefinition = {
  moduleKey: "SALES",
  typeKey: "PRICELISTS",
  label: "Pricelist",
  description: "Harga Product-UOM, Pricelist Customer, dan tier kuantitas Global.",
  exportRoles: salesRoles,
  importRoles: ownerRoles,
  // Existing export remains CSV; the dedicated importer accepts CSV and XLSX.
  formats: ["CSV"],
  scopeKind: "COMPANY",
  exportOnly: false,
  filters: [],
};

const definitions: CatalogDefinition[] = [
  master("INVENTORY", "PRODUCT_CATEGORY", "Kategori Produk", "Daftar kategori produk aktif dan nonaktif.", inventoryRoles),
  master("INVENTORY", "UOM", "Satuan (UOM)", "Master satuan beserta aturan quantity.", inventoryRoles),
  master("INVENTORY", "WAREHOUSE", "Gudang", "Gudang, tipe, Toko, dan fungsi operasional.", inventoryRoles),
  master("CONTACTS", "SUPPLIER", "Supplier", "Data Supplier dan informasi pembayarannya.", supplierRoles),
  master("CONTACTS", "CUSTOMER", "Customer", "Identitas, kategori, induk, Pricelist, dan batas kredit Customer Company aktif.", salesRoles),
  master("CONTACTS", "CUSTOMER_CATEGORY", "Kategori Pelanggan", "Grouping pelanggan pada Company aktif.", salesRoles),
  master("FINANCE", "CHART_OF_ACCOUNT", "Chart of Account", "Daftar akun Company; akun sistem tetap read-only.", financeRoles),
  master("FINANCE", "TRANSACTION_CATEGORY", "Kategori Transaksi", "Kategori dan System Event Finance.", financeRoles),
  master("INVENTORY", "PRODUCT", "Produk + Satuan", "Produk dan seluruh Product-UOM sebagai satu grup.", inventoryRoles),
  master("INVENTORY", "PRODUCT_UOM", "Tambah / Perbarui UOM Produk", "Tambah atau perbarui satu UOM tanpa mengganti UOM Product lainnya.", inventoryRoles),
  master("PURCHASE", "PRODUCT_SUPPLIER", "Produk–Supplier", "Relasi pembelian Product, Supplier, dan UOM.", supplierRoles),
  master("INVENTORY", "PRODUCT_WAREHOUSE_MINIMUM_STOCK", "Minimum Stock", "Konfigurasi minimum stock per Produk–Gudang.", inventoryRoles),
  inventoryReport("STOCK_REAL", "Stock Real", "Saldo aktual, minimum stock, dan valuasi FIFO per Produk–Gudang."),
  inventoryReport("STOCK_MOVEMENTS", "Kartu Stok", "Ledger perubahan stok final beserta dokumen sumber."),
  salesInvoiceReport,
  salesPricelistExchange,
  financeReport("JOURNAL_ENTRIES", "Journal Entries", "Dokumen jurnal beserta seluruh baris debit/kredit."),
  financeReport("GENERAL_LEDGER", "Buku Besar", "Ringkasan akun dan detail ledger POSTED."),
  financeReport("TRIAL_BALANCE", "Neraca Saldo", "Saldo awal, mutasi, dan saldo akhir akun POSTED."),
  financeReport("INCOME_STATEMENT", "Laba Rugi", "Pendapatan, HPP, beban, dan laba periode."),
  financeReport("BALANCE_SHEET", "Neraca", "Aset, liabilitas, dan ekuitas per akhir bulan."),
  financeReport("PENDING_ANALYSIS", "Transaksi Belum Masuk Laporan", "Financial Event HOLD/deferred yang tidak masuk laporan POSTED."),
  financeReport("RECONCILIATION_SUMMARY", "Ringkasan Rekonsiliasi", "Perbandingan current-state subledger dan ledger."),
  financeReport("CUSTOMER_BALANCES", "Saldo Customer", "Saldo berjalan dan mutasi Customer pada periode terpilih."),
  financeReport("SUPPLIER_INVOICES", "Faktur Supplier", "Faktur, matching, pajak, dan variance pembelian pada periode terpilih."),
  financeReport("SUPPLIER_PAYMENTS", "Pembayaran Supplier", "Pembayaran AP dan alokasi Faktur Supplier pada periode terpilih."),
  financeCsv("PAYMENT_METHODS", "Metode Pembayaran", "Metode pembayaran, cakupan Toko, jalur dana, bukti, dan konfigurasi fee."),
];

export const masterDataExchangeTypes = new Set(
  definitions.filter((item) => item.formats.includes("CSV")).map((item) => item.typeKey),
);

export const financeDataExchangeTypes = new Set(
  definitions.filter((item) => item.formats.includes("XLSX")).map((item) => item.typeKey),
);

async function effectiveRole(caller: CallerContext, companyId: string) {
  const { data: profile, error: profileError } = await caller.client
    .from("profiles")
    .select("role")
    .eq("id", caller.user.id)
    .maybeSingle();
  if (profileError) throw profileError;
  if (profile?.role === "super_admin") return "SUPER_ADMIN";

  const { data: membership, error: membershipError } = await caller.client
    .from("company_memberships")
    .select("role_code")
    .eq("company_id", companyId)
    .eq("user_id", caller.user.id)
    .eq("status", "ACTIVE")
    .maybeSingle();
  if (membershipError) throw membershipError;
  if (!membership?.role_code) {
    throw new ApiRouteError("COMPANY_ACCESS_DENIED", 403);
  }
  return membership.role_code;
}

function actionsFor(
  definition: CatalogDefinition,
  role: string,
): DataExchangeAction[] {
  if (role === "SUPER_ADMIN") {
    return definition.importRoles ? ["EXPORT", "IMPORT"] : ["EXPORT"];
  }
  const actions: DataExchangeAction[] = [];
  if (definition.exportRoles.includes(role)) actions.push("EXPORT");
  if (definition.importRoles?.includes(role)) actions.push("IMPORT");
  return actions;
}

export async function authorizedDataExchangeCatalog(
  caller: CallerContext,
  companyId: string,
): Promise<DataExchangeCatalogItem[]> {
  const role = await effectiveRole(caller, companyId);
  const optionalPermission = (permissionKey: string) =>
    requirePermissionCapability(caller, companyId, permissionKey, "VIEW")
      .catch((error) => {
        if (error instanceof ApiRouteError && error.message === "CUSTOM_PERMISSION_DENIED") {
          return null;
        }
        throw error;
      });
  const [productPermission, stockRealPermission, stockMovementPermission,
    minimumStockPermission, customerPermission, supplierPermission,
    salesDocumentPermission, pricelistPermission, customerBalancePermission,
    supplierInvoicePermission, supplierPaymentPermission, paymentMethodPermission] =
    await Promise.all([
      optionalPermission("inventory.products"),
      optionalPermission("inventory.stock_real"),
      optionalPermission("inventory.stock_movements"),
      optionalPermission("inventory.minimum_stock"),
      optionalPermission("contacts.customers"),
      optionalPermission("contacts.suppliers"),
      optionalPermission("sales.sales_documents"),
      optionalPermission("sales.pricelists"),
      optionalPermission("finance.customer_balances"),
      optionalPermission("finance.supplier_invoices"),
      optionalPermission("finance.supplier_payments"),
      optionalPermission("finance.payment_methods"),
    ]);
  const scopedPermissions: Record<string, typeof productPermission> = {
    PRODUCT: productPermission,
    PRODUCT_UOM: productPermission,
    STOCK_REAL: stockRealPermission,
    STOCK_MOVEMENTS: stockMovementPermission,
    PRODUCT_WAREHOUSE_MINIMUM_STOCK: minimumStockPermission,
    CUSTOMER: customerPermission,
    CUSTOMER_CATEGORY: customerPermission,
    SUPPLIER: supplierPermission,
    PRODUCT_SUPPLIER: supplierPermission,
    SALES_DOCUMENTS: salesDocumentPermission,
    PRICELISTS: pricelistPermission,
    CUSTOMER_BALANCES: customerBalancePermission,
    SUPPLIER_INVOICES: supplierInvoicePermission,
    SUPPLIER_PAYMENTS: supplierPaymentPermission,
    PAYMENT_METHODS: paymentMethodPermission,
  };
  return definitions.flatMap((definition) => {
    let allowedActions = actionsFor(definition, role);
    const permission = scopedPermissions[definition.typeKey];
    if (definition.typeKey in scopedPermissions) {
      if (!permission) return [];
      allowedActions = allowedActions.filter((action) =>
        permission.effectiveCapabilities.includes(action));
    }
    if (definition.typeKey === "PRICELISTS") {
      // Distributor Pricelist import also mutates authoritative Product-UOM
      // prices. Do not advertise IMPORT when Product import is restricted.
      allowedActions = allowedActions.filter((action) => action !== "IMPORT"
        || Boolean(productPermission?.effectiveCapabilities.includes("IMPORT")));
    }
    if (!allowedActions.length) return [];
    return [{
      moduleKey: definition.moduleKey,
      typeKey: definition.typeKey,
      label: definition.label,
      description: definition.description,
      allowedActions,
      formats: definition.formats,
      scopeKind: definition.scopeKind,
      exportOnly: definition.exportOnly,
      filters: definition.filters,
    }];
  });
}

export async function requireDataExchangeAction(
  caller: CallerContext,
  companyId: string,
  typeKey: string,
  action: DataExchangeAction,
) {
  const definition = definitions.find((item) => item.typeKey === typeKey);
  if (!definition) {
    throw new ApiRouteError("DATA_EXCHANGE_TYPE_UNSUPPORTED", 400);
  }
  const role = await effectiveRole(caller, companyId);
  if (!actionsFor(definition, role).includes(action)) {
    throw new ApiRouteError("DATA_EXCHANGE_ACTION_FORBIDDEN", 403);
  }
  const permissionKey = typeKey === "PRODUCT" || typeKey === "PRODUCT_UOM"
    ? "inventory.products"
    : typeKey === "STOCK_REAL"
      ? "inventory.stock_real"
      : typeKey === "STOCK_MOVEMENTS"
        ? "inventory.stock_movements"
        : typeKey === "PRODUCT_WAREHOUSE_MINIMUM_STOCK"
          ? "inventory.minimum_stock"
        : typeKey === "CUSTOMER" || typeKey === "CUSTOMER_CATEGORY"
          ? "contacts.customers"
        : typeKey === "SUPPLIER" || typeKey === "PRODUCT_SUPPLIER"
          ? "contacts.suppliers"
        : typeKey === "SALES_DOCUMENTS"
          ? "sales.sales_documents"
        : typeKey === "PRICELISTS"
          ? "sales.pricelists"
        : typeKey === "CUSTOMER_BALANCES"
          ? "finance.customer_balances"
        : typeKey === "SUPPLIER_INVOICES"
          ? "finance.supplier_invoices"
        : typeKey === "SUPPLIER_PAYMENTS"
          ? "finance.supplier_payments"
        : typeKey === "PAYMENT_METHODS"
          ? "finance.payment_methods"
        : null;
  if (permissionKey) {
    await requirePermissionCapability(caller, companyId, permissionKey, action);
  }
  if (typeKey === "PRICELISTS" && action === "IMPORT") {
    await requirePermissionCapability(caller, companyId, "inventory.products", "IMPORT");
  }
  return definition;
}
