# Catatan Struktur Development, Traceability, dan Free-Tier

**Status:** Pedoman untuk fase implementasi; belum memerintahkan pemindahan file/kode saat ini.  
**Tujuan:** Membuat perubahan mudah dilacak, membatasi bacaan AI agent, dan menjaga konsumsi Vercel/Supabase tetap efisien.

---

## 1. Prinsip Utama

1. Satu keputusan bisnis memiliki satu source of truth.
2. Agent membaca entrypoint dan modul yang disentuh, bukan seluruh repository.
3. Route/UI tipis; aturan bisnis berada pada domain/service/RPC modul.
4. Mutation penting transactional, tenant-scoped, idempotent, dan terukur.
5. Optimasi quota tidak boleh mengorbankan RLS, audit, atau konsistensi stock/Finance.
6. Secret dan service-role hanya server-side.
7. Prioritas implementasi adalah POS retail yang berjalan; extensibility Manufacture/HR/Logistik mengikuti `ERP_EVOLUTION_ARCHITECTURE_NOTES.md` tanpa memperluas scope sekarang.

---

## 2. Target Foldering Fase Implementasi

Struktur target, diterapkan bertahap ketika coding dimulai:

```text
docs/
  README.md                         # router dokumen
  modules/
    inventory/README.md             # kontrak ringkas + pointer
    pos/README.md
    sales-pricing/README.md
    customer/README.md
    finance/README.md
    purchasing/README.md
    ketul/README.md
  decisions/                        # ADR lintas modul, hanya keputusan arsitektur
  runbooks/                         # deploy, migration, recovery

backoffice/src/
  app/                              # page dan route adapter tipis
  modules/
    pos/
      README.md                     # entrypoint agent
      domain/
      server/
      ui/
      validation/
      tests/
    inventory/
    sales-pricing/
    customer/
    finance/
    purchasing/
  shared/                           # hanya primitive yang benar-benar lintas modul

supabase/
  migrations/                       # immutable, urut
  modules/                          # source SQL/RPC terkelompok bila diperlukan
    pos/
    inventory/
    finance/
    purchasing/
  tests/
    pos/
    inventory/
    rls/
```

Jangan memindahkan file existing sekaligus. Buat migration map, perbarui import/path, lalu verifikasi per modul.

Gunakan modular monolith selama kebutuhan/measurement belum membuktikan perlunya service terpisah. Jangan membuat tabel kosong, message broker, atau abstraction generik untuk future module hanya demi label ERP-ready. Folder Manufacture/HR/Logistik dibuat ketika scope development-nya benar-benar dibuka.

---

## 3. Isi Minimum README Modul

Setiap `modules/<module>/README.md` harus singkat dan memuat:

```text
Scope dan non-scope
Business source-of-truth document
Feature entitlement
Role/access summary
Tables/views/RPC
API routes
UI entrypoints
State machine/status
Idempotency/transaction boundary
Events consumed/emitted
Tests wajib
Open decisions
Last verified commit/date
```

Agent yang mengubah satu modul wajib membaca:

1. `docs/README.md`;
2. README modul;
3. source-of-truth yang ditunjuk;
4. file kode/test yang benar-benar berada pada execution path.

Agent tidak perlu membaca semua spesifikasi lain kecuali README menyatakan dependency lintas modul.

---

## 4. Aturan Traceability

- Setiap mutation memiliki `request_id`/idempotency key dan source document.
- Log minimum: module, action, company, store, actor, request/correlation ID, source ID, result, duration, error code.
- Jangan log access token, secret, password, full payment credential, atau payload PII besar.
- Error code stabil dan dapat dicari dari UI sampai API/RPC.
- Setiap migration memiliki test/verification query dan rollback/forward-fix note.
- Setiap perubahan status final memakai event/reversal; tidak overwrite histori.
- Decision log business tetap di spesifikasi modul; ADR hanya untuk keputusan teknis lintas modul agar tidak terjadi duplikasi.

---

## 5. Pedoman Hemat Vercel/Supabase

### Request dan compute

- Gunakan satu RPC transactional untuk checkout/posting kompleks.
- Hindari N+1 request dari UI; batch lookup dan projection field.
- Cache master stabil dan gunakan incremental sync/version cursor.
- Jangan refetch seluruh katalog setelah satu mutation kecil.
- Pagination wajib untuk list/history/report.
- Report/export berat on-demand, bukan dihitung pada setiap page load.

### Database

- Index dibuat dari query/RLS nyata, bukan semua kolom.
- Hindari index duplikat dan JSON payload besar tanpa kebutuhan query.
- `current_balance`/summary boleh menjadi cache, tetapi ledger tetap source of truth.
- Notification event penting disimpan satu kali; pending badge dihitung dari status source.
- Tetapkan retention untuk transient sync log, notification delivery, import staging, dan generated export; histori finansial/stock final tidak boleh dipangkas sembarang.

### Network dan storage

- Bukti pembayaran, foto Produk, dan attachment memakai Google Drive/external HTTPS link pada scope awal sesuai `EXTERNAL_EVIDENCE_LINK_POLICY.md`.
- Simpan URL/metadata saja; jangan simpan blob/base64 di PostgreSQL atau upload ke Supabase Storage sebelum keputusan kapasitas baru.
- Jangan proxy/download file eksternal melalui Vercel Function dan jangan server-side fetch URL bukti.
- Link bukti bukan payment verification; status tetap diputuskan workflow Finance.

- Gambar dikompres WebP/JPEG, lazy-load, thumbnail seperlunya.
- Checkout response tidak membawa gambar atau master record penuh.
- Static asset memakai browser/CDN cache dengan versioned filename.
- PDF/Excel dibuat saat diminta dan dibersihkan sesuai retention policy.

### Realtime dan polling

- Realtime hanya untuk event yang benar-benar perlu instan.
- Polling ringan berhenti ketika tab hidden dan memakai backoff saat error/offline.
- Satu notification/badge terkelompok lebih baik daripada subscription per row/product.

### Observability

- Gunakan structured log ringkas dan sampling untuk success path ramai.
- Error/exception tetap lengkap tetapi tanpa secret/PII sensitif.
- Ukur p50/p95 duration, request count, response bytes, DB rows, dan egress sebelum optimasi.

---

## 6. Gate Sebelum Coding Modul

Sebelum implementasi:

1. tandai source-of-truth dan open decision;
2. petakan execution path existing;
3. tentukan tenant/RLS boundary;
4. tentukan transaction/idempotency boundary;
5. estimasi request/row/egress budget;
6. tulis test matrix happy path, retry, cross-tenant, dan failure;
7. baru ubah schema/API/UI secara bertahap.

Setelah implementasi:

1. jalankan test modul dan RLS;
2. ukur request graph dan payload;
3. bandingkan dengan capacity model;
4. perbarui README modul dan router dokumen;
5. jangan mengubah status requirement menjadi “implemented” tanpa bukti execution path.
