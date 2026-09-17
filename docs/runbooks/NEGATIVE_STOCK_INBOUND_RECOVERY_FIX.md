# Negative Stock Inbound Recovery Forward-Fix

## Dampak

- Memperbaiki guard `stock_movements` yang salah meminta otorisasi penjualan
  ketika Goods Receipt positif memperbaiki saldo tetapi saldo akhirnya masih
  negatif.
- Movement inbound `qty_change > 0` tidak memerlukan otorisasi minus.
- Movement outbound yang berakhir negatif tetap melewati otorisasi Retail atau
  Backoffice Warehouse canonical.
- Tidak mengubah Product Stock, FIFO, PO, Goods Receipt, Finance, permission,
  atau transaksi historis saat migration dipasang.

## Urutan manual

1. Jalankan seluruh `negative_stock_inbound_recovery_preflight.sql`; hentikan
   jika ada `BLOCKER`.
2. Jalankan `20260917140000_negative_stock_inbound_recovery_fix.sql` satu kali.
3. Jalankan seluruh `negative_stock_inbound_recovery_postflight.sql`; seluruh
   hasil non-`INFO` wajib `PASS`.
4. Jalankan seluruh `negative_stock_inbound_recovery_behavior.sql`; hasil harus
   satu baris `PASS` dan transaksi test di-rollback.
5. Jalankan postflight sekali lagi.
6. Hard refresh Backoffice, lalu ulangi Post Goods Receipt yang sebelumnya
   terkena `NEGATIVE_STOCK_AUTHORIZATION_REQUIRED`.

## Rollback / forward-only

Migration ini forward-only. Jangan mengembalikan guard lama karena akan kembali
memblokir inbound recovery. Jika ada kegagalan baru, hentikan posting dan buat
forward-fix berdasarkan error lengkap; jangan menghapus ledger atau transaksi.
