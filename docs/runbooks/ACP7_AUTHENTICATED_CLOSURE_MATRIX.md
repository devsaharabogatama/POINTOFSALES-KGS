# ACP-7 Authenticated Closure Matrix

## Status

Database preflight tidak memiliki `BLOCKER`. Dua Company sudah aktif dan 24
permission key sudah `ENFORCED`. Tahap ini melengkapi fixture login minimal dan
menutup parity Home → direct URL → API → RPC tanpa membuat role baru.

## Fixture minimal

Sebelum menjalankan matrix, rollout dan verifikasi
`PRD_COMPANY_ACCESS_LIFECYCLE_ROLLOUT.md`. Detail user wajib menunjukkan Company
yang sedang diatur dan menyediakan guarded revoke; jangan melakukan UAT dengan
UI lama yang bergantung secara tersamar pada Company header.

Gunakan flow Backoffice; jangan membuat Auth/Profile/Membership melalui SQL.
Password dan email UAT tidak dicatat di repository.

1. Pada Company A, buat akun `Company Admin`, `Warehouse Admin`, dan `Cashier`.
   Cashier wajib mendapat Store aktif.
2. Pilih akun `Company Admin` tersebut sebagai user multi-Company. Login Super
   Admin, switch ke Company B, lalu `Tim & Akses → Tambah akses akun existing`.
   Tambahkan email akun tadi dengan role `ACCOUNTING` di Company B. Ini sekaligus
   menutup fixture role Accounting dan regular multi-Company.
3. Sebagai Super Admin, buka detail user tersebut pada masing-masing Company.
   Untuk permission yang sama, gunakan contoh aman berikut:
   - Company A: `inventory.stock_real` → `LIHAT_SAJA`;
   - Company B: `inventory.stock_real` → `TANPA_AKSES`.
4. Jalankan ulang
   `supabase/diagnostics/acp_phase7_security_closure_preflight.sql`.
   Tiga row `SETUP` harus menjadi `PASS`; seluruh `BLOCKER` tetap nol.

## Tambahan fixture PRD-1 untuk Company B

Output consolidated PRD-1 menunjukkan tepat satu Company belum memiliki
operational scope dan master minimum. Lengkapi lewat UI canonical pada Company B:

1. satu Store aktif;
2. satu POS Terminal aktif pada Store tersebut;
3. satu Warehouse aktif dengan `Sumber penjualan` aktif;
4. satu Product aktif dengan base/sales UOM;
5. satu Customer aktif (Walk-In hasil provisioning boleh memenuhi kontrak jika
   memang aktif);
6. satu Payment Method aktif dan default sesuai kontrak Company.

Reuse fixture akun agar tidak membuat user berlebihan:

- Company A: buat `COMPANY_ADMIN`, `WAREHOUSE_ADMIN`, dan `CASHIER`;
- Cashier wajib mendapat Store aktif;
- tambahkan akun `COMPANY_ADMIN` A sebagai existing user pada Company B dengan
  role `ACCOUNTING`;
- akun yang sama menjadi fixture multi-Company serta menerima override berbeda
  `inventory.stock_real` di A/B seperti langkah sebelumnya.

Setelah seluruh setup selesai, jalankan hanya dua query penutup berikut—tidak
perlu mengulang behavioral regression historis:

1. `supabase/diagnostics/acp_phase7_security_closure_preflight.sql`;
2. `supabase/diagnostics/prd_phase1_predeploy_closing_preflight.sql`.

Expected: seluruh `SETUP` menjadi `PASS`, seluruh `BLOCKER` tetap nol.

Jika role Accounting sudah dibuat sebagai akun lain sebelum langkah 2, user
multi-Company tetap boleh memakai role lain di Company B. Yang wajib adalah
satu identity non-Super-Admin memiliki membership aktif pada dua Company dan
override berbeda untuk permission yang sama.

## Matrix browser wajib

| Skenario | Harapan |
|---|---|
| Company Owner/Admin tanpa override | Menu dan action mengikuti role baseline |
| `LIHAT_SAJA` | List/detail tampil; create/edit/post/export tidak muncul dan API/RPC menolak |
| `OPERASIONAL` | Action operasional yang didukung tampil; approve/post/reversal protected tetap ditolak |
| `TANPA_AKSES` | Home, module landing, Fast Link, dan search tidak menampilkan submodul |
| Direct URL saat tanpa akses | Halaman tidak membocorkan data; API/RPC mengembalikan denial |
| Multi-Company user di Company A | Stock Real terlihat read-only sesuai override A |
| User yang sama switch ke Company B | Stock Real hilang/ditolak sesuai override B; data/cache A tidak tertinggal |
| Cashier | Hanya PWA Store/session scope; Backoffice protected module ditolak |
| Feature OFF | Menu hilang dan RPC tetap menolak meski role/preset mendukung |
| Membership dinonaktifkan saat login | Refresh/tab lama tidak boleh mempertahankan akses |
| Override diubah saat tab aktif | Hard refresh dan request berikutnya memakai keputusan terbaru |
| Exact retry override | Tidak membuat duplikat; version/audit tetap konsisten |
| Expected version lama | Ditolak `MASTER_VERSION_CONFLICT` |

## Bukti yang dicatat

- role, Company, preset, submodul, dan hasil `ALLOW/DENY`;
- HTTP/RPC error code untuk negative test, tanpa token atau payload sensitif;
- screenshot Home/Fast Link hanya bila perlu membuktikan navigation parity;
- hasil preflight ulang;
- Backoffice/PWA build dan warning performa;
- tidak ada secret atau service-role key pada client bundle/repository.

## Boundary

ACP-7 tidak memproses Finance `HOLD`, tidak membuat Journal baru, tidak membuka
Assets atau inter-Company automation, dan tidak mengubah role baseline. Setelah
matrix PASS, lanjut ke PRD-1 full pre-deploy regression dan Vercel Preview
readiness—bukan Production langsung.
