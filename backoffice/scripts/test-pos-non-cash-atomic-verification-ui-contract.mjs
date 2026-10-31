import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const read = (path) => readFileSync(resolve(root, path), "utf8");

const panel = read("src/components/SalesPaymentVerificationPanel.tsx");
const route = read("src/app/api/finance/sales-payment-verifications/route.ts");
const finance = read("src/components/FinanceOperationsView.tsx");

assert.match(panel, /Verifikasi dan posting jurnal diproses bersamaan/);
assert.match(panel, /Pembayaran terverifikasi dan jurnal berhasil diposting/);
assert.match(panel, /Tidak ada jurnal tambahan karena akun sumber dan clearing sama/);
assert.doesNotMatch(panel, /masuk event HOLD|Proses melalui Antrian Jurnal/);
assert.doesNotMatch(panel, /openQueue/);
assert.doesNotMatch(finance, /openQueue=\{\(\) => setTab\("queue"\)\}/);
assert.match(route, /POSTABLE_ACCOUNTING_PERIOD_NOT_FOUND/);
assert.match(route, /POSTING_RULE_SET_MISSING_OR_AMBIGUOUS/);
assert.match(route, /ACCOUNT_MAPPING_MISSING_OR_AMBIGUOUS/);

console.log("pos-non-cash-atomic-verification-ui-contract: PASS");
