# UXD-2 Two-Level Launcher Rollout

**Tanggal:** 2026-08-11  
**Status:** LOCAL READY — authenticated smoke pending

## Yang Berubah

- Home hanya menampilkan card modul yang dikembalikan catalog server;
- hero `Halo, User`, block summary, dan query Produk untuk statistik Home dihapus;
- klik modul membuka landing submodul, bukan langsung halaman pertama;
- sidebar tetap fast link dan memakai item dari catalog yang sama;
- Faktur Supplier dan Pembayaran Supplier hanya dimiliki modul Finance;
- Expense, Saldo Customer, dan Pajak mengikuti entitlement terkait;
- Company switch kembali ke Home dan memuat ulang catalog;
- navigation ke View yang tidak ada pada catalog aktif ditolak client, sementara
  API/RPC/RLS tetap menjadi boundary final.

## Authority

`GET /api/me/navigation-catalog` memerlukan bearer session dan active Company.
Server membaca profile, membership aktif, serta `company_features`, kemudian
membangun catalog dari stable ID pada `src/lib/navigation-catalog.ts`. Client
hanya memetakan `iconKey` ke icon lokal. Catalog bukan pengganti authorization
API/RPC/RLS dan tidak membuka granular ACL baru.

## Evidence Lokal

- scoped ESLint: PASS;
- `tsc --noEmit`: PASS;
- Next production build: PASS, 53 static pages;
- route `/api/me/navigation-catalog` terdeteksi dynamic;
- tidak ada migration, data mutation, grant, atau Supabase rollout.

## Authenticated Smoke Wajib

1. Owner/Admin: Home tidak memiliki hero/statistik; card membuka landing.
2. Purchase hanya Supplier Order dan Retur Pembelian; Faktur/Pembayaran
   Supplier berada di Finance.
3. Feature OFF: Expense, Saldo Customer, dan Pajak tidak muncul; setelah enable
   dan refresh muncul kembali.
4. Store Manager, Warehouse Admin, Finance, dan Accounting: cocokkan card dengan
   matrix UXD-1; mutation tetap mengikuti tombol/API masing-masing.
5. Cashier tidak memperoleh aplikasi Backoffice.
6. Multi-Company: buka submodul, ganti Company, pastikan kembali ke Home dan
   catalog Company lama tidak terbawa.
7. Home → modul → submodul → Back kembali ke landing modul; Home/logo kembali
   ke daftar aplikasi; sidebar tetap dapat discroll.
8. Role tanpa hak tetap ditolak endpoint modul saat mencoba API manual.

## Rollback dan Next Step

Rollback UI tidak mempunyai schema/data impact dan tidak boleh menurunkan guard
API/RPC/RLS. Setelah smoke PASS, mulai BRD-1 Company branding/logo preflight.
