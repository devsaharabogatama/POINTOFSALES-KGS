# Office/Purchase — paket pemasangan production manual

Status: ALL90 FILES + FINAL POSTFLIGHT PRODUCTION USER-CONFIRMED PASS;
CLIENT DEPLOYMENT / SMOKE / UAT BELUM DIKONFIRMASI.

Next: [rekonsiliasi data dan release client](OFFICE_PURCHASE_PRODUCTION_CLIENT_RELEASE.md).
Daftar di bawah menjadi catatan pemasangan; jangan rerun migration yang installed.

## Hasil audit dan impact map

User mengirim guard Production: duplicate Receipt Draft0, invalid reservation0,
invalid authorization0, dependency Receipt belum installed tetapi prerequisite ada.
39 Draft BACKOFFICE dipertahankan; jangan hapus atau membuat ulang histori.
Hasil rehearsal lama tetap dipakai; tidak perlu clone baru tanpa relevant drift.

Paket ini menunjuk file migration existing yang diuji, tidak menulis ulang atau
menggabungkannya. Impact pemasangan mencakup schema/RPC/role/Stock reservation,
FIFO, customer/supplier payment, cashier-session compatibility, Finance dan audit.
Runtime mutation tetap melalui transactional/idempotent/concurrency-safe cores.
Tidak ada perubahan source runtime pada penyusunan paket. Source SHA256 tersedia di
[manifest paket](../../supabase/rollout/office_purchase_production_manual_plan.json).

## Sebelum memulai — bukan langsung klik seluruh migration

1. Pastikan project Production `nbxjslqojexjfogamnjt` dan backup/restore point terbaru
   tersedia. Jangan pakai artifact build clone atau environment Development.
2. Tutup mutation operasional POS/Backoffice selama pemasangan; bereskan submission
   offline dan antrean posting melalui flow yang ada, bukan menghapusnya.
3. Jalankan ulang [discovery](../../supabase/diagnostics/office_purchase_production_discovery_preflight.sql)
   dan [sensitive guards](../../supabase/diagnostics/office_purchase_production_sensitive_rows.sql).
   Ledger harus sesuai plan; queue bersih. Jika versi lain sudah terpasang, jangan
   rerun file; rekonsiliasi plan dulu. Jalankan [fingerprint](../../supabase/diagnostics/office_purchase_clone_closing_fingerprints.sql)
   dan simpan CSV baseline tepat sebelum migration pertama.
4. Authenticated UI/role/concurrency/bulk UAT yang belum dibuktikan tetap gate
   release/pilot; jangan menganggap postflight SQL pengganti behavioral/UI test.
   Pemasangan database manual dilakukan hanya pada waktu maintenance yang disetujui.

## Cara menjalankan

- Buka link migration sesuai nomor; paste ISI FILE PENUH ke SQL Editor, run satu
  file, pastikan sukses sebelum berikutnya. Original BEGIN/guard/COMMIT dipertahankan.
- File `20260910100000` SUDAH TERPASANG: sengaja tidak masuk90 langkah.
- Setelah semua file dalam satu checkpoint, jalankan setiap postflight di bawahnya.
  Simpan seluruh CSV. Jika FAIL/BLOCKER/error/timeout/unexpected row mutation,
  STOP; jangan mematikan guard, mengedit installed migration, atau lanjut checkpoint.
- SETUP harus ditafsirkan sesuai runbook aslinya; INFO/zero rows bukan bukti behavior.
  Jangan menjalankan fixture behavioral/seed di Production.
- Dua insert compatibility ada di posisi rehearsal, bukan sort timestamp:
  DP setelah status SO (E); Receipt line_no sebelum AUTO_RO (G).

## Checkpoint A — Quotation/SO, roles, harga, diskon, pajak dan revisi

13 file; nomor 1–13 dari90.

