# Backoffice Sales Discrepancy Physical-State Rollout — Step 4/6.2

Status: **LOCAL READY; MANUAL ISOLATED DEVELOPMENT ROLLOUT PENDING**  
Target tunggal: Supabase Development `fkywtxucmyjvpwdiqpix`  
Production `nbxjslqojexjfogamnjt` dan staging lama `yjxpddwrjdczuqyix`: **DILARANG**

## Outcome

Forward migration ini memperbaiki kontrak Step 4/6.1 tanpa mengedit migration
yang sudah applied:

- keputusan komersial kekurangan tetap `BACKORDER` atau `ACCEPT_SHORT`;
- kondisi fisik quantity kurang wajib dicatat terpisah sebagai `NOT_LOADED`,
  `RETURNING`, `LOST`, atau `DAMAGED`;
- `WRONG_ITEM` menyimpan Product, UOM, qty UOM, dan qty base aktual secara
  terpisah dari quantity Product yang seharusnya diterima;
- setiap shortage tetap membutuhkan penyelesaian Gudang karena quantity sudah
  berada pada lineage Dispatch/Transit;
- clean receipt lima-argumen tetap tersedia dan tidak berubah.

Paket ini belum membuka mixed Customer Receipt, Stock correction, Backorder
DO/SJ, approval UI, write-off, atau Finance queue.

## Impact map

- Direct: empat kolom dan constraint pada
  `backoffice_sales_delivery_discrepancy_lines`; overload classifier tiga
  argumen; validator payload diperketat.
- Downstream: Step 4/6.3 wajib memakai dua fakta shortage tersebut saat
  menentukan Transit -> Customer, Transit -> Gudang, Backorder, atau exception.
- Tidak berubah: POS Retail, clean Customer Receipt, DO/Reservation aktif,
  Stock/FIFO/Movement, Invoice, Payment, session Kasir, Finance, dan dokumen lama.
- Concurrency/idempotency: belum ada mutation operasional baru. Migration
  menolak seluruh row discrepancy existing agar tidak mengarang backfill.
- Rollback: setelah applied, jangan drop kolom/constraint. Gunakan forward-fix.
  Sebelum applied, rollback cukup tidak menjalankan migration.

## Urutan manual

Jalankan setiap file secara utuh di SQL Editor project Development:

1. `supabase/diagnostics/backoffice_sales_discrepancy_physical_state_preflight.sql`
2. `supabase/migrations/20260911165000_backoffice_sales_discrepancy_physical_state.sql`
3. `supabase/diagnostics/backoffice_sales_discrepancy_physical_state_postflight.sql`
4. `supabase/tests/backoffice_sales_discrepancy_physical_state_behavior.sql`
5. ulangi postflight nomor 3.

Stop pada SQL error, `BLOCKER`, atau `FAIL`. `INFO` bukan bukti behavior.

## Expected evidence

- Preflight seluruh check operasional `PASS`.
- Migration commit dan ledger tepat satu row.
- Postflight seluruh check selain inventory `PASS`.
- Behavioral menghasilkan tepat satu row `PASS` dan tidak menyisakan data.
- Authenticated smoke belum berlaku karena UI/runtime mixed receipt belum dibuka.

## Next safe step

Setelah seluruh output di atas PASS, Step 4/6.3 dapat menambahkan mixed
Customer Receipt atomik yang mengonsumsi hanya accepted qty dari Transit,
membuka Qty To Invoice segera, dan mempertahankan discrepancy fisik yang belum
selesai tanpa menggandakan Stock/COGS.

