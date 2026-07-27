# G2 Phase 36 — Automatic Hidden Master Codes Rollout

## Status

`COMPLETE`

## Outcome

Membuat kode teknis otomatis untuk delapan master tanpa mengganti UUID,
menulis ulang 41 kode existing, atau memutus Import/Export empat master lama.

## Files

1. Migration:
   `supabase/migrations/20260724010000_g2_phase36_automatic_master_codes.sql`
2. Postflight:
   `supabase/diagnostics/g2_phase36_automatic_master_codes_postflight.sql`
3. Behavioral test:
   `supabase/tests/g2_phase36_automatic_master_codes_tests.sql`

## Rollout Order

Jalankan satu per satu di Supabase SQL Editor:

1. seluruh migration;
2. seluruh postflight;
3. seluruh behavioral test.

Expected:

- migration sukses satu kali;
- 11 postflight row seluruhnya `PASS`, `violation_rows=0`;
- behavioral test menghasilkan notice:
  `TEST PASSED: codes auto-generate per Company...`;
- seluruh fixture/counter test rollback.

Kirim output postflight lengkap dan notice behavioral test.

## Compatibility

- UUID dan semua kode existing dipertahankan;
- explicit-code RPC signature lama tetap tersedia untuk import engine applied;
- form/API lama masih dapat create dengan explicit code selama window rollout;
- update yang mengirim kode existing yang sama tetap bekerja;
- perubahan kode existing ditolak `SYSTEM_CODE_IMMUTABLE`;
- Product SKU, Customer code, COA, Tax, barcode, dan vendor Product code tidak
  berubah;
- tidak ada stock, transaction, checkout, payment snapshot, atau journal yang
  ditulis migration.

User mengonfirmasi migration, 11-check postflight, dan behavioral test seluruhnya
PASS. Backoffice kemudian dipindahkan ke overload tanpa kode melalui Phase 37.
Template CSV create lama tetap kompatibel sampai full-import gate berikutnya.

## Concurrency and Failure

Allocator memakai atomic `INSERT ... ON CONFLICT DO UPDATE` pada satu counter
per Company/entity. Dua create concurrent tidak menerima nomor yang sama.
Allocation berada dalam transaction create; create gagal juga me-rollback
counter. Gap nomor akibat transaction committed lalu business row dinonaktifkan
tetap diperbolehkan dan nomor tidak digunakan ulang.

## Rollback / Forward-fix

Migration satu transaction. Error sebelum `COMMIT` me-rollback table, routine,
trigger, grant, dan ledger row. Setelah applied:

- jangan edit atau rerun migration;
- hentikan UI cutover jika regression ditemukan;
- buat forward migration;
- jangan menurunkan counter atau menggunakan ulang kode yang sudah pernah
  dialokasikan.

## Manual Compatibility Smoke

Smoke UI setelah cutover mengikuti
`G2_PHASE37_AUTOMATIC_MASTER_CODE_UI_CUTOVER.md`.
