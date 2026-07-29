# G3 Phase 8 — Stock Adjustment Preflight

## Status

`READY FOR MANUAL PREFLIGHT`

## Alasan urutan

Roadmap G3 dilanjutkan ke Stock Adjustment sebelum Stock Opname. Adjustment
adalah dokumen koreksi stok langsung, sedangkan Posting Stock Opname nantinya
membuat Adjustment otomatis untuk line yang memiliki selisih. Menyiapkan
Adjustment lebih dahulu mencegah Opname membuat jalur mutation stok kedua yang
berbeda.

## Scope preflight

Jalankan seluruh file:

`supabase/diagnostics/g3_phase8_stock_adjustment_preflight.sql`

Diagnostic ini hanya membaca:

- dependency canonical Transfer;
- histori `stock_adjustments` legacy dan hubungan movement-nya;
- kelengkapan snapshot canonical Movement;
- rekonsiliasi `product_stocks` terhadap movement dan FIFO;
- Base UOM Product aktif;
- kategori `STOCK_GAIN`/`STOCK_LOSS`;
- akun/fallback `INVENTORY_ASSET`, `STOCK_GAIN_INCOME`, dan
  `STOCK_LOSS_EXPENSE`;
- reason backfill scope;
- browser direct-write boundary;
- gap tabel/RPC canonical.

File tidak membuat alasan Adjustment, dokumen, saldo, FIFO, movement, event,
jurnal, trigger, policy, atau grant.

## Expected result

- seluruh `BLOCKER` harus `PASS`;
- `legacy_adjustment_without_movement`,
  `legacy_adjustment_movement_without_source`, atau incomplete snapshot dapat
  berstatus `REVIEW/BACKFILL` hanya jika benar-benar ada histori legacy;
- `legacy_adjustment_reason_backfill_scope = BACKFILL` berarti alasan free-text
  existing perlu dipetakan secara eksplisit ke master reason;
- `canonical_stock_adjustment_schema_state = INFO` dan missing canonical tables
  adalah expected sebelum migration;
- seluruh direct browser write idealnya `false`.

Kirim seluruh output tanpa dipotong. Migration tidak dibuat berdasarkan
asumsi jika terdapat `BLOCKER`, histori legacy, ambiguity source, atau reason
yang membutuhkan keputusan mapping.

## Target contract setelah preflight bersih

- master alasan reusable per Company;
- `DRAFT -> POSTED` atau `DRAFT -> CANCELED`;
- user mengisi stok akhir/fisik, bukan angka plus/minus;
- server menyimpan system snapshot dan menghitung difference;
- loss mengonsumsi FIFO aktual; gain membentuk layer dengan cost snapshot yang
  dapat diaudit;
- Posting atomic terhadap balance, FIFO, immutable movement, event Finance
  `HOLD`, audit, idempotency, dan row lock;
- Store Manager hanya dalam assignment Gudang store; Company Owner/Admin dan
  Super Admin dalam Company scope; Warehouse Admin tidak dapat Posting;
- posted document immutable.

## Boundary

- belum membuat UI/API Adjustment;
- belum membuka Stock Opname, POS blind count, atau recount;
- belum membuat jurnal final;
- G4 notification dan G5 Purchasing tetap tertutup.
