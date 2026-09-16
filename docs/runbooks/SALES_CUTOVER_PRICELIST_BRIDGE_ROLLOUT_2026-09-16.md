# Sales Cutover Pricelist Bridge Rollout — 2026-09-16

Status: `PRODUCTION DATABASE LIVE + BEHAVIOR/POSTFLIGHT USER-CONFIRMED PASS`.
Authenticated Apply smoke dan UAT masih pending. Agent tidak menjalankan SQL Production.

Jalankan setiap file penuh di SQL Editor Production, satu per satu:

1. [Preflight](../../supabase/diagnostics/sales_cutover_pricelist_bridge_preflight.sql)
2. [Migration](../../supabase/migrations/20260916120000_sales_cutover_pricelist_bridge.sql)
3. [Postflight](../../supabase/diagnostics/sales_cutover_pricelist_bridge_postflight.sql)
4. [Behavioral rollback-only](../../supabase/tests/sales_process_cutover_retail_to_backoffice_converter_behavior.sql)
5. Jalankan [Postflight](../../supabase/diagnostics/sales_cutover_pricelist_bridge_postflight.sql) lagi.

Stop pada `BLOCKER`, SQL error, `FAIL`, atau behavioral bukan `PASS`. Jangan
menghapus plan/dokumen/Pricelist/ledger atau bypass guard.

Setelah seluruh SQL PASS, muat ulang Pengaturan Sales, Apply plan sebagai
Platform Super Admin, lalu pastikan target muncul dan Customer, line, Qty, UOM,
harga, diskon, pajak, ongkir, total, tanggal, jatuh tempo dan link histori sama.
Conversion tidak boleh membuat Stock Movement, jurnal, atau pembayaran.

Apply Production adalah authenticated smoke non-rollback. Bila gagal, simpan
error lengkap dan jangan membuat dokumen pengganti manual; Apply bersifat atomik.
