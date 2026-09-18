# Privileged Company Permission Authority Rollout

Status 2026-09-18: migration, rollback-only behavior, dan postflight telah
dikonfirmasi user `PASS`. Client deploy, authenticated smoke, dan UAT masih
menunggu.

## Outcome

Platform Super Admin memperoleh seluruh capability yang didukung pada semua
Company aktif. Company Owner memperoleh capability yang sama hanya pada Company
tempat membership `COMPANY_OWNER`-nya aktif. Keduanya tetap mengikuti feature
entitlement dan guard bisnis dokumen.

Fix client juga mengganti daftar permission navigation yang sebelumnya ditulis
satu per satu dengan satu profil permission server. Bug konkret
`finance.payment_methods` jatuh ke fallback `VIEW` karena key tersebut tidak
pernah diminta oleh endpoint navigation; setelah fix tombol tambah/edit membaca
capability `MANAGE` yang sebenarnya.

## Impact boundary

- berubah: resolver ACP, guard penyimpanan restriction, navigation capability,
  serta tampilan restriction untuk Company Owner;
- tidak berubah: data transaksi, role user, membership, feature Company,
  Payment Method existing, Stock/FIFO, Payment, Journal, audit transaksi, dan
  lifecycle dokumen;
- `platform.companies` tetap khusus Platform Super Admin;
- toggle entitlement Company tetap khusus Platform Super Admin;
- Company Owner tidak memperoleh akses Company lain;
- maker-checker, status dokumen, optimistic version, idempotency, periode dan
  source ownership tetap diperiksa oleh RPC domain masing-masing.

Existing override milik Owner direset oleh migration karena bertentangan dengan
authority baru. State lama dicatat lebih dahulu pada audit immutable; transaksi,
membership, dan histori bisnis tidak dihapus.

## Urutan manual database

Jalankan file penuh, bukan selected text. Stop pada SQL error, `BLOCKER`, atau
`FAIL`.

1. [Preflight](../../supabase/diagnostics/privileged_company_permission_authority_preflight.sql)
2. [Migration](../../supabase/migrations/20260918110000_privileged_company_permission_authority.sql)
3. [Postflight](../../supabase/diagnostics/privileged_company_permission_authority_postflight.sql)
4. [Behavior test](../../supabase/tests/privileged_company_permission_authority_behavior.sql)
5. Jalankan ulang postflight.
6. Deploy client Backoffice setelah database PASS.

## Authenticated smoke

1. Login sebagai Platform Super Admin, pilih satu Company, buka Finance →
   Metode Pembayaran. Tombol **Tambah Metode** harus tersedia dan create/edit
   Draft master berhasil melalui RPC canonical.
2. Ulangi sebagai Company Owner pada Company miliknya.
3. Pindah ke Company yang tidak dimiliki Owner; akses harus ditolak.
4. Pastikan Owner tidak dapat membuka pengelolaan daftar Company platform atau
   toggle entitlement.
5. Uji satu akun Finance/Accounting dengan preset restriction; restriction
   tetap mempersempit capability sesuai konfigurasi.
6. Uji satu aksi domain final dan pastikan lifecycle/approval tetap menolak
   aksi yang belum memenuhi status bisnis.

## Rollback / forward-fix

Migration tidak mengubah transaksi atau menghapus override. Jika postflight
atau smoke gagal, hentikan client rollout. Jangan edit migration yang sudah
applied; buat forward-fix yang mengembalikan definisi resolver sebelumnya atau
memperbaiki mapping menu yang salah. Existing override tetap tersedia untuk
role non-privileged.
