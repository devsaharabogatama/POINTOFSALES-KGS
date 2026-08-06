# G4 Phase 50 — Customer Balance Operational UI

## Scope

Phase ini membuka UI Backoffice `Finance > Saldo Customer` di atas RPC guarded
Phase 49. Tidak ada schema atau direct table mutation baru.

Fungsi yang tersedia:

- dashboard total liability dan status lifecycle Company;
- saldo per Customer dan statement append-only;
- pengajuan koreksi tambah/kurang dengan Toko, sumber dana, alasan, dan link bukti HTTPS;
- approval atau penolakan oleh reviewer berbeda;
- label bisnis user-facing; UUID dan account-function key tidak ditampilkan;
- custom dialog dengan tombol Escape.

Checkout Customer Balance, refund-to-balance, overpayment credit, Ketul,
exceptional settlement, Offline Customer Balance, export Excel/aging, dan jurnal
G6 tetap tertutup.

## Evidence Lokal

```text
cd backoffice
npm.cmd run lint   # PASS
npm.cmd run build  # PASS; 4 route Customer Balance terdaftar
git diff --check   # PASS untuk scope Phase 50
```

## Authenticated Smoke

1. Restart Backoffice dan login sebagai Finance/Owner/Admin pada Company aktif.
2. Buka `Finance > Saldo Customer`; pastikan UUID/account code tidak tampil.
3. Buat pengajuan tambah saldo Customer memakai Toko aktif dan alasan jelas.
4. Pastikan saldo belum berubah serta status pengajuan `Menunggu`.
5. Login dengan user reviewer berbeda; setujui pengajuan.
6. Pastikan saldo Customer bertambah tepat sekali dan Statement memiliki satu mutasi dengan saldo sebelum/sesudah yang benar.
7. Buat pengajuan pengurangan lalu tolak dengan alasan; pastikan saldo tidak berubah.
8. Pastikan pembuat tidak memperoleh tombol approval untuk request miliknya.
9. Tekan Escape pada seluruh modal; modal tertutup tanpa browser prompt.
10. Login Accounting; halaman hanya baca dan tidak menyediakan mutation.

Jika API mengembalikan `CUSTOMER_BALANCE_ACCOUNT_FUNCTION_NOT_CONFIGURED`,
konfigurasi fallback/COA sumber tersebut harus diperbaiki; UI tidak boleh
memilih akun lain secara diam-diam.

## Compatibility

- `customers.current_balance` tetap cache read-only dari ledger.
- Foundation dan digest forward fix Phase 49 tidak direrun.
- Canonical Sale tetap menolak tender Customer Balance sampai fase checkout khusus dibuka dan lulus UAT.
