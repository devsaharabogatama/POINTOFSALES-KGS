# Handoff Simulasi Kuota Satu Transaksi POS

**Status:** Input untuk analisis eksternal, bukan hasil perhitungan  
**Tujuan:** Dokumen ini dapat diberikan kepada GPT/Gemini untuk menghitung estimasi konsumsi kuota Vercel dan Supabase dari satu transaksi POS serta proyeksi bulanannya.  
**Batas:** Jangan mengubah kode/schema berdasarkan estimasi sebelum asumsi dan hasil pengukuran nyata diverifikasi.

---

## 1. Output yang Diminta dari AI Analis

AI analis harus menghasilkan:

1. konsumsi Supabase per satu transaksi;
2. konsumsi Vercel per satu transaksi;
3. biaya bersama yang diamortisasi per transaksi;
4. proyeksi harian/bulanan pada beberapa volume;
5. batas transaksi sebelum setiap kuota free tier mendekati limit;
6. bottleneck pertama dan rekomendasi optimasi;
7. tabel asumsi, rumus, sumber resmi, tanggal pengecekan, dan tingkat keyakinan;
8. daftar data yang masih harus diukur dari aplikasi nyata.

Jangan hanya memberi angka akhir. Pisahkan **fakta plan terkini**, **asumsi desain**, **estimasi**, dan **hasil pengukuran**.

---

## 2. Langkah Analisis Wajib

### Langkah A — Ambil kuota plan terkini

- Buka dokumentasi/pricing resmi Vercel dan Supabase.
- Catat nama plan, tanggal akses, region bila relevan, satuan quota, reset period, serta overage/behavior ketika limit tercapai.
- Jangan memakai angka quota dari ingatan model.
- Jangan meminta atau menampilkan API key, service-role key, password, atau isi `.env.local`.

### Langkah B — Definisikan skenario transaksi

Hitung minimal skenario berikut secara terpisah:

1. **Baseline Online Cash:** customer Walk-In, 3 line stock biasa, satu payment Cash, satu receipt.
2. **Online Customer/Pricelist:** customer terdaftar, resolver Pricelist, diskon, rounding, Customer Balance disabled.
3. **Online Bundle:** satu Bundle dengan beberapa komponen/FIFO allocation.
4. **Online Electronic Payment:** QRIS/Transfer/Card dengan verification/reference.
5. **Offline Sync:** transaksi `PENDING_SYNC`, allowance consumption, sync, acknowledgement, dan Slip Offline.
6. **Exception:** retry idempotent atau `OFFLINE_PAYMENT_EXCEPTION`.

Laporkan baseline lebih dahulu; variant hanya menghitung delta terhadap baseline.

### Langkah C — Petakan request graph

Untuk setiap skenario, inventarisasi:

```text
browser/PWA request
-> Vercel route/function/static asset
-> Supabase Auth/REST/RPC/Storage/Realtime
-> PostgreSQL reads/writes/indexes
-> response payload
-> polling/realtime/notification side effects
```

Pisahkan request yang terjadi **per transaksi** dari request yang hanya terjadi per login, per sesi, per page load, per cache refresh, atau background polling.

### Langkah D — Inventarisasi Supabase

Estimasi dan jelaskan:

- Auth/MAU impact;
- jumlah REST/RPC/function call;
- database read/write statement;
- row insert/update per tabel;
- perkiraan row bytes dan index bytes;
- pertumbuhan database bulanan;
- database/network egress response;
- Storage request/egress bila receipt/file digunakan;
- Realtime messages/concurrent connection bila aktif;
- Edge Function invocation/duration bila digunakan;
- WAL/log/backup overhead hanya jika plan menghitungnya dan sumber resmi mendukung.

Jangan menganggap satu SQL transaction sama dengan satu row write. Tunjukkan tabel/row yang diperkirakan berubah.

### Langkah E — Inventarisasi Vercel

Estimasi dan jelaskan:

- function/edge invocation;
- execution duration dan memory/CPU metric yang dikenakan plan;
- request/response bandwidth;
- image optimization bila gambar Produk ikut dimuat;
- static/cache hit versus dynamic request;
- build/deployment cost dipisahkan dari transaksi runtime;
- log/observability usage bila dikenakan quota;
- cron/background job dipisahkan dari per-transaction cost.

### Langkah F — Hitung shared cost

Biaya berikut tidak boleh seluruhnya dibebankan ke satu transaksi:

- login/session refresh;
- download katalog/cache;
- polling notification;
- stock refresh;
- open/close Cashier Session;
- allowance allocation;
- deployment/build;
- monitoring/log retention.

Gunakan rumus:

