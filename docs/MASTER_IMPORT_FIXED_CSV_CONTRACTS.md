# Fixed CSV Contracts — KGS POS Master Import/Export

**Status:** approved implementation contract for G2 phase 35+
**Requirement:** MST-005
**Scope:** master data that users can create through the active Backoffice

## 1. Principles

- Templates are versioned and fixed; arbitrary user headers are mapped only at
  the staging boundary.
- Create templates use user-facing names and approved business codes, not UUID
  or hidden technical codes. UUID remains an optional technical round-trip
  column in exported files.
- References never auto-create another master. Missing or ambiguous references
  become preview errors.
- Grouped masters commit atomically per group, while a bad group does not roll
  back unrelated valid groups.
- Every import uses staging → mapping → validation → preview → explicit update
  confirmation → partial commit → history/error download.
- Updates use optimistic `master_version`; data changed after preview is not
  overwritten.
- A template version is recorded on every job. Future template changes require
  a new version and compatibility parser.

## 2. Included Master Types and Dependency Order

| Order | Import type | Atomic group |
|---|---|---|
| 1 | Product Category | one category |
| 1 | UOM | one UOM |
| 1 | Warehouse | one warehouse |
| 1 | Supplier | one supplier |
| 1 | Customer Category | one category |
| 1 | Chart of Account | one account; parent must already exist or appear earlier |
| 1 | Transaction Category | one category referencing a System Event key |
| 2 | Tax Rule | Tax identity plus one effective version |
| 2 | Product | Product plus all Product-UOM rows and optional Tax assignment |
| 2 | Pricelist | header, Store scope, and all Product-UOM rules |
| 2 | Payment Method | method plus Store assignments and fee configuration |
| 3 | Customer | Customer plus parent and reusable Pricelist assignment |
| 3 | Product-Supplier | one Product/Supplier/purchase-UOM relation |
| 3 | Product-Warehouse Minimum Stock | one Product/Warehouse setting |
| 3 | Transaction Account Rule | category/function/account effective rule |
| 3 | Company Account Fallback | function/account effective fallback |

Staff/password, Company creation, feature entitlement, posted transactions,
stock balance, Opening Stock, movement, journal, and system-owned Walk-In or
internal payment method are not bulk master imports. They require dedicated
security/onboarding or transactional workflows.

## 3. Fixed Template Headers

Create templates do not contain `internal_id`, `master_version`, or hidden
technical code. An **Export untuk Update** contains those read-only fields so a
rename still targets the correct row. Product SKU, Customer code, COA account
code, Tax code, barcode, and Supplier-owned Product code remain business-facing.

### Simple masters

```text
product_category_v1:
name,is_active,sales_tax_rule_name,purchase_tax_rule_name

uom_v1:
name,uom_type,allow_decimal,decimal_precision,is_active

warehouse_v1:
name,warehouse_type,store_name,location,is_sale_source,is_purchase_destination,is_active

supplier_v1:
name,contact_name,phone,address,npwp,payment_term,bank_name,bank_account_number,bank_account_holder,is_active

customer_category_v1:
name,is_active

chart_of_account_v1:
code,name,account_type,normal_balance,parent_account_code,system_function_key,is_postable,allow_manual_posting,allow_reconciliation,is_active

transaction_category_v1:
name,system_key,description,is_active
```

`store_name` menerima label export `Nama Toko (KODE)`, nama Toko yang unik,
atau kode Toko existing untuk compatibility. API menyelesaikannya ke UUID
active-Company; UUID tidak menjadi input create template.

### Product group

One row represents one UOM of a Product. Rows sharing `product_key` are one
atomic Product group.

```text
product_v1:
product_key,sku,product_name,category_name,image_url,is_active,uom_name,factor_to_base,purchase_allowed,sales_allowed,purchase_price,sale_price,barcode,sales_tax_rule_name,purchase_tax_rule_name,weight_per_largest_uom_kg
```

Rules:

- exactly one row has `factor_to_base=1` and becomes Base UOM;
- largest active factor becomes weight-reference UOM;
- `weight_per_largest_uom_kg` is identical on every row in the group;
- at least one active Sales UOM and, for STOCK, Purchase UOM are required;
- referenced Category, UOM, and Tax Rule must already exist and be active;
- Product import never creates those references and never creates stock.

### Product-Supplier

