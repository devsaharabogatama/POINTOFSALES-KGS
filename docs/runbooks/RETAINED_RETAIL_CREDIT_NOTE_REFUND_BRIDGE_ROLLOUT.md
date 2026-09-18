# Retained Retail Credit Note and Refund Bridge Rollout

Status: `DATABASE LIVE + BEHAVIOR/POSTFLIGHT USER-CONFIRMED PASS`; belum
`CLIENT DEPLOYED`, `SMOKE PASS`, atau `UAT PASS`.

## Tujuan

Menyelesaikan Retur berlabel `Asal Retail` setelah Gudang mem-posting Receipt.
Finance mengalokasikan barang ke Invoice Retail asli, mem-posting Credit Note,
dan membayar Refund hanya jika Credit Note menghasilkan liability Refund.

## Batas kompatibilitas

- Sale, Invoice snapshot, pembayaran, Return Retail, Receipt/disposition, Stock,
  FIFO, dan jurnal historis tidak ditulis ulang.
- Retur Backoffice native tetap didelegasikan ke runtime sebelumnya.
- Credit Note mengurangi AR lebih dahulu; kelebihan menjadi liability Refund.
- Refund memakai Payment Method, mapping akun, periode, retry, reversal, dan
  permission Finance canonical; tidak memakai POS/Cashier Session.

## Urutan Production

Jalankan setiap file penuh satu per satu di SQL Editor. Berhenti pada SQL error,
`BLOCKER`, atau `FAIL`; jangan menjalankan ulang migration yang sudah sukses.

1. [Preflight](../../supabase/diagnostics/retained_retail_credit_note_refund_bridge_preflight.sql)
2. [Migration](../../supabase/migrations/20260918150000_retained_retail_credit_note_refund_bridge.sql)
3. [Behavior rollback-only](../../supabase/tests/retained_retail_credit_note_refund_bridge_behavior.sql)
4. [Postflight](../../supabase/diagnostics/retained_retail_credit_note_refund_bridge_postflight.sql)
5. Deploy client setelah database Step 1-4 lulus.

Behavior memakai Retur `RETAINED_RETAIL` yang sudah diterima, menambah fixture
pembayaran hanya di dalam transaksi, menguji allocation, Credit Note, Refund,
reversal, retry dan stale version, lalu selalu `ROLLBACK`.

## Authenticated smoke

1. Buka Retur berlabel **Asal Retail** yang status barangnya sudah diterima.
2. Pastikan target koreksi otomatis menunjukkan **Invoice Retail Asli**.
3. Klik **Proses koreksi**; harus terbentuk Draft Credit Note tanpa error
   `query returned no rows`.
4. Buka Credit Note, cek nilai, lalu **Post Credit Note**.
5. Jika `Kewajiban refund > 0`, post Refund memakai metode Cash/Bank yang aktif.
6. Pastikan Journal Credit Note balance, AR berkurang, Refund source-linked,
   dan Sale/Invoice Retail asal tetap dapat dibuka tanpa perubahan nilai.
7. Smoke satu Retur Backoffice native untuk memastikan dispatcher lama tetap
   menghasilkan behavior yang sama.

## Rollback / forward-fix

Migration mengubah contract tabel yang sudah dapat menerima row Retained Retail;
setelah ada row baru, jangan drop column/function atau mengembalikan file lama.
Jika behavior/postflight gagal setelah migration `COMMIT`, hentikan client
deploy, simpan output lengkap, dan buat migration forward-fix additive.
