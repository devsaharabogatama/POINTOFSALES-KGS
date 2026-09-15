# Backoffice Sales — Safe Development and Release Plan

**Authority date:** 2026-09-08  
**Status:** DEVELOPMENT BASELINE PARTIAL / AUTH ACTOR SETUP REQUIRED  
**Production:** UNTOUCHED  
**Feature:** OFF

Dokumen ini adalah execution authority untuk business process opsional
`BACKOFFICE_DELIVERED_QTY_INVOICE`. Bila catatan lama bertentangan, dokumen ini
menang. Tidak boleh melewati environment gate atau menganggap PostgreSQL
biasa/mock sebagai bukti integrasi Supabase.

## 1. Batas kemampuan saat ini

- Full Supabase lokal membutuhkan Docker-compatible runtime; runtime tersebut
  tidak tersedia pada laptop saat ini.
- PostgreSQL lokal boleh dipakai untuk parser/domain experiment, tetapi bukan
  bukti Auth, JWT, RLS, PostgREST, RPC privilege, Storage, atau client Supabase.
- Development hanya boleh berlanjut memakai project Supabase Development yang
  terpisah dari production.
- Bila Docker dan project Development sama-sama tidak tersedia, pekerjaan
  berhenti pada desain.

## 2. Environment wajib

```text
Browser lokal -> Backoffice/PWA lokal -> Supabase Development (dummy data)
Production MADS -> tidak disentuh selama development
```

Project Development harus mempunyai URL/key sendiri, data dummy, dan marker
environment. Secret tidak boleh ditaruh di client, Git, log, dokumentasi, atau
chat. Startup guard lokal harus menolak project reference production.

## 3. Gate berurutan

1. **Production freeze:** jangan jalankan SQL draft, migration, deployment, atau
   enablement Backoffice Sales pada production.
2. **Development environment:** buat project Supabase Development terpisah,
   simpan credential hanya pada env lokal yang di-ignore, dan pasang production
   project-ref denylist.
3. **Reproducible baseline:** audit ledger lalu bangun schema existing dari
   migration repository pada database Development kosong. Reset dan ulangi.
   Bila tidak reproducible, hentikan feature work dan perbaiki migration chain.
4. **Existing regression baseline:** dengan dummy fixture dua Company dan role
   representatif, buktikan POS, Draft/Confirm, Invoice/SJ, Reservation, Stock,
   Payment, Finance, RLS, dan direct-write boundary existing masih bekerja.
5. **Business contract freeze:** kunci status/disposition Transit, approval
   overage, penutupan sisa SO, serta penomoran DO Backorder.
6. **Additive identity foundation:** feature default OFF, immutable source/mode,
   permission, tenant, audit, idempotency, dan version. Tidak ada final effect.
7. **Quotation/SO vertical slice:** Draft/Sent/Confirmed/Canceled, price/date/
   due-date snapshot, exact retry, stale version, concurrency, dan zero
   Stock/Finance effect.
8. **Reservation:** On Hand tidak berubah; Available, shortage, partial reserve,
   release, multiple allocation, multi-Company, dan concurrency direkonsiliasi.
9. **DO/Transit/acceptance:** multiple DO, partial Dispatch, Backorder,
   discrepancy, Gudang-to-Transit, Customer Received, Movement, FIFO, audit.
10. **Multiple Invoice:** gunakan expand-migrate-contract; jangan melepas unique
    current sebelum seluruh consumer retail kompatibel. Invoice tidak boleh
    melebihi Qty To Invoice dan satu SO boleh mempunyai 0..N Invoice.
11. **Finance:** COGS/Inventory pada acceptance, Delivered Not Invoiced,
    Revenue/AR pada Invoice, Advance/Clearing, Payment, Return/Credit Note,
    period dan controlled queue.
12. **Client/UAT Development:** UI memakai RPC nyata Development; fixture hanya
    data. Jalankan matrix POS/Backoffice, role, two Company, retry, stale,
    concurrency, partial/full, Return, offline, dan historical compatibility.