```text
amortized_cost_per_tx = shared_cost_per_period / transaction_count_per_period
total_cost_per_tx = direct_transaction_cost + amortized_cost_per_tx
```

### Langkah G — Proyeksi volume

Minimal simulasi:

| Skenario | Transaksi/hari | Hari/bulan | Store | Terminal/store |
|---|---:|---:|---:|---:|
| Kecil | 100 | 30 | 1 | 1 |
| Sedang | 500 | 30 | 3 | 2 |
| Tinggi | 2.000 | 30 | 10 | 3 |

Hitung juga 5%, 20%, dan 50% transaksi offline bila desain offline aktif. Gunakan headroom minimum 30%; jangan merencanakan pemakaian sampai 100% quota.

### Langkah H — Sensitivity analysis

Uji dampak perubahan:

- jumlah line per transaksi;
- jumlah FIFO batch yang dikonsumsi;
- ukuran payload/gambar;
- polling interval;
- penggunaan Realtime;
- persentase offline retry;
- retention log/notification/import history;
- jumlah index pada tabel transaksi.

---

## 3. Data Aplikasi yang Harus Diminta/Diukur

Jika kode sudah tersedia, AI analis harus meminta atau membaca:

- route checkout dan sync aktif;
- RPC/function SQL yang benar-benar dipanggil;
- schema tabel serta index;
- middleware/auth refresh;
- ukuran response katalog dan checkout;
- log invocation/duration Vercel;
- Supabase usage dashboard sebelum/sesudah controlled test;
- jumlah row sebelum/sesudah satu transaksi;
- Network panel browser untuk request count dan transferred bytes.

Controlled test yang disarankan:

1. catat baseline usage;
2. jalankan 100 transaksi test identik pada environment aman;
3. catat usage sesudahnya;
4. kurangi background/shared traffic;
5. bagi delta dengan 100;
6. bandingkan hasil pengukuran dengan estimasi teoretis.

Satu transaksi terlalu kecil untuk membaca perubahan dashboard secara andal; batch test mengurangi noise.

---

## 4. Format Tabel Hasil

### Per transaksi

| Provider | Meter/Quota | Direct per Tx | Shared per Tx | Total per Tx | Confidence | Evidence |
|---|---|---:|---:|---:|---|---|

### Pertumbuhan database

| Table/Index | Rows per Tx | Bytes per Row | Bytes per Tx | Monthly Rows | Monthly Bytes |
|---|---:|---:|---:|---:|---:|

### Proyeksi plan

| Volume | Vercel % | Supabase DB % | Supabase Egress % | Supabase MAU % | First Bottleneck | Headroom |
|---|---:|---:|---:|---:|---|---:|

---

## 5. Prompt Siap Diberikan ke GPT/Gemini

```text
Anda bertugas membuat capacity model untuk aplikasi POS Next.js/Vercel + Supabase.

Baca dokumen CAPACITY_SIMULATION_HANDOFF.md dan dokumen modul yang ditunjuk oleh docs/README.md. Jangan mengubah kode. Gunakan pricing/quota resmi Vercel dan Supabase yang berlaku saat analisis, sertakan link dan tanggal akses.

Hitung baseline satu transaksi POS dan variant online/offline. Bedakan fakta, asumsi, estimasi, dan pengukuran. Petakan request graph, row/index growth, egress, function invocation/duration, Auth/MAU, Storage, Realtime, polling, logging, serta shared cost yang harus diamortisasi.

Buat proyeksi volume kecil/sedang/tinggi dengan headroom minimal 30%. Jika data kode atau metrik belum tersedia, jangan mengarang: tulis data yang dibutuhkan dan berikan rumus spreadsheet agar angka dapat diisi kemudian. Jangan pernah meminta atau menampilkan secret/API key.
```

---

## 6. Catatan Optimasi yang Harus Diuji, Bukan Diasumsikan

- satu RPC transactional lebih hemat round trip dibanding banyak mutation client;
- katalog/master di-cache dan diambil incremental;
- list memakai pagination dan field projection;
- notification event-based dan pending badge dihitung dari status, bukan reminder row berulang;
- polling dihentikan saat tab tidak aktif dan interval tidak agresif;
- gambar dikompres, lazy-loaded, dan tidak ikut response checkout;
- export/report berat dijalankan on-demand;
- retry memakai idempotency key yang sama;
- log payload besar/PII dihindari;
- index hanya dibuat berdasarkan query nyata dan diverifikasi dengan query plan.

AI analis wajib menghitung trade-off setiap optimasi terhadap konsistensi data, bukan sekadar menyatakan “gunakan cache”.