```text
product_supplier_v1:
product_sku,supplier_name,purchase_uom_name,supplier_product_code,reference_purchase_price,is_preferred_supplier,is_active
```

One row represents one Product-Supplier relation. Product is resolved from its
tenant-scoped SKU; Supplier and purchase UOM are resolved from active,
unambiguous names. The selected UOM must belong to the Product and be enabled
for purchase. The import does not create any of those references.

`reference_purchase_price` may be blank but cannot be negative.
`last_purchase_price` is transaction-owned and is never importable. At most one
active preferred Supplier is allowed per Product. To switch preferred Supplier
in one file, include the old relation with `is_preferred_supplier=false` and
the new relation with `is_preferred_supplier=true`.

### Product-Warehouse Minimum Stock

```text
product_warehouse_minimum_stock_v1:
product_sku,warehouse_name,minimum_stock_base_qty,low_stock_alert_enabled
```

One row represents one Product-Warehouse pair. Product is resolved from its
tenant-scoped SKU and Warehouse from its active, unambiguous user-facing name.
The Product must be active, non-bundle, and have one active Base Product-UOM
with factor `1`.

`minimum_stock_base_qty` always uses the Product Base UOM, may be blank only
when the alert is disabled, and cannot be negative. Importing this setting
never creates a stock balance, movement, Stock Request, Supplier Order, or
another master.

### Customer

```text
customer_v1:
code,name,customer_category_name,parent_customer_name,default_pricelist_name,phone,email,address,customer_type,credit_limit,credit_term_days,notes,is_active
```

Parent must be an active root Customer. Walk-In is export-only and rejected on
import.

### Pricelist group

One row represents one Product-UOM rule. Rows sharing `pricelist_key` are one
atomic Pricelist. `store_codes` is pipe-separated and must contain existing
Store codes.

```text
pricelist_v1:
pricelist_key,name,scope,priority,is_default,applies_all_stores,store_codes,valid_from,valid_until,notes,is_active,product_sku,uom_name,min_qty,tier_qty_basis,pricing_method,final_unit_price,discount_amount_per_unit,discount_percent,rule_valid_from,rule_valid_until,rule_is_active
```

`final_unit_price` is used for ordinary fixed-price rules. Discount fields are
used only when the selected pricing method explicitly requires them.

### Payment Method group

```text
payment_method_v1:
name,method_type,settlement_route,is_default,available_all_stores,store_codes,proof_mode,fee_enabled,fee_bearer,fee_type,fee_percent,fee_fixed_amount,clearing_account_function,bank_account_function,effective_from,effective_until,is_active
```

System-owned Customer Balance and Ketul Offset are export-only.

### Tax Rule

```text
tax_rule_v1:
code,name,scope,rate_percent,calculation_scope,price_mode,account_code,is_recoverable,effective_from,effective_to,status,is_active
```

### Finance rules

```text
transaction_account_rule_v1:
transaction_category_code,account_function_key,account_code,effective_from,effective_to,status

company_account_fallback_v1:
account_function_key,account_code,effective_from,effective_to,status
```

## 4. Template Validation

Before a file can reach database staging, the Backoffice must reject:

- wrong template version or import type;
- duplicate/blank headers;
- missing required headers;
- more than 5 MB, 5,000 rows, 100 columns, or 20 UOM rows per Product;
- malformed CSV quoting;
- duplicate group keys with conflicting header fields;
- unsupported enum/boolean/date/number formats;
- a technical ID without matching master version when ID update mode is used.

The server repeats all validation. Client validation is UX only.

## 5. Hidden Technical Code

New Product Category, UOM, Warehouse, Supplier, Customer Category, Pricelist,
Payment Method, and custom Transaction Category receive an immutable code from
the server. Format is a tenant-scoped prefix plus padded sequence, for example
`UOM-000001`. Existing codes are preserved.

The UUID remains the real canonical identity. The sequence is only a stable
technical code and never replaces UUID. Allocation is transactional and
concurrency-safe; `MAX(code)+1` and number reuse are prohibited.

Blank create templates do not expose this code. Export-for-update may include
`system_code` as read-only diagnostics together with `internal_id` and
`master_version`.

## 6. Rollout Boundary

The four existing non-stock imports remain active. Expansion to grouped and
Finance/Sales masters requires the Phase 35 preflight result, additive database
migration, postflight, behavioral tests, and authenticated UI smoke. Applied
Phase 30–33 migrations must not be edited.
