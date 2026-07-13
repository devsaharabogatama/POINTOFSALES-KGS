# WORKFLOW & PROGRESS: KGS MINI-ERP

Dokumen ini adalah acuan kerja (*workflow*) dan pelacakan progres proyek migrasi **KGS Mini-ERP** agar pengembangan tetap terarah dari awal hingga siap dideploy.

---

## 📋 Alur Kerja (Workflow)
Setiap penambahan fitur atau perbaikan kode harus mengikuti langkah-langkah berikut:
1. **Verifikasi Skema**: Pastikan kolom database di Supabase sesuai dengan perubahan kode.
2. **Pengujian Lokal**: Selalu jalankan `npm run build` pada folder `pwa` atau `backoffice` untuk memastikan tidak ada kesalahan TypeScript/linting sebelum berpindah ke modul lain.
3. **Pemberian Tanda Progres**: Perbarui checklist progres di bawah ini setelah menyelesaikan sebuah milestone.

---

## 📈 Peta Progres Proyek (Roadmap & Progress)

### 🟢 Fase 1: Database Setup (Supabase)
* [x] Inisiasi proyek Supabase dan eksekusi skema PostgreSQL dasar ([supabase/schema.sql](file:///C:/Users/sbi_l/OneDrive/Documents/POINT%20OF%20SALES/supabase/schema.sql)).
* [x] Konfigurasi RLS (Row Level Security) untuk Cashier, Manager, dan Owner.
* [ ] Aktifkan Supabase Realtime untuk tabel `product_stocks`.

### 🟢 Fase 2: Struktur & Kerangka Dasar Proyek
* [x] Struktur folder Monorepo Terpisah:
  * `pwa/` : Aplikasi Kasir (PWA & Mobile-ready).
  * `backoffice/` : Panel Manajerial & API Serverless.
* [x] Konfigurasi TailwindCSS v4 pada kedua aplikasi.
* [x] Mockup Premium POS Kasir ([pwa/src/App.tsx](file:///C:/Users/sbi_l/OneDrive/Documents/POINT%20OF%20SALES/pwa/src/App.tsx)).
* [x] Mockup Premium Backoffice Dashboard ([backoffice/src/app/page.tsx](file:///C:/Users/sbi_l/OneDrive/Documents/POINT%20OF%20SALES/backoffice/src/app/page.tsx)).
* [x] Validasi kompilasi build lokal (keduanya sukses).

### 🟢 Fase 3: Integrasi Supabase & Offline-First POS (PWA)
* [x] Konfigurasi Supabase Client dan file `.env` di `pwa/` & `backoffice/`.
* [x] Inisialisasi skema **Dexie.js** (`db.ts`) untuk basis data lokal (IndexedDB) di sisi POS.
* [x] Pembuatan modul penarikan data master (katalog produk, pelanggan, sesi) ke local cache.
* [x] Logic sinkronisasi transaksi offline ke server ketika koneksi kembali online (`/api/pos/sync`).

### 🟢 Fase 4: Serverless API & Worker Akuntansi (Backoffice)
* [x] Endpoint Checkout `/api/pos/checkout` (transaksi ACID postgres & pencatatan `financial_events`).
* [x] Background Worker `/api/worker/process-queue` (asynchronous double-entry generator).
* [x] Logic posting otomatis ke `journal_entries` (debit/kredit seimbang) berdasarkan tipe event.
* [x] Otomatisasi Rekonsiliasi Kasir (`pos_reconciliations`).

### 🟢 Fase 5: Modul Manajemen Backoffice
* [x] Manajemen Produk & Stok Gudang (KGS vs GDS) termasuk pemindahan stok (*stock transfer*).
* [x] Log Pengajuan & Persetujuan Beban / Cash Advance.
* [x] Log Setoran Tunai ke Bank (`bank_deposits`).
* [x] Laporan Finansial (Buku Besar, Neraca, Laba/Rugi).

### 🟢 Fase 6: PWA & Deployment
* [x] Konfigurasi plugin Vite PWA (`manifest.json` & Service Worker untuk caching asset offline).
* [x] Konfigurasi WebBluetooth / WebUSB ESC/POS printing driver pada POS.
* [x] Deployment aplikasi Backoffice ke Vercel.

---

## 🛠️ Ringkasan Perintah Penting

| Aplikasi | Masuk Folder | Mode Dev | Mode Build |
| :--- | :--- | :--- | :--- |
| **POS Kasir (PWA)** | `cd pwa` | `npm run dev` | `npm run build` |
| **Backoffice** | `cd backoffice` | `npm run dev` | `npm run build` |
