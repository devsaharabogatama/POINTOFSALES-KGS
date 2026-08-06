# G4 Phase 26 — Sales Return Foundation Rollout

**Status:** READY FOR MANUAL DATABASE ROLLOUT

Foundation ini membuka canonical Sales Return server-side. UI Return belum
dibuka pada fase ini.

## Kontrak

- source wajib Sale `POSTED` dan seluruh nilai memakai snapshot Sale asal;
- cumulative returned quantity tidak boleh melewati source line;
- `SALEABLE` memulihkan FIFO ke Gudang penjualan asal;
- `DAMAGED` memerlukan Gudang DAMAGED aktif;
- `NO_PHYSICAL_RETURN` tidak membuat batch, stock, Movement, atau pembalikan
  HPP;
- refund hanya Cash/Transfer pada boundary ini; Customer Balance dan TEMPO
  tetap tertutup;
- total refund harus sama persis dengan refund server, full Return membalik
  remaining total final Sale, partial Return memakai rounding tersendiri;
- default approval tetap `REQUIRED`: Kasir dapat membuat Draft, hanya Company
  Owner/Admin atau Store Manager pada Store terkait yang dapat posting;
- posting atomic, idempotent, immutable, audited, memperbarui expected Cash
  Session, serta menghasilkan Financial Event `HOLD` untuk G6;
- browser tidak memperoleh direct table write.

## Urutan Eksekusi

1. Pastikan hasil Phase-25 tidak mempunyai `BLOCKER`.
2. Jalankan seluruh migration:
   `supabase/migrations/20260803010000_g4_phase26_sales_return_foundation.sql`.
3. Jalankan seluruh postflight:
   `supabase/diagnostics/g4_phase26_sales_return_foundation_postflight.sql`.
4. Hanya jika seluruh check selain inventory `INFO` berstatus `PASS`, jalankan
   behavioral test rollback-safe:
   `supabase/tests/g4_phase26_sales_return_foundation_tests.sql`.
5. Jalankan regression:
   - `supabase/diagnostics/g4_phase10_online_checkout_stress_preflight.sql`;
   - `supabase/diagnostics/g3_phase14_inventory_core_exit_preflight.sql`;
   - `supabase/tests/g1_security_closure_tests.sql`.

### Forward fix Return batch lineage

Behavioral run pertama setelah migration live dapat berhenti pada constraint
`product_batches_transfer_lineage_check`. Test tetap rollback-safe. Penyebabnya
adalah `source_batch_id` historis hanya mengizinkan lineage Transfer, sedangkan
Return juga wajib menunjuk FIFO batch asal.

Jika migration utama sudah applied, jalankan satu kali:

1. `supabase/migrations/20260803020000_g4_phase26_sales_return_batch_lineage_fix.sql`;
2. `supabase/diagnostics/g4_phase26_sales_return_batch_lineage_fix_postflight.sql`;
3. setelah seluruh postflight fix `PASS`, rerun behavioral test Phase-26.

Forward fix membuat lineage Transfer dan Return mutually exclusive; ordinary,
Opening, Adjustment, dan Purchase batch tetap wajib tanpa `source_batch_id`.

Jangan rerun migration setelah ledger `20260803010000` tercatat. Jika migration
gagal, kirim error pertama lengkap dan jangan menjalankan postflight/test.

## Expected

- migration sukses satu kali;
- seluruh postflight `PASS`, inventory `INFO` boleh nol;
- behavioral test menghasilkan notice `TEST PASSED` lalu `ROLLBACK`;
- seluruh regression tetap bersih;
- data Sale/Stock aktual tidak berubah karena behavioral fixture di-rollback.

## Compatibility dan Deferred

- Sale/Payment/FIFO/receipt existing tidak diubah;
- Cash refund mulai ikut perhitungan expected drawer Cash;
- Return UI, approval policy `OPTIONAL`, Customer Balance refund, Transfer
  evidence UX, laporan Return, Finance journal/GL, Credit Note, dan Purchase
  Return belum dibuka;
- forward fix wajib migration baru; migration ini jangan diedit setelah applied.
