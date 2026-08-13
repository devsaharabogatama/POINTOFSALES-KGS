# BRD-2 Company Branding Upload dan UI

**Status:** LOCAL READY — AUTHENTICATED SMOKE PENDING  
**Dependency:** BRD-1 migration/postflight/behavior user-reported ALL PASS

## Implementasi

- `GET/POST/DELETE /api/platform/company-branding` selalu mengambil Company
  dari active-company context server, bukan ID dari form/query.
- GET tersedia untuk user yang memiliki akses Company; mutation hanya Super
  Admin atau membership Owner/Admin aktif.
- file bytes diproses di Route Handler Node.js; service-role tetap di modul
  `server-only` dan tidak dikirim ke client.
- PNG/JPEG/WebP maksimal 2 MiB; server memeriksa magic bytes, MIME, extension,
  ukuran, dan SHA-256.
- object path dibuat server berdasarkan Company, logo version, dan checksum.
- metadata hanya diaktifkan sesudah object ada; kegagalan RPC membersihkan
  object baru. Object lama dihapus setelah replace/remove berhasil.
- UI berada di `Platform -> Logo Perusahaan`, memakai modal internal yang dapat
  ditutup dengan Escape dan tidak menampilkan UUID/path/checksum kepada user.

## Manual Smoke

Restart Backoffice agar Route Handler baru terbaca, lalu:

1. Masuk sebagai Owner/Admin Company A dan buka Platform -> Logo Perusahaan.
2. Upload PNG/JPEG/WebP valid di bawah 2 MiB; refresh dan pastikan logo tetap.
3. Ganti logo; versi bertambah dan gambar lama tidak lagi aktif.
4. Hapus logo melalui modal; fallback `Tanpa logo` kembali.
5. Coba file kosong, lebih dari 2 MiB, SVG/PDF, dan file yang extension-nya
   diubah palsu; seluruhnya harus ditolak tanpa branding aktif berubah.
6. Buka dua tab, ganti logo dari tab pertama, lalu submit versi lama dari tab
   kedua; tab kedua harus menerima konflik dan diminta memuat ulang.
7. Pastikan logo tampil di samping nama Company pada header; klik logo harus
   kembali ke halaman aplikasi/Home.
8. Buka Fast Link dan cari nama menu maupun nama modul. Hasil hanya boleh
   berasal dari menu catalog server yang diizinkan untuk akses aktif.

## Multi-Company Isolation

Gunakan satu akun Super Admin atau akun multi-Company:

1. Pada Company A pasang logo A.
2. Switch ke Company B. Halaman harus remount dan tidak menampilkan logo A.
3. Pasang logo B, lalu switch A/B berulang; masing-masing hanya menampilkan
   logonya sendiri.
4. Saat Company A aktif, request GET tidak boleh mengembalikan `companyId` B.
5. Owner/Admin A tanpa membership B tidak boleh mengelola logo B lewat direct
   API/RPC.
6. Role Store Manager/Finance/Accounting/Cashier tidak melihat menu mutation;
   direct POST/DELETE harus 403.
7. Cari nama menu terlarang pada Fast Link tiap role; hasil tidak boleh muncul
   dan input search tidak boleh membuat jalur akses baru.

## Evidence Lokal

- scoped ESLint: PASS;
- `tsc --noEmit`: PASS;
- Next.js 16.2.10 production build: PASS, 54 static pages dan dynamic route
  `/api/platform/company-branding` terdeteksi;
- `git diff --check`: PASS;
- authenticated Storage/UI smoke: menunggu user.

BRD-2 belum mengubah snapshot dokumen. Penyematan logo ke Sales Invoice/Surat
Jalan baru dilakukan pada SLD phase agar dokumen final tetap immutable.
