# MADS Document, PO Export, dan Terminal UI Rollout

## Outcome

- Invoice dan Surat Jalan dapat diunduh sebagai PDF dengan nama Customer di awal nama file.
- Supplier Order dapat diekspor sebagai XLSX dua sheet melalui capability `EXPORT`.
- Owner/Admin/Store Manager dapat menyembunyikan fitur operasional tertentu per Terminal POS. Ini hanya menyederhanakan UI; authorization RPC tetap berlaku terpisah.
- Branding visual aplikasi berubah menjadi MADS tanpa mengganti identifier database historis.

## Urutan rollout

1. Jalankan `supabase/migrations/20260820100000_mads_po_export_terminal_ui.sql`.
2. Jalankan `supabase/tests/mads_po_export_terminal_ui_postflight.sql`; seluruh baris wajib `PASS`.
3. Jalankan `supabase/tests/mads_po_export_terminal_ui_behavior.sql`; statement harus sukses dan berakhir `ROLLBACK`.
4. Deploy/restart Backoffice dan PWA.
5. Smoke: unduh Invoice/SJ, buka workbook PO, simpan visibility satu Terminal, lalu hard refresh POS terminal tersebut.

## Compatibility dan backfill

Terminal existing mendapat `hidden_feature_keys={}` sehingga semua fitur tetap tampil. Tidak ada dokumen, transaksi, stok, payment, atau jurnal yang diubah. Capability `EXPORT` mengikuti role dan custom restriction Supplier Order yang sudah ada.

## Forward-fix

Jika UI perlu dipulihkan, simpan seluruh fitur menjadi tampil dari Backoffice. Jangan menghapus kolom atau audit setelah deployment; gunakan migration forward untuk koreksi schema/runtime.
