# POS Session-close Stock Request Policy Rollout

Status: **LOCAL READY**. Agent belum menjalankan Production mutation atau deploy.

## Urutan wajib

1. Hentikan sementara penutupan sesi POS pada target Company.
2. Jalankan
   [preflight](../../supabase/diagnostics/pos_session_close_stock_request_policy_preflight.sql).
   Semua gate selain `INFO` harus `PASS`; jangan lanjut jika ada `BLOCKER`.
3. Jalankan migration
   [20260924110000](../../supabase/migrations/20260924110000_pos_session_close_stock_request_policy.sql)
   satu kali sebagai file penuh.
4. Jalankan rollback-only
   [behavioral test](../../supabase/tests/pos_session_close_stock_request_policy_behavior.sql).
5. Jalankan
   [postflight](../../supabase/diagnostics/pos_session_close_stock_request_policy_postflight.sql).
   Semua kontrak harus `PASS`. `default_policy` boleh menjadi `REVIEW` hanya
   setelah Super Admin memang mengaktifkan Company secara sengaja.
6. Deploy Backoffice dan PWA dari commit yang sama.
7. Authenticated smoke:

   - Dengan switch `OFF`, buka Session, buat Order shortage, tutup Session;
     Session harus `CLOSED`, demand harus `FROZEN`, dan tidak boleh ada Stock
     Request baru.
   - Retry close Session yang sama setelah switch diubah `ON`; tetap tidak boleh
     membuat request karena snapshot Session adalah `OFF`.
   - Dengan switch `ON`, buka Session baru, buat Order shortage, tutup Session;
     harus terbentuk tepat satu Stock Request `SUBMITTED` dengan lineage Session.
   - Retry exact Session `ON`; tidak boleh membuat request kedua.
   - Transfer-only/Cash-only/split payment tetap mengikuti runtime pembayaran
     yang sudah aktif dan tidak menghalangi close.
   - Ulangi pada Company kedua untuk membuktikan tenant isolation.
   - Pastikan scheduler RO/PO harian tetap memakai mode Purchase dan tidak
     berubah akibat switch.

## Compatibility

- Existing linked Stock Request selalu dipertahankan dan dikembalikan pada
  retry, meskipun Company kemudian mematikan switch.
- Existing historical Session default `OFF` tanpa decision timestamp; retry
  tidak boleh memproyeksikannya secara retroaktif.
- Setting memakai `master_version`; tab stale harus menerima
  `MASTER_VERSION_CONFLICT`.

## Forward-fix / rollback note

Jangan drop kolom snapshot setelah Production karena nilainya menjadi bukti
keputusan close. Jika ditemukan defect:

1. matikan switch pada Company terdampak;
2. hentikan close Session baru;
3. inventarisir Session snapshot, demand, dan request lineage;
4. jangan hapus atau ubah Stock Request yang sudah final;
5. koreksi dengan forward migration append-only lalu ulangi preflight,
   behavior, postflight, deploy, dan authenticated smoke.
