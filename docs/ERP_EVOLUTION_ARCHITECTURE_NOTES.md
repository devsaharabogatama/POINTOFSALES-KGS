# Arah Evolusi POS Menjadi ERP Modular

**Status:** Architectural direction approved; bukan scope implementasi modul baru  
**Prioritas saat ini:** Menyelesaikan dan menjalankan POS retail terlebih dahulu  
**Arah masa depan:** Finance yang matang, Manufacture, HR, Logistik, serta modul ERP lain secara bertahap

---

## 1. Prinsip POS-First, ERP-Ready

1. POS retail yang sedang dirancang harus selesai dan stabil sebelum membuka implementasi modul besar berikutnya.
2. Desain sekarang tidak boleh mengimplementasikan Manufacture, HR, Logistik, atau modul spekulatif lain secara prematur.
3. Kontrak tenant, master data, source document, status, event, audit, UOM, stock, dan Finance dibuat extensible agar modul baru dapat ditambahkan melalui migration/API baru.
4. Arsitektur awal adalah **modular monolith** pada Next.js/Supabase, bukan microservices. Ini mengurangi kompleksitas dan pemakaian free-tier sambil menjaga module boundary.
5. Ekspansi dilakukan sambil operasional POS berjalan, melalui rollout per company/feature entitlement dan backward-compatible migration.

---

## 2. Boundary Modul

Setiap modul memiliki:

```text
scope dan non-scope
owned tables/data
public command/RPC/API
events emitted/consumed
status/state machine
role/entitlement
idempotency boundary
Finance mapping
tests dan migration
README agent entrypoint
```

- Modul tidak mengubah tabel milik modul lain secara sembarang. Mutation lintas modul lewat service/RPC/source event yang ditentukan.
- Shared code hanya berisi primitive stabil seperti tenant context, auth/role, money/decimal, UOM snapshot, idempotency, audit, dan error contract.
- Hindari satu service/table `generic_erp_data` atau JSON besar sebagai tempat seluruh modul; extensibility tidak berarti menghilangkan domain constraint.
- Reporting lintas modul memakai view/read model terkontrol, bukan memberi setiap modul hak mutasi ke ledger/domain lain.

---

## 3. Kontrak Lintas Modul yang Harus Stabil

Source document/event minimum membawa:

```text
company_id
source_module
source_type
source_id
event_type
event_version
idempotency_key
correlation_id
actor_id
store_id nullable
warehouse_id nullable
occurred_at
posted_at nullable
status
```

- ID immutable dan tenant-scoped.
- Event contract versioned dan backward compatible; consumer tidak mengandalkan label UI.
- Posted event append-only. Correction memakai reversal/replacement/source correction.
- Finance journal mereferensikan source event, bukan membaca asumsi dari nama tabel.
- Pada fase awal event dapat diproses transactional dalam database/outbox ringan; tidak perlu message broker eksternal sebelum volume membuktikan kebutuhan.

---

## 4. Roadmap Boundary

### Fase 1 — POS Retail yang Berjalan

- tenant/role dan company switching;
- Product/UOM/Category/Warehouse/Supplier/Customer master;
- Inventory, FIFO, movement, adjustment, opname;
- POS online/offline, session, payment, refund, Tempo;
- Purchasing receipt/invoice/payment boundary;
- Expense, Setor Kas, Customer Balance, Ketul sesuai entitlement;
- Finance source mapping dan reconciliation minimum.

Fase ini tetap prioritas. Catatan masa depan tidak boleh memperluas acceptance criteria coding Fase 1 secara diam-diam.

### Fase Berikutnya — Dibuka Satu per Satu

- **Manufacture:** BOM/recipe, production order, raw material consumption, WIP, yield, scrap, finished goods, manufacturing variance.
- **HR:** employee master, attendance, payroll/benefit bila diputuskan; Auth User/Company Membership tidak otomatis menjadi payroll record.
- **Logistik:** shipment, delivery route, carrier, shipping charge, tracking, proof of delivery; menggunakan weight estimate tetapi tidak mengubah inventory tanpa stock event.
- Modul lain ditambahkan hanya setelah scope, role, Finance mapping, capacity, dan migration plan disetujui.

