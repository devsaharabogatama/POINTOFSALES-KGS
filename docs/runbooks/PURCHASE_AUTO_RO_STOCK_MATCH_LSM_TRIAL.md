# LSM AUTO_RO Stock Match Trial

Status: `DATABASE LIVE / POSTFLIGHT PASS / BEHAVIOR PASS / POLICY OFF`;
belum `CLIENT DEPLOYED`, `LSM ACTIVATED`, `SMOKE PASS`, atau `UAT PASS`.

## Urutan rollout wajib

Hentikan pada SQL error, `BLOCKER`, atau `FAIL` pertama. Jangan melompati gate.

1. Jalankan read-only preflight
   `supabase/diagnostics/purchase_auto_ro_stock_match_preflight.sql`.
2. Jalankan migration
   `supabase/migrations/20260924100000_purchase_auto_ro_stock_match.sql`.
   Feature masih OFF di seluruh Company.
3. Jalankan read-only installation postflight
   `supabase/diagnostics/purchase_auto_ro_stock_match_postflight.sql`.
   Gate ini sengaja mewajibkan `enabledCompanies = 0`.
4. Jalankan rollback-only behavior
   `supabase/tests/purchase_auto_ro_stock_match_behavior.sql`.
   Test membuat RO/PO transient, menguji de-dup dan stale guard, lalu rollback.
   Sequence nomor PO dapat mempunyai gap; Stock/FIFO/Finance tidak berubah.
5. Deploy client yang berisi API/UI `Cocokkan Stok`. Jangan mengaktifkan LSM
   sebelum client baru live karena client lama akan ditolak saat confirm.
6. Jalankan activation khusus LSM
   `docs/runbooks/LSM_AUTO_RO_STOCK_MATCH_ACTIVATION.sql`.
7. Jalankan
   `supabase/diagnostics/purchase_auto_ro_stock_match_lsm_activation_postflight.sql`.
8. Authenticated smoke menggunakan satu RO LSM Draft, lalu lakukan UAT.

## Authenticated smoke

1. Buka detail RO LSM. KMS/SMS tidak boleh menampilkan flow baru.
2. Jika ada selisih, periksa daftar SKU dan klik `Cocokkan Stok`.
3. Pastikan nomor RO tetap sama, banner selisih hilang, dan status menjadi
   `Stok sudah cocok`.
4. Pastikan tab `Stok Lebih` tidak membuat baris PO.
5. Ubah satu Qty dari rekomendasi dan klik konfirmasi. Dialog kedua harus
   menampilkan rekomendasi, jumlah dipesan, dan proyeksi selisih.
6. Pilih kembali lalu kembalikan Qty ke rekomendasi; konfirmasi harus membuat PO.
7. Pastikan RO yang sudah menjadi PO tidak lagi dihitung sebagai Draft coverage;
   hanya sisa PO belum diterima yang dihitung.
8. Pastikan rematch sendiri tidak membuat Stock Movement, FIFO, Receipt, Bill,
   Event, Journal, atau Payment.

## Emergency stop

Jalankan `docs/runbooks/LSM_AUTO_RO_STOCK_MATCH_DEACTIVATION.sql`. Setelah OFF,
legacy confirmation LSM kembali aktif. Audit match yang sudah ada tetap disimpan.
Dokumen bisnis tidak dihapus atau dibalik oleh deactivation.
