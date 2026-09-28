# Backoffice Posted Invoice Price Correction Rollout

Status awal: `LOCAL READY` hanya setelah lint/build lulus. Jangan menyebut
`DATABASE LIVE`, `SMOKE PASS`, atau `UAT PASS` sebelum bukti masing-masing ada.

## Urutan Production

1. Jalankan `supabase/diagnostics/backoffice_posted_invoice_price_correction_preflight.sql`.
   Berhenti pada SQL error atau satu pun `BLOCKER`.
2. Jalankan `supabase/migrations/20260928110000_backoffice_posted_invoice_price_correction.sql`.
   Berhenti pada SQL error; jangan mengubah guard agar migration terlihat sukses.
3. Jalankan `supabase/tests/backoffice_posted_invoice_price_correction_behavior.sql`.
   Test memakai satu Invoice Posted yang eligible, membuat Debit dan Credit Note
   di dalam transaksi, lalu `ROLLBACK`. Berhenti bila tidak menghasilkan satu
   baris `PASS`.
4. Jalankan `supabase/diagnostics/backoffice_posted_invoice_price_correction_postflight.sql`.
   Berhenti pada `FAIL`.
5. Deploy commit client yang sama. Lakukan authenticated smoke pada KMS dahulu,
   lalu LSM dan SMS.

## Smoke wajib

- Invoice Posted tanpa Retur: ubah satu harga naik, konfirmasi, lalu cocokkan
  timestamp server, Debit Note, jurnal balance, total berlaku, AR, dan batas
  Penerimaan Customer.
- Exact browser retry tidak boleh menggandakan correction/Event/Journal.
- Dua browser: browser kedua dengan price revision lama harus ditolak.
- Harga turun pada Invoice belum dibayar: Credit Note mengurangi AR.
- Harga turun melampaui AR terbuka: UI harus menampilkan Refund Customer
  tertunda; jangan dianggap payout selesai.
- Setelah Refund Customer tertunda terbentuk, koreksi harga naik berikutnya
  harus mengurangi liability itu lebih dulu dan tidak langsung membuat AR baru.
- Daftar kandidat Penerimaan Customer, batas input, posting recheck, aging,
  statement, detail, print, dan PDF harus menunjukkan total efektif yang sama.
- Invoice yang sudah mempunyai Credit Note Retur tidak menampilkan aksi aktif
  dan server tetap menolak mutation.
- Buat Retur setelah koreksi pada fixture/UAT yang disetujui; nilai Credit Note
  harus memakai harga efektif terbaru.
- Pastikan tidak ada Stock Movement/FIFO/COGS/qty/UOM/original Invoice/original
  Journal yang berubah.

## Forward-fix

Sebelum ada correction Production, migration dapat dibatalkan secara terencana
dengan mengembalikan wrapper/read model dan menghapus objek additive. Setelah
ada correction Posted, jangan drop atau mengubah histori. Nonaktifkan tombol dan
buat forward-fix/reversal correction baru dengan source lineage yang sama.
