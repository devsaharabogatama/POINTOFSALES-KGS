# G6 Corrective Phase 6B - Controlled Live Stock Opening

## Reviewed scope

Live preflight dikonfirmasi tanpa blocker/review:

- satu `STOCK_OPENING` HOLD;
- source/rule/period valid;
- amount sumber Rp450.000;
- tidak ada queue aktif, journal, atau exception awal;
- FIFO Rp84.710.000 dan Inventory GL nol;
- 25 event dari sembilan contract lain tetap deferred.

Rp450.000 tidak sama dengan seluruh nilai FIFO. Operasi ini hanya membuktikan
dan memposting event yang sudah didukung. Selisih sesudah posting tetap deferred
sampai resolver kontrak transaksi lain dibuka; jangan membuat adjustment manual.

## Urutan

1. Pastikan tidak ada aktivitas Finance/Opening Stock lain selama maintenance.
2. Jalankan seluruh
   `supabase/operations/g6_phase6b_post_one_live_stock_opening.sql`.
3. Expected hasil terakhir:
   `status=COMPLETED`, `posted_count=1`, `failed_count=0`, `skipped_count=0`.
4. Jalankan seluruh
   `supabase/diagnostics/g6_phase6b_stock_opening_live_reconciliation_postflight.sql`.
5. Kirim seluruh output untuk closing review.

## Failure handling

- Bila operation berhenti sebelum `COMMIT`, transaction rollback dan preflight
  harus diulang.
- First attempt yang berhenti pada `INVALID_CONTEXT_SOURCE` terjadi sebelum
  queue/journal dibuat dan rollback utuh. Operation telah dikoreksi memakai
  source `G6_PHASE6B_LIVE_POST` yang memenuhi kontrak 2–32 karakter.
- Bila queue final `COMPLETED_WITH_ERRORS`, jangan menghapus queue/journal/event.
  Kirim output dan exception untuk forward diagnosis.
- Jangan menjalankan operation dua kali. Exact retry dilindungi queue/event
  identity, tetapi rerun manual bukan prosedur recovery.

## Boundary

Operation menggunakan linked Super Admin sebagai maintenance actor dan active
Company yang diturunkan dari satu event reviewed. Scope dikunci ke tepat satu
event dengan total Rp450.000; perubahan live sebelum eksekusi membuat script
abort. Tidak ada event unsupported yang masuk queue.
