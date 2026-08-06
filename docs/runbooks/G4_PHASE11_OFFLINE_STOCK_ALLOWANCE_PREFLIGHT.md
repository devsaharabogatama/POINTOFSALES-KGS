# G4 Phase 11 — Offline Stock Allowance Preflight

## Tujuan

Preflight ini mengaudit kesiapan fondasi transaksi offline sebelum schema,
reservation, queue, endpoint sync, atau UI offline dibuka. File ini tidak
mengubah database.

Phase 11 tetap berada dalam roadmap G4. Return, TEMPO, Customer Balance,
Expense, Deposit, Ketul, Purchase, dan Finance posting tidak ikut dibuka.

## Kontrak yang sedang dipersiapkan

- Offline sale fisik hanya boleh dibuat bila Company memiliki entitlement
  `offline_pos_enabled` dan Terminal/Session mempunyai allowance aktif.
- Allowance dicatat per Company, Store, Gudang, Terminal, Session, Product, dan
  Base UOM. Allowance adalah reservation; ia tidak mengubah on-hand atau
  membuat Stock Movement.
- Default allowance adalah 20% dari available-unreserved stock, dibulatkan
  sesuai precision Base UOM; untuk UOM integer minimal satu bila stok tersedia.
- Total allowance aktif tidak boleh melebihi available-unreserved stock.
- Sale lokal memakai `client_transaction_id` dan idempotency key stabil,
  mengurangi allowance lokal secara atomik, lalu berstatus `QUEUED`.
- Sync server mengunci allowance, Sale, stok, dan FIFO; satu payload hanya boleh
  menghasilkan satu invoice, Payment, Movement, allocation, dan Financial
  Event.
- Payload lokal tidak boleh dihapus sebelum acknowledgement server tersimpan.
- Tanpa allowance, PWA hanya boleh menyimpan Draft; barang/pembayaran tidak
  boleh diserahterimakan.
- Offline tidak membuka Customer Balance, TEMPO, Ketul, Return, Goods Receipt,
  atau Adjustment.

## Cara menjalankan

1. Buka Supabase SQL Editor pada environment aktif.
2. Jalankan seluruh
   `supabase/diagnostics/g4_phase11_offline_stock_allowance_preflight.sql`.
3. Ekspor atau salin seluruh hasil `check_name,status,details`.
4. Jangan mengaktifkan `offline_pos_enabled` dan jangan menjalankan endpoint
   sync lama.

## Interpretasi

- `BLOCKER`: harus diselesaikan sebelum migration Phase 11 ditulis/applied.
- `SETUP`: schema offline memang belum ada dan akan dibuat setelah preflight
  disetujui.
- `PASS`: invariant existing aman.
- `INFO`: inventory/readiness, bukan kegagalan.

`enabled_offline_entitlement_without_foundation` wajib `PASS`. Jika `BLOCKER`,
nonaktifkan entitlement melalui workflow Super Admin yang sudah diaudit sebelum
rollout. Jangan mengubah `company_features` langsung.

`canonical_offline_schema_state = SETUP` adalah hasil yang diharapkan pada
baseline saat ini. Endpoint `/api/pos/sync` juga tetap wajib mengembalikan
`OFFLINE_SYNC_NOT_ENABLED` sampai migration, behavioral test, dan PWA queue
selesai.

## Forward-fix / rollback note

Belum ada mutation pada tahap ini sehingga rollback tidak diperlukan. Setelah
hasil live diterima, next safe step adalah merancang migration additive untuk
policy, allowance reservation, audit, dan submission envelope. Queue PWA dan
sync posting baru boleh dibuka pada fase sesudah server invariant tersebut
lulus.