13. **Production rollout:** hanya atas perintah user; backup, preflight,
    expand-only migration feature OFF, postflight, smoke retail, pilot satu
    Company, monitor, lalu enablement bertahap.

## 4. Status evidence wajib

Status tidak boleh digabung atau dilebihkan:

- `SOURCE READY`
- `DEVELOPMENT DATABASE PASS`
- `CLIENT DEVELOPMENT SMOKE PASS`
- `REGRESSION PASS`
- `UAT PASS`
- `PRODUCTION NOT DEPLOYED` atau `PRODUCTION DEPLOYED`

PASS dengan runtime row nol bukan behavioral evidence. Setiap migration wajib
memiliki preflight, guard, postflight, behavioral test, authenticated smoke,
compatibility evidence, serta rollback/forward-fix note.

## 5. Current state

- Phase 0 source audit PASS pada isolated Development.
- Migration process identity `20260908100000` DATABASE PASS; feature tetap OFF.
- Migration Quotation/SO persistence foundation `20260908110000` DATABASE PASS:
  empat relation RLS terisolasi, browser privilege nol, immutable history
  trigger aktif, dan zero Stock/Delivery/Invoice/Finance effect.
- Runtime database Quotation/SO `20260908120000` dan digest forward-fix
  `20260908121000` sudah PASS pada isolated Development. Rollback behavior
  membuktikan Draft/Sent/Confirmed/Canceled, exact retry, conflict, stale
  version, audit, dan zero downstream effect. Client UI, authenticated browser
  smoke, Reservation, DO, multiple Invoice, dan Finance belum diimplementasikan.
- Full integration authority adalah isolated Supabase Development
  `fkywtxucmyjvpwdiqpix`, bukan PostgreSQL lokal kosong.

## 6. Next action tunggal

Implementasikan client vertical slice Quotation/SO hanya untuk environment
Development dan konsumsi 7 RPC guarded yang sudah tersedia. Feature tetap OFF
secara permanen; aktifkan sementara hanya pada fixture/smoke terkontrol. Setelah
authenticated browser smoke dan regression POS PASS, baru lanjut ke Reservation
dan DO sebagai migration/gate terpisah. Invoice dan Finance tetap deferred.

## 7. Evidence target lama yang dibatalkan

Audit sebelumnya dijalankan read-only terhadap
`POINTOFSALES-KGS-STAGING`. Project itu bukan project Development baru yang
dimaksud user, sehingga seluruh hasil baseline/ledger staging tidak sah sebagai
bukti environment baru. Tidak ada reset, migration, INSERT, UPDATE, DELETE,
deployment, atau enablement yang dilakukan. Usulan reset staging dibatalkan.

## 8. Historical staging observations (bukan gate project baru)

- Management API: `POINTOFSALES-KGS-STAGING` `ACTIVE_HEALTHY`.
- CLI linked marker: STAGING `true`, production `false`.
- Isolation launcher: `ENVIRONMENT_GUARD=PASS`, `PRODUCTION_ACCESS=DENIED`.
- Remote migration list: staging berhenti pada `20260814170000`; migration lokal
  mulai `20260818090000` masih pending.
- OpenAPI/table audit hanya visibility evidence; object yang tidak diberikan
  privilege ke `service_role` dapat tidak muncul. Catalog authority memakai
  `supabase db query --linked` dengan diagnostic read-only
  `backoffice_sales_development_baseline_preflight.sql`.
- Catalog preflight: active Finance queue dan nonterminal Offline submission
  nol; feature Backoffice belum ada. Enam relation dan empat RPC current masih
  belum terpasang.
- Ledger drift nyata: `supabase_migrations` berhenti pada `20260814170000`,
  sedangkan custom application ledger mempunyai enam versi manual tambahan:
  `20260820100000`, `20260825100000`, `20260825110000`, `20260825120000`,
  `20260825130000`, dan `20260825131000`.
- `db push` tidak boleh dijalankan pada state ini karena akan mencoba memutar
  ulang migration manual. Gate berikutnya membutuhkan persetujuan eksplisit
  untuk mereset project STAGING (menghapus fixture 1 Company/2 Sale), kemudian
  membangun migration chain dari nol dua kali.
