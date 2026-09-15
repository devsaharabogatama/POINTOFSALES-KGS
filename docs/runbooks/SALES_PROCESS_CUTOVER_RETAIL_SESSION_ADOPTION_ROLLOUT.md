# Sales Process Cutover Retail Session Adoption — Step 4D/6

Status: **DATABASE LIVE + BEHAVIOR/POSTFLIGHT USER-CONFIRMED PASS ON ISOLATED DEVELOPMENT**.

Target hanya isolated Supabase Development `fkywtxucmyjvpwdiqpix`.
Production/staging tidak disentuh.

## Kontrak terkunci

- Draft `BACKOFFICE_CUTOVER` dibuat tanpa sesi/terminal palsu.
- Saat operator menekan `Lanjutkan`, attachment hanya boleh ke Cashier Session
  `OPEN` milik actor dengan Company, Store, dan Warehouse yang sama.
- Attachment mengambil lock dan menaikkan optimistic version, tetapi tidak
  menjalankan resolver harga.
- Harga, discount, tax, rounding, ongkir, tanggal, line, dan total tetap persis
  snapshot source ketika Draft hanya dibuka atau pilihan pembayaran disimpan.
- Payment selalu dimulai ulang di PWA. Preserve-save hanya mengganti array
  payment intent; confirmation runtime lama tetap menjadi validator akhir.
- Jika operator mengubah isi form selain pembayaran, PWA kembali memakai
  `save_pos_sale_draft_with_pricelist` canonical dan resolver Retail.
- Origin tetap `BACKOFFICE_CUTOVER`; Company, Store, dan Warehouse tidak boleh
  berpindah setelah conversion.

## Impact map

- Direct: identity helper/guard `sales_headers`, dua RPC attachment/preserve,
  immutable operation history, read model daftar Draft, dan PWA `Lanjutkan`.
- Downstream yang tidak berubah: Reservation, SJ/Invoice final, Stock Movement,
  On Hand, FIFO/COGS, Payment final, Cash Drawer, Finance Event/Queue/Journal,
  Company mode, dan public Apply.
- Draft POS/revisi biasa tetap memakai lock + save/reprice lama.
- Exact operation retry mengembalikan response yang sama; payload berbeda pada
  UUID sama ditolak. Stale master version ditolak sebelum mutation.

## Urutan manual

1. Pastikan SQL Editor menunjuk Development `fkywtxucmyjvpwdiqpix`.
2. Jalankan seluruh [preflight](../../supabase/diagnostics/sales_process_cutover_retail_session_adoption_preflight.sql).
   `step_4d_object_collision=SETUP` adalah expected sebelum migration; seluruh
   `BLOCKER` wajib nol.
3. Jalankan [migration](../../supabase/migrations/20260911120000_sales_process_cutover_retail_session_adoption.sql).
4. Jalankan seluruh [behavioral test](../../supabase/tests/sales_process_cutover_retail_session_adoption_behavior.sql).
   Test membuat fixture sendiri dan `ROLLBACK` penuh.
5. Jalankan [postflight](../../supabase/diagnostics/sales_process_cutover_retail_session_adoption_postflight.sql).
6. User telah mengonfirmasi hasil behavior dan seluruh row postflight `PASS`.
   Gate berikutnya adalah Step 4E atomic Apply; client deployment/smoke/UAT
   tetap belum dilakukan.

## Evidence lokal

### Historical-clone rehearsal — 2026-09-15

- Target rehearsal `idrufihckscppsyclmsu`, bukan production.
- Behavioral preparation memakai fresh Auth/Profile UUID dalam transaksi yang
  sama, sehingga tidak berbenturan dengan unique OPEN-session per cashier.
  Sesi operasional tidak dipinjam, ditutup, atau diubah.
- Jalankan [exact fixture preflight](../../supabase/diagnostics/sales_process_cutover_retail_session_adoption_behavior_fixture_preflight.sql)
  sebelum behavioral. Preflight PASS pada empat Company.
- Corrected behavioral dan closing postflight PASS; adoption operations kembali
  nol. Migration applied tetap immutable dan tidak dijalankan ulang.

- PWA `npm.cmd run lint`: PASS.
- PWA `npm.cmd run build`: PASS; hanya warning ukuran chunk existing.
- SQL delimiter/parenthesis scan: seimbang.
- `git diff --check` scoped: PASS; hanya warning normalisasi CRLF existing.
- Migration SHA-256: `3e4308a38c554dbcb16629987bab39f93e7d44822f7af4cdc890f2ef1205182b`.
- Preflight SHA-256: `f39d3ba8c1056d41307a358c9ba9845a60c44d7ef56b09f63c42b9a5c9f4b491`.
- Behavior SHA-256: `158ff591f56c1c609f77e9a946ee8a99f8084a8feac19a52d8a664e55e651321`.
- Postflight SHA-256: `6cc37ba42e887f20dd4e1153f50c2bfab4a97dc05e9cce0d7a57899415d3b5f2`.

## Rollback / forward-fix

SQL error sebelum `COMMIT` merollback seluruh Step 4D. Setelah ledger terpasang,
jangan edit migration. Defect wajib dikoreksi dengan migration additive baru.
Karena public Apply belum tersedia, runtime dapat tetap tertutup tanpa mengubah
Company mode atau dokumen operasional.