| No. | Migration (buka file lengkap) |
| --- | --- |
| 1 | [20260908100000_backoffice_sales_process_identity_foundation.sql](../../supabase/migrations/20260908100000_backoffice_sales_process_identity_foundation.sql) |
| 2 | [20260908110000_backoffice_sales_order_foundation.sql](../../supabase/migrations/20260908110000_backoffice_sales_order_foundation.sql) |
| 3 | [20260908120000_backoffice_sales_order_runtime.sql](../../supabase/migrations/20260908120000_backoffice_sales_order_runtime.sql) |
| 4 | [20260908121000_backoffice_sales_order_runtime_digest_fix.sql](../../supabase/migrations/20260908121000_backoffice_sales_order_runtime_digest_fix.sql) |
| 5 | [20260909100000_backoffice_sales_odoo_form_default_warehouse.sql](../../supabase/migrations/20260909100000_backoffice_sales_odoo_form_default_warehouse.sql) |
| 6 | [20260909110000_backoffice_sales_canonical_tax_runtime.sql](../../supabase/migrations/20260909110000_backoffice_sales_canonical_tax_runtime.sql) |
| 7 | [20260909120000_backoffice_sales_pricelist_header.sql](../../supabase/migrations/20260909120000_backoffice_sales_pricelist_header.sql) |
| 8 | [20260909130000_sales_roles_and_module_authority.sql](../../supabase/migrations/20260909130000_sales_roles_and_module_authority.sql) |
| 9 | [20260909140000_backoffice_sales_commercial_parity.sql](../../supabase/migrations/20260909140000_backoffice_sales_commercial_parity.sql) |
| 10 | [20260909141000_backoffice_sales_canonical_insert_fix.sql](../../supabase/migrations/20260909141000_backoffice_sales_canonical_insert_fix.sql) |
| 11 | [20260909142000_backoffice_sales_revision_status_runtime.sql](../../supabase/migrations/20260909142000_backoffice_sales_revision_status_runtime.sql) |
| 12 | [20260909143000_backoffice_sales_activity_cancel_guard.sql](../../supabase/migrations/20260909143000_backoffice_sales_activity_cancel_guard.sql) |
| 13 | [20260909144000_backoffice_sales_revision_commercial_reset_fix.sql](../../supabase/migrations/20260909144000_backoffice_sales_revision_commercial_reset_fix.sql) |

Postflight checkpoint:

- [backoffice_sales_revision_commercial_reset_fix_postflight.sql](../../supabase/diagnostics/backoffice_sales_revision_commercial_reset_fix_postflight.sql)

## Checkpoint B — Reservation, gudang/transit, DO dan penerimaan customer

11 file; nomor 14–24 dari90.

| No. | Migration (buka file lengkap) |
| --- | --- |
| 14 | [20260909145000_backoffice_sales_fulfillment_foundation.sql](../../supabase/migrations/20260909145000_backoffice_sales_fulfillment_foundation.sql) |
| 15 | [20260909146000_backoffice_sales_fulfillment_contract_fix.sql](../../supabase/migrations/20260909146000_backoffice_sales_fulfillment_contract_fix.sql) |
| 16 | [20260909147000_backoffice_sales_confirm_fulfillment_runtime.sql](../../supabase/migrations/20260909147000_backoffice_sales_confirm_fulfillment_runtime.sql) |
| 17 | [20260909148000_backoffice_sales_inventory_reservation_read_model.sql](../../supabase/migrations/20260909148000_backoffice_sales_inventory_reservation_read_model.sql) |
| 18 | [20260909149000_backoffice_sales_inventory_delivery_read_model.sql](../../supabase/migrations/20260909149000_backoffice_sales_inventory_delivery_read_model.sql) |
| 19 | [20260909150000_warehouse_transit_usage_foundation.sql](../../supabase/migrations/20260909150000_warehouse_transit_usage_foundation.sql) |
| 20 | [20260909151000_backoffice_sales_dispatch_to_transit.sql](../../supabase/migrations/20260909151000_backoffice_sales_dispatch_to_transit.sql) |
| 21 | [20260909152000_backoffice_sales_customer_receipt_foundation.sql](../../supabase/migrations/20260909152000_backoffice_sales_customer_receipt_foundation.sql) |
| 22 | [20260909153000_backoffice_sales_receipt_finance_mapping.sql](../../supabase/migrations/20260909153000_backoffice_sales_receipt_finance_mapping.sql) |
| 23 | [20260909154000_backoffice_sales_customer_receipt_runtime.sql](../../supabase/migrations/20260909154000_backoffice_sales_customer_receipt_runtime.sql) |
| 24 | [20260909155000_backoffice_sales_receipt_finance_posting.sql](../../supabase/migrations/20260909155000_backoffice_sales_receipt_finance_posting.sql) |

