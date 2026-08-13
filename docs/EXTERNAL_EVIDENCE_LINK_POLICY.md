# Kebijakan Link Bukti dan Foto Eksternal

**Status:** Business/design decision approved; belum memerintahkan implementasi Storage  
**Berlaku:** Seluruh company dan modul yang memakai bukti pembayaran, foto, atau attachment  
**Strategi sementara:** Google Drive/external link untuk bukti transaksi;
Company logo adalah exception branding terpisah yang direncanakan

---

## 1. Tujuan

Pada fase Supabase/Vercel free-tier, aplikasi tidak menyimpan binary foto/bukti ke Supabase Storage atau meneruskannya melalui Vercel Function. User mengunggah file ke Google Drive terlebih dahulu, lalu menempelkan link pada dokumen transaksi.

Kebijakan ini berlaku sampai ada keputusan eksplisit untuk memakai Storage milik aplikasi.

---

## 2. Scope Awal

- bukti pembayaran Transfer yang diinput Cashier;
- bukti refund Transfer;
- bukti Expense/settlement Transfer;
- bukti Setor Kas;
- bukti Ketul Customer/Vendor;
- bukti pembayaran Tempo/Recovery;
- foto Produk atau foto operasional lain yang nanti ditambahkan.

Company logo tidak termasuk evidence transaksi. Instruksi user 2026-08-11
membuka exception terbatas untuk upload logo ke storage branding aplikasi agar
dapat dipakai pada Invoice dan Surat Jalan. Exception tersebut wajib mengikuti
`PREDEPLOY_MODULAR_HOME_BRANDING_SALES_DOCUMENT_PLAN.md` dan tidak memperluas
hak upload bukti pembayaran/foto operasional.

Cash dan metode non-Transfer tetap boleh memiliki link bukti bila workflow membutuhkannya, tetapi field Transfer harus selalu tersedia pada form terkait.

---

## 3. Data Minimum

```text
evidence_url nullable
evidence_provider = GOOGLE_DRIVE | EXTERNAL_URL
evidence_label nullable
evidence_note nullable
evidence_added_by
evidence_added_at
evidence_updated_by nullable
evidence_updated_at nullable
```

- URL harus `https`.
- Scope awal menyimpan link/metadata saja; server tidak mengunduh, menyalin, memindai, membuat thumbnail, atau mem-proxy file.
- Link tidak dianggap bukti pembayaran sudah verified. Status verification tetap keputusan Finance/authority melalui workflow transaksi.
- Dokumen posted menyimpan audit perubahan link. Penggantian link tidak boleh mengubah nominal/status jurnal secara otomatis.

---

## 4. Hak Akses

- Cashier dapat mengisi/mengoreksi link selama dokumen masih pada status yang mengizinkan input bukti.
- Finance, Company Admin, dan Super Admin dapat melihat link sesuai company scope.
- Store Manager melihat link sesuai store scope bila workflow modul memberinya akses.
- Link tidak boleh muncul pada receipt Customer atau export publik kecuali ada keputusan modul khusus.
- Backend/RLS tetap melindungi row metadata. Keamanan file Drive mengikuti sharing permission pada Google Drive dan menjadi tanggung jawab operasional company.

---

## 5. UI dan Validasi

- Form menyediakan field **Link Bukti Transfer (Google Drive)** dan helper text untuk mengunggah file ke Drive lalu menempelkan link.
- Backoffice menyediakan aksi **Buka Bukti** yang membuka URL pada tab baru dengan proteksi `noopener/noreferrer`.
- UI menampilkan status `BELUM ADA LINK` atau `LINK TERSEDIA`, bukan thumbnail wajib.
- Mode bukti dapat `OPTIONAL` atau `REQUIRED` sesuai konfigurasi modul/company/store yang sudah disetujui.
- Jika `REQUIRED`, dokumen tidak dapat masuk status confirmation/final yang ditentukan workflow sebelum URL valid tersedia.
- Aplikasi tidak mencoba mengecek apakah user Finance memiliki permission Drive; kegagalan akses ditangani secara operasional dengan mengganti sharing/link.

---

## 6. Guardrail Keamanan dan Biaya

- Jangan meminta Google access token atau kredensial Drive pada scope awal.
- Jangan memakai service-role key di client.
- Jangan membuat Vercel route untuk proxy/download file eksternal.
- Jangan melakukan server-side fetch ke URL bukti; ini mencegah SSRF, bandwidth, dan invocation tambahan.
- Jangan menyimpan base64/blob/file bytes di PostgreSQL.
- Link berbahaya atau non-HTTPS ditolak; allowlist Google Drive dapat ditambahkan melalui konfigurasi bila company hanya mengizinkan Drive.
- Migrasi ke Storage internal nanti harus memiliki dokumen, quota model, private bucket/RLS, retention, rollout, dan rollback terpisah.

---

## 7. Instruksi untuk AI Agent

- Baca file ini untuk task bukti pembayaran/foto/attachment.
- Jangan menambahkan upload Supabase Storage atau proxy Vercel tanpa keputusan user baru.
- Jangan menganggap URL eksternal sebagai payment verification.
- Simpan source document, actor, timestamp, dan audit perubahan link.
- Implementasi harus tetap tenant-scoped walaupun file berada di luar aplikasi.

---

## 8. Decision Log

| Tanggal | Keputusan | Status |
|---|---|---|
| 2026-07-19 | Bukti Transfer Cashier memakai link yang dapat dilihat Finance | APPROVED |
| 2026-07-19 | File/foto disimpan sementara di Google Drive, bukan Supabase Storage | APPROVED |
| 2026-07-19 | Aplikasi hanya menyimpan URL/metadata dan tidak mem-proxy file | APPROVED |
| 2026-07-19 | Link bukan payment verification; status tetap dikonfirmasi melalui workflow Finance | APPROVED |
| 2026-08-11 | Upload internal dibuka hanya untuk logo Company; bukti transaksi tetap external-link | APPROVED ROADMAP, belum implemented |
