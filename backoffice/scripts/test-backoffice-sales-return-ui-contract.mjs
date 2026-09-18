import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const read = (path) => readFileSync(resolve(root, path), "utf8");

const navigation = read("src/lib/navigation-catalog.ts");
const navigationApi = read("src/app/api/me/navigation-catalog/route.ts");
const page = read("src/app/page.tsx");
const salesOrder = read("src/components/BackofficeSalesOrderView.tsx");
const returnView = read("src/components/BackofficeSalesReturnView.tsx");
const receiptView = read("src/components/CustomerReturnReceiptView.tsx");
const returnRoute = read("src/app/api/sales/backoffice-returns/[id]/route.ts");
const receiptRoute = read("src/app/api/inventory/customer-return-receipts/route.ts");

assert.match(navigation, /id:\s*["']backoffice-sales-returns["']/);
assert.match(navigation, /id:\s*["']customer-return-receipts["']/);
assert.match(navigationApi, /sales\.backoffice_returns/);
assert.match(navigationApi, /inventory\.customer_return_receipts/);
assert.match(page, /initialReturnId=\{salesReturnLaunch\?\.returnId\}/);
assert.match(salesOrder, /get_backoffice_sales_return_links|returns\?: ReturnLink\[\]/);
assert.match(salesOrder, /Buat Retur/);
assert.match(returnView, /Finance memilih tujuan setiap qty/);
assert.match(returnView, /Post Credit Note/);
assert.match(returnView, /Post Refund/);
assert.match(receiptView, /RESTOCK|Masuk stok/);
assert.match(receiptView, /DESTROY|Dihancurkan/);
assert.match(receiptRoute, /get_backoffice_sales_return_receipt_workspace/);
assert.match(returnRoute, /get_backoffice_sales_return_activity/);

for (const source of [returnView, receiptView]) {
  assert.doesNotMatch(source, /cashier_sessions|open cashier|pos session/i);
}

console.log("backoffice-sales-return-ui-contract: PASS");