Postflight checkpoint:

- [backoffice_sales_customer_receipt_runtime_postflight.sql](../../supabase/diagnostics/backoffice_sales_customer_receipt_runtime_postflight.sql)

## Checkpoint C — Invoice/Finance foundation dan preview mode

8 file; nomor 25–32 dari90.

| No. | Migration (buka file lengkap) |
| --- | --- |
| 25 | [20260909156000_backoffice_sales_invoice_accounting_foundation.sql](../../supabase/migrations/20260909156000_backoffice_sales_invoice_accounting_foundation.sql) |
| 26 | [20260909157000_backoffice_sales_invoice_draft_runtime.sql](../../supabase/migrations/20260909157000_backoffice_sales_invoice_draft_runtime.sql) |
| 27 | [20260909158000_backoffice_sales_invoice_draft_digest_fix.sql](../../supabase/migrations/20260909158000_backoffice_sales_invoice_draft_digest_fix.sql) |
| 28 | [20260909159000_backoffice_sales_invoice_tax_breakdown.sql](../../supabase/migrations/20260909159000_backoffice_sales_invoice_tax_breakdown.sql) |
| 29 | [20260909160000_backoffice_sales_invoice_finance_mapping.sql](../../supabase/migrations/20260909160000_backoffice_sales_invoice_finance_mapping.sql) |
| 30 | [20260909161000_backoffice_sales_invoice_posting_runtime.sql](../../supabase/migrations/20260909161000_backoffice_sales_invoice_posting_runtime.sql) |
| 31 | [20260909162000_sales_process_cutover_foundation.sql](../../supabase/migrations/20260909162000_sales_process_cutover_foundation.sql) |
| 32 | [20260909163000_sales_process_cutover_preview_runtime.sql](../../supabase/migrations/20260909163000_sales_process_cutover_preview_runtime.sql) |

Postflight checkpoint:

- [backoffice_sales_invoice_posting_runtime_postflight.sql](../../supabase/diagnostics/backoffice_sales_invoice_posting_runtime_postflight.sql)
- [sales_process_cutover_preview_postflight.sql](../../supabase/diagnostics/sales_process_cutover_preview_postflight.sql)

## Checkpoint D — Cutover, warehouse stock-minus authority dan konversi

13 file; nomor 33–45 dari90.

