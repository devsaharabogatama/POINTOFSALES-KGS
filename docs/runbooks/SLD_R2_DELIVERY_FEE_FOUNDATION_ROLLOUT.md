# SLD-R2 Delivery Fee Foundation Rollout

**Status:** LOCAL-READY; manual Supabase rollout pending  
**Migration:** `20260811140000_sld_r2_delivery_fee_finance_foundation.sql`

Catatan koreksi: eksekusi pertama user rollback pada statement ledger karena
kolom lokal salah `name/description`. File sekarang memakai contract canonical
`migration_name/notes`; jalankan ulang file migration lengkap dari awal.

## Outcome

SLD-R2 menambahkan ongkir Customer sebagai nilai server-authoritative yang:

- hanya valid untuk `DELIVERY`;
- ditambahkan sekali setelah Product rounding;
- ikut grand total, Payment, TEMPO, Customer Balance, dan replay Offline melalui
  jalur Draft/Post canonical yang sama;
- tersimpan pada receipt, Sales Invoice snapshot, dan `SALE_POSTED.amounts`;
- dipisahkan dari `netSalesInclusiveTax` sebagai `deliveryFee`;
- mempunyai account function, COA sistem Company, dan fallback mapping
  `DELIVERY_FEE_REVENUE`.

Tidak ada pajak ongkir implisit. Biaya kurir aktual tetap Expense terpisah.
Snapshot/Event historis tidak ditulis ulang. Return produk parsial juga tidak
otomatis mengembalikan ongkir.

## Urutan Eksekusi

1. Pastikan output `sld_r1_delivery_fee_preflight.sql` tidak mempunyai
   `BLOCKER`.
2. Jalankan migration foundation:
   `supabase/migrations/20260811140000_sld_r2_delivery_fee_finance_foundation.sql`.
3. Jalankan forward fix mandatory POST repricing:
   `supabase/migrations/20260811143000_sld_r2_post_reprice_delivery_fee_fix.sql`.
   File ini wajib karena behavioral pertama membuktikan POST core melakukan
   repricing ulang dan sempat mereset total fee sebelum Payment validation.
4. Jalankan postflight:
   `supabase/diagnostics/sld_r2_delivery_fee_postflight.sql`.
5. Semua row `FAIL` wajib nol. Row `DEFERRED` Finance Sale posting masih
   expected karena engine G6 live saat ini baru mem-post Stock Opening;
   `SALE_POSTED` tetap `HOLD` dan tidak diproses diam-diam.
6. Jalankan rollback-safe behavior:
   `supabase/tests/sld_r2_delivery_fee_tests.sql`.
7. Rerun postflight dan regression:
   - `supabase/tests/sld_phase2_sales_document_tests.sql`;
   - G4 Phase-56 Customer Balance behavior;
   - G4 Phase-8 split-payment behavior;
   - G4 Phase-12 Offline sync behavior;
   - G1 security closure.

## Expected Evidence

- Pickup dengan ongkir ditolak `PICKUP_DELIVERY_FEE_NOT_ALLOWED`.
- Delivery Product 100 + ongkir 25 menghasilkan total 125.
- Save Draft kedua tetap total 125, bukan 150.
- Payment/receivable merekonsiliasi 125.
- Invoice dan receipt menyimpan 25 serta display mode.
- Event menyimpan `netSalesInclusiveTax=100`, `deliveryFee=25`,
  `grandTotal=125`.
- satu active Company mempunyai tepat satu active mapping pendapatan ongkir.
- browser tidak memperoleh direct write ke Sale.

## Compatibility dan Forward Fix

- Payload lama: `PICKUP`, fee `0`, mode `SHOW_SEPARATE`.
- Existing Invoice/Event immutable tetap tanpa key ongkir; kolom Sale lama
  terisi nol melalui default additive.
- Jangan mengedit migration bila sudah dijalankan. Jika rollout gagal setelah
  commit, buat forward migration baru.
- Sebelum commit, rollback transaksi migration aman karena seluruh DDL/DML
  berada dalam satu transaksi.

## Sisa Gate

- SLD-R3: confirmation UI, Customer autofill, display toggle, Offline restore,
  dan printable Invoice/SJ.
- SLD-R4: explicit full-return delivery-fee refund + closing regression.
- G6 Sale posting: resolver/rule lengkap sebelum Event Sale HOLD boleh dijurnal.