---

## 5. Feature Entitlement dan Authority

- Kemunculan/peniadaan modul atau feature company hanya dikendalikan Super Admin sesuai keputusan platform.
- Setelah modul aktif, Company Admin mengelola kewenangan tertinggi dalam company; role operasional mengikuti scope modul.
- Menonaktifkan modul tidak menghapus histori/open balance. Gunakan lifecycle seperti `ACTIVE`, `WIND_DOWN`, `DISABLED` bila masih ada obligation.
- UI tersembunyi bukan security boundary; RLS/API/RPC tetap menolak akses tidak sah.

---

## 6. Schema dan Migration Strategy

- Jangan membuat tabel kosong untuk semua modul masa depan sekarang.
- Gunakan additive migration, nullable/backfill/enforcement bertahap, compatibility window, verification query, serta rollback/forward-fix.
- Master reusable memiliki stable ID, company scope, status active/inactive, audit, dan historical snapshot.
- Jangan mengubah enum/status global secara sembarang bila module-specific status table/check lebih aman untuk evolusi.
- Index dibuat berdasarkan query/RLS nyata dan capacity measurement.
- Modul baru harus dapat diluncurkan per company tanpa memaksa seluruh tenant menggunakannya.

---

## 7. Foldering Target

Struktur implementasi berkembang per modul:

```text
docs/modules/{pos,inventory,finance,purchasing,manufacture,hr,logistics}/
backoffice/src/modules/{pos,inventory,finance,purchasing,...}/
supabase/modules/{pos,inventory,finance,purchasing,...}/
supabase/tests/{pos,inventory,finance,purchasing,rls,...}/
```

Folder Manufacture/HR/Logistik baru dibuat ketika development modul tersebut benar-benar dimulai; router dokumen cukup mencatat arah untuk saat ini.

---

## 8. Gate Membuka Modul Baru

1. POS production path dan data integrity yang menjadi dependency sudah stabil.
2. Business specification dan non-scope disetujui.
3. Ownership data serta events consumed/emitted ditentukan.
4. Role, entitlement, tenant/RLS, dan approval ditentukan.
5. Stock/Finance effect dan correction flow ditentukan.
6. Capacity/free-tier impact diestimasi dan kemudian diukur.
7. Migration, backfill, test, rollout, dan rollback disiapkan.
8. Router/README modul diperbarui agar agent tidak perlu membaca seluruh repo.

---

## 9. Instruksi untuk AI Agent

- Prioritaskan scope POS aktif; jangan mengimplementasikan future module hanya dari file ini.
- Jangan mengubah Product Bundle menjadi BOM Manufacture.
- Jangan mengubah Auth Profile/Company Membership menjadi Employee/Payroll master.
- Jangan menganggap weight estimate sebagai shipment atau stock movement.
- Saat modul masa depan dibuka, buat spesifikasi dan README modulnya sendiri, lalu gunakan contract lintas modul di file ini.
- Hindari overengineering yang menambah cost sebelum ada kebutuhan/measurement.

---

## 10. Decision Log

| Tanggal | Keputusan | Status |
|---|---|---|
| 2026-07-20 | Sistem diarahkan berkembang dari POS menjadi ERP modular | APPROVED sebagai arah |
| 2026-07-20 | Manufacture, HR, Logistik, dan modul lain ditambahkan bertahap setelah POS berjalan | APPROVED |
| 2026-07-20 | Arsitektur awal modular monolith dan ERP-ready, bukan microservices prematur | APPROVED |
| 2026-07-20 | Future module tidak menambah scope implementasi POS saat ini | APPROVED |
| 2026-07-20 | Module boundary, versioned event, tenant, audit, UOM, dan Finance source reference dijaga untuk ekspansi | APPROVED |