| No. | Migration (buka file lengkap) |
| --- | --- |
| 33 | [20260910110000_sales_process_cutover_persistent_preview.sql](../../supabase/migrations/20260910110000_sales_process_cutover_persistent_preview.sql) |
| 34 | [20260910120000_sales_process_cutover_plan_refresh_cancel.sql](../../supabase/migrations/20260910120000_sales_process_cutover_plan_refresh_cancel.sql) |
| 35 | [20260910130000_sales_process_cutover_retail_identity.sql](../../supabase/migrations/20260910130000_sales_process_cutover_retail_identity.sql) |
| 36 | [20260910140000_sales_process_cutover_procurement_blocker.sql](../../supabase/migrations/20260910140000_sales_process_cutover_procurement_blocker.sql) |
| 37 | [20260910150000_backoffice_sales_delivery_fee_parity.sql](../../supabase/migrations/20260910150000_backoffice_sales_delivery_fee_parity.sql) |
| 38 | [20260910151000_backoffice_sales_delivery_fee_immutable_history_fix.sql](../../supabase/migrations/20260910151000_backoffice_sales_delivery_fee_immutable_history_fix.sql) |
| 39 | [20260910152000_sales_process_cutover_payment_term_boundary.sql](../../supabase/migrations/20260910152000_sales_process_cutover_payment_term_boundary.sql) |
| 40 | [20260910153000_unified_warehouse_negative_stock_authority.sql](../../supabase/migrations/20260910153000_unified_warehouse_negative_stock_authority.sql) |
| 41 | [20260911100000_sales_process_cutover_retail_to_backoffice_converter.sql](../../supabase/migrations/20260911100000_sales_process_cutover_retail_to_backoffice_converter.sql) |
| 42 | [20260911110000_sales_process_cutover_backoffice_to_retail_converter.sql](../../supabase/migrations/20260911110000_sales_process_cutover_backoffice_to_retail_converter.sql) |
| 43 | [20260911111000_sales_process_cutover_backoffice_to_retail_operation_audit_fix.sql](../../supabase/migrations/20260911111000_sales_process_cutover_backoffice_to_retail_operation_audit_fix.sql) |
| 44 | [20260911120000_sales_process_cutover_retail_session_adoption.sql](../../supabase/migrations/20260911120000_sales_process_cutover_retail_session_adoption.sql) |
| 45 | [20260911130000_sales_process_cutover_atomic_apply.sql](../../supabase/migrations/20260911130000_sales_process_cutover_atomic_apply.sql) |

Postflight checkpoint:

- [sales_process_cutover_atomic_apply_postflight.sql](../../supabase/diagnostics/sales_process_cutover_atomic_apply_postflight.sql)

## Checkpoint E — Office dispatch, pelunasan, discrepancy, reporting dan fix DP

29 file; nomor 46–74 dari90.

