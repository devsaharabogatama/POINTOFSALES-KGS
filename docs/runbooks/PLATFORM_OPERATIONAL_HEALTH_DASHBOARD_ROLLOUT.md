# Platform Operational Health Dashboard Rollout

**Status:** `LOCAL READY; MANUAL DATABASE ROLLOUT AND SUPER ADMIN SMOKE PENDING`  
**Tanggal:** 1 September 2026  
**Akses tahap ini:** hanya Platform Super Admin

## Outcome

Memberi Super Admin satu dashboard global untuk menemukan Company dan modul
yang membutuhkan tracing tanpa membuka SQL satu per satu. Dashboard hanya
membaca agregat status dan tidak mempunyai tombol perbaikan data.

## Scope tahap pertama

- seluruh Company tampil dalam satu dashboard;
- klasifikasi `HEALTHY`, `WARNING`, atau `CRITICAL`;
- indikasi sesi kasir lama, queue/exception Finance, import/Offline tertahan,
  Reservation/Delivery/Demand lama, pembayaran pending, event `HOLD`, serta
  settlement biaya stok minus;
- refresh hanya ketika halaman dibuka atau tombol **Muat ulang manual** ditekan;
- payload tidak memuat nama Customer, nama Kasir, nomor rekening, alamat,
  payment proof, atau isi transaksi;
- RPC dan endpoint hanya menerima Super Admin.

## Di luar scope

- auto-fix, retry, posting, cancel, atau mutation apa pun;
- trigger pada POS, Stock, FIFO, Purchasing, Payment, atau Finance;
- polling/auto-refresh di latar belakang;
- dashboard Company Owner/Admin;
- log aplikasi eksternal dan perbandingan versi bundle Vercel.

Dashboard Company yang lebih terbatas dicatat sebagai pengembangan berikutnya.
Versi tersebut harus tenant-scoped dan hanya menampilkan tindakan operasional,
bukan diagnosis teknis lintas Company.

## Impact dan compatibility

- Migration hanya membuat `public.get_platform_operational_health()` dan satu
  ledger migration. Tidak ada tabel transaksi, backfill, trigger, atau policy
  Company yang diubah.
- RPC memakai `SECURITY DEFINER`, guard `private_is_super_admin(auth.uid())`,
  `search_path` terkunci, dan statement timeout 8 detik.
- `anon` tidak memperoleh execute; `authenticated` masih harus lolos guard
  Super Admin di database.
- Endpoint API mengulang guard role dan menggunakan Supabase publishable/anon
  client dengan JWT user, bukan service-role.
- Jika migration belum terpasang atau query timeout, hanya halaman Health yang
  gagal dimuat. POS dan menu Backoffice lain tidak bergantung pada RPC ini.

## Threshold awal

| Indikasi | Threshold |
|---|---:|
| Sesi kasir terbuka | lebih dari 18 jam |
| Queue Finance aktif | lebih dari 30 menit |
| Import nonterminal | lebih dari 30 menit |
| Offline `QUEUED/SYNCING` | lebih dari 15 menit |
| Reservation atau Delivery aktif | lebih dari 24 jam |
| Demand Purchasing aktif | lebih dari 24 jam |
| Payment verification pending | lebih dari 24 jam |

Finance exception, Offline `FAILED/NEEDS_CONFIRMATION`, open negative-cost
allocation, pending cost adjustment, dan event `HOLD` ditampilkan tanpa
menunggu threshold umur. Nilai tersebut adalah indikasi untuk diperiksa, bukan
izin mengubah data langsung.

## Urutan rollout manual

1. Jalankan
   `supabase/diagnostics/platform_operational_health_dashboard_preflight.sql`.
2. Berhenti jika ada `BLOCKER`.
3. Jalankan migration
   `supabase/migrations/20260901090000_platform_operational_health_dashboard.sql`.
4. Jalankan
   `supabase/tests/platform_operational_health_dashboard_postflight.sql`.
5. Berhenti jika ada `FAIL`.
6. Jalankan
   `supabase/tests/platform_operational_health_dashboard_behavior.sql`.
7. Jalankan postflight sekali lagi.
8. Deploy/restart Backoffice target yang memang dipilih user; jangan mengubah
   production secara otomatis.
9. Login sebagai Super Admin, buka **Platform → Health Operasional**, lalu tekan
   **Muat ulang manual**.
10. Login sebagai user biasa dan pastikan menu tidak tampil serta endpoint
    mengembalikan `403` bila dipanggil langsung.

## Smoke operasional

- Cocokkan jumlah Company dengan menu Platform → Perusahaan.
- Pastikan Company dengan Finance exception atau Offline failure berada pada
  status `CRITICAL`.
- Pastikan pekerjaan aktif yang masih di bawah threshold tidak salah diberi
  indikasi stale.
- Pilih Company dan pastikan daftar indikasi terfilter.
- Buka POS dan lakukan transaksi terpisah ketika dashboard sedang tertutup;
  tidak ada RPC health yang dipanggil.
- Buka dashboard lalu ulangi transaksi; dashboard tidak auto-refresh dan tidak
  memblokir mutation.
- Simulasikan endpoint gagal/migration belum ada pada environment nonproduction;
  halaman menampilkan error terisolasi dan navigation lain tetap bekerja.

## Rollback / forward-fix

Tidak ada business-data rollback karena migration tidak mengubah data bisnis.
Jika query perlu diperbaiki, sembunyikan menu dari build target atau buat
forward migration yang mengganti definisi RPC. Jangan drop function ketika
client lama masih dapat memanggilnya dan jangan memberi akses direct table
sebagai jalan pintas.

