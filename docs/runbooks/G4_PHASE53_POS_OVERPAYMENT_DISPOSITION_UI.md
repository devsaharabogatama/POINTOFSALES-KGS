# G4 Phase 53 — POS Overpayment Disposition UI

## Outcome

POS online menampilkan pilihan eksplisit ketika nominal Cash atau Transfer yang
diterima lebih besar daripada bagian tagihan:

- `Kembalikan ke Customer`; atau
- `Simpan sebagai Saldo` untuk Customer reguler ketika feature dan policy
  Customer Balance Company aktif.

Phase ini hanya menghubungkan UI ke kontrak server Phase 52. Customer Balance
belum menjadi cara bayar, dan kredit saldo tetap ditutup saat POS offline.

## Compatibility dan boundary

- pembayaran tepat tidak menampilkan pilihan tambahan;
- Cash lama tanpa disposition tetap diperlakukan `RETURNED` oleh server;
- Walk-In tidak dapat menerima saldo;
- Transfer menerima input nominal aktual hanya saat online;
- offline tidak mengirim `CUSTOMER_BALANCE`;
- harga, total, eligibility Customer, feature, policy, ledger, dan idempotency
  tetap divalidasi server-side.

Tidak ada migration pada Phase 53. Rollback cukup mengembalikan perubahan PWA;
contract additive Phase 52 tetap kompatibel dengan client lama.

## Verification lokal

```powershell
cd pwa
npm.cmd run lint
npm.cmd run build
```

## Authenticated smoke wajib

1. hard refresh PWA lalu buka satu Session online;
2. Customer Walk-In + Cash tepat: pilihan selisih tidak muncul dan Sale posted;
3. Customer Walk-In + Cash lebih: opsi saldo disabled, pilih kembalian, lalu
   pastikan receipt menampilkan kembalian;
4. Customer reguler + Cash lebih: pilih `Simpan sebagai Saldo`, post, lalu
   pastikan receipt menampilkan `Saldo +` dan statement/cache Customer bertambah
   tepat sekali;
5. ulangi poin 4 dengan Transfer dan bukti HTTPS bila metode mewajibkannya;
6. Split Payment: jumlah `Bagian tagihan` tetap sama dengan total final dan
   selisih tender hanya berada pada leg yang dipilih;
7. putuskan jaringan: opsi simpan saldo tidak tersedia dan transaksi offline
   tidak boleh menghasilkan credit Customer Balance;
8. retry/reload receipt Sale yang sama tidak boleh menggandakan ledger credit.

## Exit gate

Phase 53 menjadi complete setelah authenticated smoke di atas lulus. Tender
Customer Balance, refund-to-balance, offline balance, dan exceptional settlement
tetap menunggu gate terpisah.
