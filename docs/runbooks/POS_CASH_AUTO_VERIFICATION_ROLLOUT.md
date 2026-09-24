# POS Cash Auto Verification Rollout

Status: **LOCAL READY**. Tidak ada Production mutation atau deploy yang
dijalankan oleh agent.

## Urutan wajib

1. Hentikan sementara konfirmasi POS dan proses Finance pada target Company.
2. Jalankan
   [preflight](../../supabase/diagnostics/pos_cash_auto_verification_preflight.sql).
   Semua gate harus `PASS`; `INFO` hanya inventory. Jangan lanjut jika ada
   `BLOCKER`. Gate call-chain harus melaporkan `confirmWrapper=1` dan
   `confirmComposition=1`; nilai lama `confirm=0` berasal dari harness yang
   hanya memeriksa wrapper publik dan tidak boleh dipakai lagi.
3. Jalankan migration
   [20260923100000](../../supabase/migrations/20260923100000_pos_cash_auto_verification.sql)
   satu kali dan sebagai file penuh.
4. Jalankan rollback-only
   [behavioral test](../../supabase/tests/pos_cash_auto_verification_behavior.sql).
   Fixture dibatalkan oleh `ROLLBACK`.
5. Jalankan
   [postflight](../../supabase/diagnostics/pos_cash_auto_verification_postflight.sql).
   Semua gate kontrak harus `PASS`.
6. Deploy Backoffice dari commit yang sama. PWA tidak membutuhkan perubahan
   client untuk kontrak ini; perubahan status terjadi di RPC confirm server.
7. Lakukan authenticated smoke berikut pada Company uji yang sama:

   - Cash-only: confirm Order, pastikan request langsung `VERIFIED`, satu Drawer
     `IN`, satu Event `HOLD`, dan tidak muncul di Verifikasi Pembayaran POS.
   - Transfer-only: pastikan tetap `PENDING`, muncul di queue Finance, dan
     maker-checker tetap berlaku.
   - Split Cash + Transfer: Cash langsung final, Transfer tetap pending, total
     kedua kaki sama dengan total Order, tidak ada movement/event ganda.
   - Retry request yang sama dan stale payload: exact retry tidak menambah row;
     payload berbeda ditolak.
   - Tutup sesi setelah Cash-only: Session dapat ditutup dan expected Cash
     memuat Drawer `IN` tersebut.
   - Cancel sebelum dispatch saat Event masih `HOLD`: satu Drawer `OUT`, Event
     menjadi `CANCELED`, request menjadi `CANCELED`.
   - Coba cancel setelah Event `POSTED` atau dispatch dimulai: harus ditolak dan
     diarahkan ke reversal/refund source-linked.
   - Pastikan Order yang memiliki Cash `VERIFIED` tetap tidak dapat direvisi.
   - Ulangi smoke dari Company berbeda dan pastikan tidak ada data lintas tenant.

## Compatibility

- Existing pending Cash hanya dibackfill bila Drawer `IN`, Session, Store, POS,
  amount, source request, Sales, dan kategori Finance exact. Ambiguitas membuat
  migration rollback penuh.
- Existing Cash/Transfer yang sudah final tidak ditulis ulang.
- Posting jurnal tetap controlled. Auto-verification hanya membuat Event
  `HOLD`; mapping COA dan periode tetap diperiksa oleh runtime posting existing.
- Stock, FIFO, Reservation, Dispatch, Return/Refund, RO/PO, dan Backoffice Sales
  tidak diubah.

## Forward-fix / rollback note

Migration ini melakukan backfill status dan membuat source-linked Event, jadi
jangan drop kolom, audit, request, Drawer movement, atau Event setelah Production
commit. Bila defect ditemukan sesudah migration:

1. hentikan confirm POS baru;
2. rollback client Backoffice bila perlu;
3. inventarisir request `verification_mode='AUTO_CASH'` beserta Event/Journal;
4. Event `HOLD` dapat dikoreksi dengan forward migration source-linked;
5. Event `POSTED` wajib memakai reversal/refund, tidak boleh diubah/hapus;
6. buat forward-fix append-only dan ulangi behavior/postflight/smoke.

Jangan tandai selesai sebelum status `DATABASE LIVE`, `CLIENT DEPLOYED`,
`SMOKE PASS`, dan `UAT PASS` masing-masing mempunyai bukti nyata.
