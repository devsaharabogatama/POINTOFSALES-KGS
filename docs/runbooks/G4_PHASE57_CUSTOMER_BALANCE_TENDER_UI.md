# G4 Phase 57 — Customer Balance Tender POS UI

## Outcome

POS menampilkan saldo Customer regular dan otomatis memakai seluruh saldo lama
sebagai leg pembayaran pertama. Cashier tidak memasukkan nominal saldo manual.

## Authenticated Smoke

1. Restart/hard refresh PWA dan buka Session ONLINE.
2. Pilih Walk-In: indikator dan metode Saldo Customer tidak boleh muncul.
3. Pilih Customer saldo nol: tampil `Rp 0`, tanpa leg saldo.
4. Pilih Customer saldo positif lebih kecil dari total: leg Saldo Customer
   otomatis sebesar seluruh saldo; sisa tagihan otomatis masuk cara bayar lain.
5. Ubah isi Cart: leg saldo dan sisa pembayaran harus menyesuaikan otomatis.
6. Bila saldo lebih besar dari total: tombol Post disabled dan UI memberi
   minimum tambahan belanja. Tambah produk sampai total cukup.
7. Post: receipt/print menampilkan `Potongan Saldo Customer`; saldo menjadi nol
   dan stock/payment hanya berubah satu kali.
8. Policy WIND_DOWN: saldo lama masih dapat dipakai. Setelah nol, metode hilang
   pada refresh berikutnya.
9. Putus internet: Customer Balance tidak tersedia dan tidak masuk payload
   Offline.
10. Pastikan overpayment `Simpan sebagai Saldo` Phase 53 tetap bekerja pada
    Customer/policy ACTIVE.

## Verification Lokal

- `npm.cmd run lint` — PASS;
- `npm.cmd run build` — PASS;
- PWA service worker berhasil dibuat; warning chunk existing non-blocking.

Tidak ada migration pada Phase 57. Rollback hanya mengembalikan perubahan PWA;
contract database Phase 56 tetap kompatibel.
