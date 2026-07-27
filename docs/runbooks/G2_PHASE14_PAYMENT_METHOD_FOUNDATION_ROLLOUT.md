# G2 Phase 14 — Payment Method Foundation Rollout

## Outcome

Menambahkan master Payment Method tenant-scoped, assignment Store, konfigurasi
fee, default Tunai, version/audit, guarded RPC, serta kolom snapshot nullable
pada `sales_payments` tanpa memindahkan checkout lama.

## Urutan manual

Catatan rollout 2026-07-22: percobaan pertama berhenti dengan PostgreSQL
`55006 cannot ALTER TABLE ... pending trigger events`. Transaction migration
rollback penuh. File migration sekarang memaksa validasi event deferred setelah
backfill default dan sebelum RLS `ALTER TABLE`; rerun seluruh file terbaru.

1. Jalankan
   `supabase/migrations/20260722120000_g2_phase14_payment_method_foundation.sql`.
2. Jalankan
   `supabase/diagnostics/g2_phase14_payment_method_foundation_postflight.sql`.
   Expected: **13 PASS**.
3. Jalankan
   `supabase/tests/g2_phase14_payment_method_foundation_tests.sql`.
   Expected notice: `TEST PASSED`.
4. Restart Backoffice lalu buka seluruh menu existing untuk compatibility smoke.

## Yang diverifikasi

- setiap Company aktif memiliki tepat satu default Payment Method aktif;
- default awal adalah `Tunai`, berlaku seluruh Store;
- kode/nama unik per Company;
- assignment Store tidak dapat lintas Company;
- fee percent/fixed/gabungan dan penanggung fee konsisten;
- Customer Balance/Ketul Offset tidak dapat dibuat lewat custom RPC;
- kode yang sudah dipakai tidak dapat diubah;
- direct browser mutation tertutup dan perubahan diaudit;
- enum serta kolom legacy checkout tetap tersedia.

## Compatibility boundary

- `sales_payments.payment_method` enum lama tidak dihapus atau diwajibkan
  memakai master pada fase ini.
- Kolom snapshot canonical nullable; tidak ada rewrite histori karena preflight
  mengonfirmasi zero Sales Payment.
- Checkout, split-payment calculation, resolver fee, offline payment,
  settlement, reconciliation, dan Finance posting tetap deferred ke G4/G6.
- Foundation menyimpan current configured fee pada master. Effective-dated
  Store-specific fee override dan precedence resolver masih menjadi gap G4 dan
  wajib selesai sebelum checkout canonical diaktifkan.
- Account function hanya disimpan sebagai canonical function key; FK ke COA
  menunggu Finance/COA foundation.

## Forward-fix / rollback

Migration berada dalam satu transaction dan rollback otomatis bila guard/DDL
gagal sebelum `COMMIT`. Setelah master dipakai, jangan drop tabel atau kolom;
gunakan forward migration. Jika UI berikutnya bermasalah, master tetap aman dan
checkout legacy tetap berjalan karena belum dicutover.