| No. | Migration (buka file lengkap) |
| --- | --- |
| 46 | [20260911140000_backoffice_sales_negative_dispatch_runtime.sql](../../supabase/migrations/20260911140000_backoffice_sales_negative_dispatch_runtime.sql) |
| 47 | [20260911150000_backoffice_sales_invoice_client_activation.sql](../../supabase/migrations/20260911150000_backoffice_sales_invoice_client_activation.sql) |
| 48 | [20260911160000_backoffice_sales_payment_collection_runtime.sql](../../supabase/migrations/20260911160000_backoffice_sales_payment_collection_runtime.sql) |
| 49 | [20260911161000_backoffice_sales_payment_account_mapping_fix.sql](../../supabase/migrations/20260911161000_backoffice_sales_payment_account_mapping_fix.sql) |
| 50 | [20260911162000_backoffice_sales_invoice_payment_ui_runtime.sql](../../supabase/migrations/20260911162000_backoffice_sales_invoice_payment_ui_runtime.sql) |
| 51 | [20260911163000_backoffice_sales_ar_reporting_integration.sql](../../supabase/migrations/20260911163000_backoffice_sales_ar_reporting_integration.sql) |
| 52 | [20260911164000_backoffice_sales_discrepancy_contract_foundation.sql](../../supabase/migrations/20260911164000_backoffice_sales_discrepancy_contract_foundation.sql) |
| 53 | [20260911165000_backoffice_sales_discrepancy_physical_state.sql](../../supabase/migrations/20260911165000_backoffice_sales_discrepancy_physical_state.sql) |
| 54 | [20260911166000_backoffice_sales_mixed_customer_receipt_runtime.sql](../../supabase/migrations/20260911166000_backoffice_sales_mixed_customer_receipt_runtime.sql) |
| 55 | [20260912100000_backoffice_sales_overage_commercial_approval.sql](../../supabase/migrations/20260912100000_backoffice_sales_overage_commercial_approval.sql) |
| 56 | [20260912110000_backoffice_sales_warehouse_resolution_foundation.sql](../../supabase/migrations/20260912110000_backoffice_sales_warehouse_resolution_foundation.sql) |
| 57 | [20260912120000_backoffice_sales_shortage_resolution_runtime.sql](../../supabase/migrations/20260912120000_backoffice_sales_shortage_resolution_runtime.sql) |
| 58 | [20260912121000_backoffice_sales_shortage_resolution_audit_fix.sql](../../supabase/migrations/20260912121000_backoffice_sales_shortage_resolution_audit_fix.sql) |
| 59 | [20260912122000_backoffice_sales_discrepancy_reconstruction_transfer.sql](../../supabase/migrations/20260912122000_backoffice_sales_discrepancy_reconstruction_transfer.sql) |
| 60 | [20260912123000_backoffice_sales_accepted_overage_invoice_line_foundation.sql](../../supabase/migrations/20260912123000_backoffice_sales_accepted_overage_invoice_line_foundation.sql) |
| 61 | [20260912124000_backoffice_sales_accepted_overage_invoice_runtime.sql](../../supabase/migrations/20260912124000_backoffice_sales_accepted_overage_invoice_runtime.sql) |
| 62 | [20260912125000_backoffice_sales_accepted_overage_invoice_client.sql](../../supabase/migrations/20260912125000_backoffice_sales_accepted_overage_invoice_client.sql) |
| 63 | [20260912130000_backoffice_sales_overage_wrong_item_resolution.sql](../../supabase/migrations/20260912130000_backoffice_sales_overage_wrong_item_resolution.sql) |
| 64 | [20260912131000_backoffice_sales_wrong_item_delivery_kind_fix.sql](../../supabase/migrations/20260912131000_backoffice_sales_wrong_item_delivery_kind_fix.sql) |
| 65 | [20260912132000_backoffice_sales_accepted_overage_finance_catalog_fix.sql](../../supabase/migrations/20260912132000_backoffice_sales_accepted_overage_finance_catalog_fix.sql) |
| 66 | [20260912133000_backoffice_sales_discrepancy_client_read_model.sql](../../supabase/migrations/20260912133000_backoffice_sales_discrepancy_client_read_model.sql) |
| 67 | [20260912134000_backoffice_sales_accepted_overage_finance_posting.sql](../../supabase/migrations/20260912134000_backoffice_sales_accepted_overage_finance_posting.sql) |
| 68 | [20260912135000_backoffice_sales_discrepancy_stock_loss_finance_posting.sql](../../supabase/migrations/20260912135000_backoffice_sales_discrepancy_stock_loss_finance_posting.sql) |
| 69 | [20260912136000_backoffice_sales_discrepancy_loss_movement_type_fix.sql](../../supabase/migrations/20260912136000_backoffice_sales_discrepancy_loss_movement_type_fix.sql) |
| 70 | [20260912137000_backoffice_sales_accepted_overage_ledger_split_fix.sql](../../supabase/migrations/20260912137000_backoffice_sales_accepted_overage_ledger_split_fix.sql) |
| 71 | [20260912138000_backoffice_sales_delivered_not_invoiced_report.sql](../../supabase/migrations/20260912138000_backoffice_sales_delivered_not_invoiced_report.sql) |
| 72 | [20260912139000_backoffice_sales_system_customer_payment_fix.sql](../../supabase/migrations/20260912139000_backoffice_sales_system_customer_payment_fix.sql) |
| 73 | [20260912140000_backoffice_sales_order_invoice_status.sql](../../supabase/migrations/20260912140000_backoffice_sales_order_invoice_status.sql) |
| 74 | [20260915100000_backoffice_invoice_dp_empty_overage_forward_fix.sql](../../supabase/migrations/20260915100000_backoffice_invoice_dp_empty_overage_forward_fix.sql) |

