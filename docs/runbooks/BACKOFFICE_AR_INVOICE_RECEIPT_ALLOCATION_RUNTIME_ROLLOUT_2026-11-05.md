# Backoffice AR Invoice/Receipt Allocation Runtime — Rollout 2026-11-05

Status: **DATABASE LIVE / FIRST+CLOSING POSTFLIGHT PASS / ROLLBACK BEHAVIOR PASS / CLIENT NOT DEPLOYED / SMOKE+UAT PENDING**.

First execution failed on PostgreSQL `42601` and rolled back. Repeated full
production preflight proves `FOUNDATION_INSTALLED_TASK3_NOT_INSTALLED`, Task 3
ledger absent, and unchanged active anchors. The never-live candidate was then
corrected in-place: two invalid composite multi-target `INTO` statements now
select only the required Journal and Journal Line UUID values. Do not reuse the
first candidate checksum; the corrected checksum is
`9f72544a0b7356a32212e903cce1d9512462fc7b23fcd5d6c2f6d4003dc3c690`.

Production rollout kemudian selesai: ledger tepat satu, runtime wrapper lengkap,
registry 535 Invoice / 313 Receipt tetap exact, 380 allocation tidak mismatch
atau over-allocated, rollback behavior PASS, dan closing postflight kembali
PASS. Migration ini sekarang immutable dan tidak boleh dijalankan atau diedit
ulang. Client belum deployed; authenticated smoke dan UAT masih gate terpisah.

## Outcome bisnis

- Finance memilih alokasi Receipt ke Invoice secara manual.
- Nominal diterima boleh lebih besar dari total alokasi untuk Invoice
  Backoffice. Selisih menjadi kredit terbuka milik Customer yang sama.
- Receipt Rp10 juta dengan alokasi Rp7 juta tetap menghasilkan satu jurnal:
  Debit Cash/Bank Rp10 juta dan Credit AR Rp10 juta. Open-item menutup Rp7 juta
  dan menyisakan kredit Rp3 juta.
- Tidak ada auto-allocation ke Invoice tertua dan tidak ada konversi otomatis ke
  Saldo Customer.

## Urutan rollout manual

Jalankan setiap file secara utuh dan hentikan pada error/FAIL:

1. `supabase/diagnostics/backoffice_ar_invoice_receipt_allocation_preflight.sql`
2. Pastikan semua row mandatory `PASS` dan state
   `FOUNDATION_INSTALLED_TASK3_NOT_INSTALLED`.
3. `supabase/migrations/20261105110000_backoffice_ar_invoice_receipt_allocation_runtime.sql`
4. `supabase/diagnostics/backoffice_ar_invoice_receipt_allocation_postflight.sql`
5. `supabase/tests/backoffice_ar_invoice_receipt_allocation_runtime_behavior.sql`
6. Jalankan postflight yang sama sekali lagi setelah behavior rollback.
7. Baru deploy client Backoffice.
8. Authenticated smoke melalui menu Finance > Penerimaan Customer.

Jangan menjalankan migration jika ada Draft Penerimaan Customer Backoffice,
Finance queue aktif, Offline submission nonterminal, atau anchor runtime berubah.

## Authenticated smoke

Gunakan Company Backoffice (KMS, LSM, atau SMS), bukan Company Retail:

1. Buka Penerimaan Customer dan pastikan panel **Kredit dan tagihan terbuka**
   tampil tanpa akses langsung ke tabel open-item.
2. Pilih satu Customer dengan Invoice terbuka.
3. Isi alokasi lebih kecil dari **Nominal diterima**, simpan Draft, lalu Post.
4. Muat ulang dan buktikan:
   - Receipt berstatus Posted;
   - Invoice berkurang sebesar alokasi;
   - selisih tampil sebagai kredit terbuka Customer yang sama;
   - jurnal hanya satu, Debit Cash/Bank penuh dan Credit AR penuh.
5. Dari detail Invoice, catat pembayaran biasa dan buktikan Receipt baru juga
   masuk registry open-item.
6. Ulangi request dengan idempotency key yang sama: tidak boleh ada duplikasi.
7. Pastikan POS Retail, mixed Receipt lama, Return/Credit Note, dan Stock/FIFO
   tidak berubah.

## Rollback / forward-fix

Migration dibungkus satu transaksi. Error guard atau assertion sebelum commit
me-roll back seluruh perubahan. Setelah ledger `20261105110000` terpasang,
jangan edit/rerun migration, menghapus ledger, atau menghapus history open-item.
Koreksi wajib memakai version forward-fix baru setelah audit dampak.

Client dapat di-rollback terpisah karena database RPC bersifat additive. Namun
database runtime tidak boleh dianggap aman hanya dari build client; postflight,
rollback behavior, closing postflight, authenticated smoke, dan UAT tetap gate
terpisah.

## Evidence lokal saat package dibuat

- Executable PostgreSQL 18 probe reproduces `42601` for the old composite form
  and successfully executes the corrected scalar UUID `INTO STRICT` form.
- PostgreSQL parser menerima migration, preflight, postflight, dan behavior.
- ESLint scoped PASS.
- TypeScript `--noEmit` PASS.
- Next.js production build PASS.
- Focused Playwright contract 3/3 PASS.
- Full `backoffice-form-contract.spec.ts` masih mempunyai failure lama di form
  Purchase yang tidak terkait Task 3; itu tidak dihitung sebagai PASS Task 3
  dan tidak disembunyikan.
