# G3 Phase 1 - Opening Stock Foundation Rollout

## Outcome

Membuka workflow database Opening Stock canonical tanpa membuka UI atau journal
posting. Dokumen dapat disimpan sebagai Draft dan diposting melalui guarded RPC.

Posting berhasil membentuk secara atomic:

- `OPENING_BALANCE` pada immutable `stock_movements`;
- saldo aktual Base UOM pada `product_stocks`;
- FIFO opening layer pada `product_batches`;
- event Finance `STOCK_OPENING` berstatus `HOLD`;
- snapshot Product/UOM/cost serta audit actor/waktu.

## Boundary

- Store Manager sesuai Store dan Finance/Accounting dapat menyiapkan Draft.
- Company Owner/Admin dan Super Admin dapat posting.
- Browser tidak mendapat direct write ke document, line, balance, movement,
  batch, atau Finance event.
- Opening Stock hanya sah jika pasangan Product-Gudang belum memiliki movement.
- Quantity selalu Base UOM dan mengikuti precision UOM.
- HPP nol diperbolehkan hanya dengan alasan eksplisit.
- Event Finance tetap `HOLD`; migration ini tidak membuat jurnal.

## Urutan Manual

Jalankan satu per satu di Supabase SQL Editor.

### 1. Migration

```text
supabase/migrations/20260728120000_g3_phase1_opening_stock_foundation.sql
```

Expected: sukses tanpa result error.

### 2. Postflight

```text
supabase/diagnostics/g3_phase1_opening_stock_postflight.sql
```

Expected: seluruh row `PASS` dengan `violation_rows = 0`.

### 3. Behavioral test

```text
supabase/tests/g3_phase1_opening_stock_tests.sql
```

Expected notice:

```text
TEST PASSED: Opening Stock is tenant-safe, atomic, FIFO-backed, idempotent, audited, and rejects prior movement.
```

Test dibungkus `BEGIN ... ROLLBACK`; fixture dan seluruh mutation test tidak
menetap.

### 4. Compatibility regression

Jalankan ulang:

```text
supabase/tests/g2_phase46_product_warehouse_minimum_stock_tests.sql
supabase/tests/g2_phase44_product_supplier_import_tests.sql
supabase/tests/g1_security_closure_tests.sql
```

Expected: seluruh behavioral test PASS.

## Hasil Operasional Setelah Rollout

Schema/RPC sudah tersedia, tetapi Backoffice belum memiliki menu Opening Stock.
Jangan mengisi `product_stocks` secara manual. UI berikutnya harus memakai:

```text
save_opening_stock_document(...)
post_opening_stock(...)
```

Setelah database gate lulus, tahap berikutnya adalah guarded API/UI Opening
Stock dan smoke satu Product-Gudang. Smoke harus membuktikan saldo aktual,
movement, FIFO layer, dan status low-stock terbaca konsisten.

## Rollback dan Forward Fix

Migration transactional: error sebelum `COMMIT` mengembalikan schema ke kondisi
awal. Setelah migration applied tetapi belum ada dokumen posted, rollback
terkontrol masih dapat dirancang dengan menghapus object baru dalam urutan FK.

Setelah ada Opening Stock `POSTED`, jangan drop table, enum, movement, batch,
balance, atau event. Gunakan forward-fix. Koreksi business stock berikutnya
harus memakai Adjustment/reversal yang dibuka pada gate G3 berikutnya, bukan
edit/delete histori.