Postflight checkpoint:

- [backoffice_sales_order_invoice_status_postflight.sql](../../supabase/diagnostics/backoffice_sales_order_invoice_status_postflight.sql)
- [backoffice_invoice_dp_empty_overage_postflight.sql](../../supabase/diagnostics/backoffice_invoice_dp_empty_overage_postflight.sql)

## Checkpoint F — Purchase foundation dan kandidat RO/PO

2 file; nomor 75–76 dari90.

| No. | Migration (buka file lengkap) |
| --- | --- |
| 75 | [20260913100000_purchase_daily_replenishment_foundation.sql](../../supabase/migrations/20260913100000_purchase_daily_replenishment_foundation.sql) |
| 76 | [20260913110000_purchase_daily_replenishment_candidate_preview.sql](../../supabase/migrations/20260913110000_purchase_daily_replenishment_candidate_preview.sql) |

Postflight checkpoint:

- [purchase_daily_replenishment_candidate_preview_postflight.sql](../../supabase/diagnostics/purchase_daily_replenishment_candidate_preview_postflight.sql)

## Checkpoint G — Dependency Receipt, RO/PO, AP, scheduler dan revisi PO

13 file; nomor 77–89 dari90.

| No. | Migration (buka file lengkap) |
| --- | --- |
| 77 | [20260825131000_backoffice_goods_receipt_workspace_line_no_fix.sql](../../supabase/migrations/20260825131000_backoffice_goods_receipt_workspace_line_no_fix.sql) |
| 78 | [20260913120000_purchase_daily_auto_ro_runtime.sql](../../supabase/migrations/20260913120000_purchase_daily_auto_ro_runtime.sql) |
| 79 | [20260913130000_purchase_daily_auto_po_runtime.sql](../../supabase/migrations/20260913130000_purchase_daily_auto_po_runtime.sql) |
| 80 | [20260914100000_purchase_daily_multiwarehouse_receipt.sql](../../supabase/migrations/20260914100000_purchase_daily_multiwarehouse_receipt.sql) |
| 81 | [20260914110000_purchase_auto_po_receipt_warehouse_boundary_fix.sql](../../supabase/migrations/20260914110000_purchase_auto_po_receipt_warehouse_boundary_fix.sql) |
| 82 | [20260914111000_purchase_auto_po_destination_filter_fix.sql](../../supabase/migrations/20260914111000_purchase_auto_po_destination_filter_fix.sql) |
| 83 | [20260914112000_purchase_supplier_order_unset_destination.sql](../../supabase/migrations/20260914112000_purchase_supplier_order_unset_destination.sql) |
| 84 | [20260914130000_purchase_supplier_assignment_ap_bridge.sql](../../supabase/migrations/20260914130000_purchase_supplier_assignment_ap_bridge.sql) |
| 85 | [20260914140000_purchase_daily_scheduler_cancellation_runtime.sql](../../supabase/migrations/20260914140000_purchase_daily_scheduler_cancellation_runtime.sql) |
| 86 | [20260914141000_purchase_daily_scheduler_midnight_window_fix.sql](../../supabase/migrations/20260914141000_purchase_daily_scheduler_midnight_window_fix.sql) |
| 87 | [20260914150000_purchase_daily_client_workspace.sql](../../supabase/migrations/20260914150000_purchase_daily_client_workspace.sql) |
| 88 | [20260914160000_purchase_order_list_parity_read_model.sql](../../supabase/migrations/20260914160000_purchase_order_list_parity_read_model.sql) |
| 89 | [20260914170000_purchase_order_pre_receipt_revision.sql](../../supabase/migrations/20260914170000_purchase_order_pre_receipt_revision.sql) |

Postflight checkpoint:

- [purchase_order_document_revision_postflight.sql](../../supabase/diagnostics/purchase_order_document_revision_postflight.sql)

