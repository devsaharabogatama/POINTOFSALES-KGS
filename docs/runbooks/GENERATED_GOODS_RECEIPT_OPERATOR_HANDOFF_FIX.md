# Generated Goods Receipt Operator Handoff Forward-Fix

## Root cause

Receipt otomatis menyimpan pembuat PO sebagai `received_by`. Runtime lama hanya
mengizinkan operator itu menyimpan atau mem-post Receipt setelah line tersedia.
Akibatnya user Gudang lain yang mempunyai permission sah menerima
`GOODS_RECEIPT_OWNER_SCOPE_INVALID`.

## Dampak fix

- Receipt Draft otomatis menjadi dokumen kerja bersama dalam Company/Gudang.
- User tetap wajib memiliki capability `EDIT_DRAFT` atau `POST`.
- Operator aktual menjadi `received_by` dan pergantiannya masuk audit.
- Company, source PO, Gudang, optimistic version dan idempotency tetap dijaga.
- Receipt final, Stock/FIFO, Bill, Payment, Finance dan transaksi historis tidak
  diubah saat migration dipasang.

## Urutan manual

1. Jalankan `generated_goods_receipt_operator_handoff_preflight.sql` penuh.
2. Hentikan bila ada `BLOCKER`; `SETUP` hanya berarti migration sudah terpasang.
3. Jalankan `20260917141000_generated_goods_receipt_operator_handoff.sql` sekali.
4. Jalankan `generated_goods_receipt_operator_handoff_postflight.sql`; seluruh
   hasil non-`INFO` harus `PASS`.
5. Jalankan `generated_goods_receipt_operator_handoff_behavior.sql` penuh;
   fixture memakai Receipt Draft started yang ada dan seluruh perubahan di-rollback.
6. Jalankan postflight sekali lagi; seluruh non-`INFO` harus tetap `PASS`.
7. Hard refresh Backoffice, buka Receipt yang sebelumnya gagal, lalu Save Draft
   dan Post dengan user Gudang yang berwenang.

Migration bersifat forward-only. Jangan menghapus Receipt, line, audit, Stock
Movement atau ledger. Jika smoke menemukan error baru, hentikan dan gunakan
error lengkap untuk forward-fix berikutnya.
