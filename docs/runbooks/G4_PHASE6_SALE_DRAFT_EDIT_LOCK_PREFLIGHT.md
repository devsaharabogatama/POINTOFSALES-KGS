# G4 Phase 6 — Sale Draft List dan Edit-Lock Preflight

## Tujuan

Mengaudit kesiapan data dan schema sebelum membuka daftar Draft/Hold Sale,
continuation lintas sesi/terminal dalam Store yang sama, single-editor lock,
takeover, force release, dan cancel Draft.

Phase ini belum membuka split payment.

## Kontrak yang Dijaga

- Draft tidak mereservasi atau mengurangi stok;
- Draft tidak membuat Payment final, Financial Event, atau jurnal;
- Draft dapat melewati pergantian sesi dan dibuka Cashier lain pada Store sama;
- hanya satu actor/session boleh mengedit satu Draft;
- heartbeat lock kedaluwarsa setelah lima menit;
- takeover lock kedaluwarsa dan force release Manager/Admin wajib diaudit;
- harga, promo, stok, UOM, Payment, dan aturan transaksi dihitung ulang sebelum
  posting;
- Draft lebih dari tujuh hari hanya diberi status stale, tidak dihapus;
- cancel Draft tidak menghapus histori dan tidak dapat mengaktifkan Draft lama.

## Cara Menjalankan

Jalankan seluruh file berikut di Supabase SQL Editor:

`supabase/diagnostics/g4_phase6_sale_draft_edit_lock_preflight.sql`

Kirim seluruh hasil `check_name,status,details`.

## Interpretasi

- `BLOCKER`: data live atau dependency tidak aman; migration belum boleh dibuat.
- `REVIEW`: snapshot Draft lama membutuhkan keputusan backfill eksplisit.
- `SETUP`: gap schema/RPC/audit/visibility yang memang akan dibuat pada phase
  foundation berikutnya.
- `PASS`: invariant existing aman.
- `INFO`: inventory atau privilege boundary.

Expected pada schema sebelum Phase 6:

- kolom lock/lifecycle masih `SETUP`;
- lima guarded routine masih `SETUP`;
- same-Store Cashier visibility dan audit action dapat masih `SETUP`;
- direct browser table write tetap seluruhnya `false`;
- seluruh check data side-effect Draft harus `PASS`.

## Boundary

Diagnostic ini SELECT-only dan tidak:

- mengubah Sale/Draft;
- membuat atau mengambil lock;
- mereservasi stok;
- membuat Payment/Movement/Financial Event;
- mengaktifkan split payment, offline queue, Return, Expense, atau Deposit.