Sebelum nomor90: jalankan [preflight generated Receipt production](../../supabase/diagnostics/purchase_order_generated_receipt_production_preflight.sql) dan [discovery ulang](../../supabase/diagnostics/office_purchase_production_discovery_preflight.sql). Simpan exact kandidat PO/Gudang dan baseline Draft. Jangan menghapus39 Draft existing. Jangan memakai preflight behavioral Development yang meminta fixture pada Production.

## Checkpoint H — Generated Receipt dan penutupan database

1 file; nomor 90–90 dari90.

| No. | Migration (buka file lengkap) |
| --- | --- |
| 90 | [20260914180000_purchase_order_generated_receipt_workflow.sql](../../supabase/migrations/20260914180000_purchase_order_generated_receipt_workflow.sql) |

Postflight checkpoint:

- [purchase_order_generated_receipt_workflow_postflight.sql](../../supabase/diagnostics/purchase_order_generated_receipt_workflow_postflight.sql)
- [office_purchase_clone_closing_ledger.sql](../../supabase/diagnostics/office_purchase_clone_closing_ledger.sql)

## Penutupan — jangan aktifkan mode bersamaan dengan deploy

1. Semua89 candidate versions +2extras harus ada di ledger; closing check4PASS.
2. Jalankan fingerprint17 tabel ulang selama mutation masih berhenti. Kolom
   additive/default dapat mengubah full-row digest: review field-level existing
   ID/nomor/qty/nilai/status yang harus tetap; jangan mengharapkan whole-row hash
   identik bila schema berubah. Bedakan backfill additive yang disebut migration.
3. Generated Receipt dapat menambah/cancel placeholder Draft sesuai sync function;
   bandingkan candidate/effect perPO/Gudang. Tidak boleh mengubah Posted Receipt/
   Movement/FIFO/AP/Journal hanya karena backfill. Simpan before/after exact set.
4. Retail default tetap Retail; Purchase tetap MANUAL. Jangan menjalankan cutover
   Apply atau generator otomatis sebagai bagian instalasi. pg_cron disiapkan oleh
   migration; jika extension/policy project menolak, STOP dan kirim error.
5. Deploy Backoffice/PWA dari source yang sesuai menggunakan Production env yang
   benar, bukan build clone. Client deployment/commit/push tidak dijalankan agent.
6. Authenticated smoke Retail lalu Office/Purchase/Finance; termasuk payment,
   partial/full Receipt, role denial, retry/stale/bulk partial success dan tracing.
   Baru buka operasional/aktivasi pilot setelah checkpoint dan regression lulus.

## Error, retry, rollback

Satu migration gagal sebelum COMMIT: periksa transaksi/ledger; jangan asumsikan
seluruh90 file atomic, karena masing-masing punya transaction sendiri. Versi yang
sudah committed tetap terpasang. Jangan drop schema/ledger atau restore database
menimpa transaksi baru tanpa recovery plan. Utamakan audited additive forward-fix;
backup restore adalah operasi recovery terpisah dengan persetujuan eksplisit.
Tidak otomatis rollback ke client lama bila RPC yang dipakai telah berubah;
verifikasi compatibility sebelum membuka kembali operasional.

## Evidence dan sisa gate

Checksum/coverage/link validation untuk paket dilakukan lokal; migration tidak
rerun pada clone final atau Production. Bukti database/behavioral menggunakan
[report rehearsal](OFFICE_PURCHASE_CLONE_REHEARSAL_FINAL_REPORT.md) dan
[review delta Production](../audits/OFFICE_PURCHASE_PRODUCTION_DELTA_REVIEW_2026-09-15.md).
Status berbeda: SOURCE/PACKAGE READY; CLONE DB/SQL PASS; PRODUCTION DB, CLIENT,
authenticated SMOKE dan UAT menunggu bukti eksekusi masing-masing.
