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

### Kandidat roadmap HR — referensi fungsi Mekari Talenta

Catatan ini memakai kelompok fungsi pada [halaman fitur resmi Mekari
Talenta](https://www.talenta.co/fitur/) sebagai referensi produk, bukan target
untuk menyalin seluruh fiturnya. Implementasi harus dibuka bertahap:

1. **HR Foundation:** Employee master yang terpisah dari akun login, struktur
   organisasi, jabatan, lokasi kerja, atasan, status/kontrak kerja, dokumen,
   histori mutasi, onboarding dan offboarding.
2. **Attendance:** jadwal dan shift, clock-in/out, keterlambatan, lembur, cuti,
   izin, timesheet dan approval. Geolocation, liveness, serta live tracking
   hanya dibuka bila kebutuhan, persetujuan privasi, dan biaya penyimpanan sudah
   jelas.
3. **Payroll, Compensation, and Benefit:** komponen gaji, tunjangan, potongan,
   reimbursement, benefit, periode payroll, perhitungan, approval, payslip dan
   disbursement. Payroll harus menghasilkan Finance event terkontrol; bukan
   menulis Journal atau Expense langsung dari browser.
4. **Talent Acquisition:** manpower request, lowongan, kandidat, tahapan ATS,
   interview, assessment, offering, lalu konversi kandidat menjadi Employee.
5. **Talent Development:** goal/KPI, performance review, kompetensi, training,
   succession/career development, feedback, form dan HR helpdesk.
6. **Employee Self Service dan Analytics:** profil terbatas, pengajuan mandiri,
   inbox approval, kalender, dashboard headcount/turnover/attendance/payroll.
   Analytics membaca read model dan tidak menjadi sumber mutasi payroll.

Boundary penting HR:

- satu orang dapat menjadi Employee tanpa akun aplikasi; akun hanya ditautkan
  bila membutuhkan ESS atau approval;
- data gaji, rekening, identitas, dokumen dan kehadiran adalah data sensitif;
  aksesnya perlu permission terpisah, audit baca/perubahan, retention, dan
  masking export;
- Company Membership menentukan akses aplikasi, bukan hubungan kerja;
- payroll period, approval, reversal dan Finance mapping harus selesai sebelum
  fitur Payroll dapat dinyatakan aktif.

### Kandidat roadmap Manufacture — referensi alur Odoo

Struktur mengacu pada konsep resmi Odoo mengenai [Bill of Materials dan
operation](https://www.odoo.com/documentation/master/applications/inventory_and_mrp/manufacturing/basic_setup/bill_configuration.html),
[Manufacturing Order/Work
Order](https://www.odoo.com/documentation/master/applications/inventory_and_mrp/manufacturing/basic_setup/manufacturing_work_orders.html),
dan [Work
Center](https://www.odoo.com/documentation/18.0/applications/inventory_and_mrp/manufacturing/advanced_configuration/using_work_centers.html).
Roadmap kandidatnya:

1. **Manufacture Foundation:** versioned BOM/recipe, komponen dan Base UOM,
   output/by-product, effective date, routing/operation, Work Center, kapasitas,
   kalender dan standard cost.
2. **Production Planning:** Manufacturing Order, kebutuhan bahan, availability,
   reservation bahan, jadwal, batch produksi dan dependency Work Order.
3. **Shop-floor Execution:** issue/consume bahan aktual, start/pause/complete Work
   Order, partial production, lot/batch output, yield, scrap, rework dan unbuild.
4. **Quality dan Maintenance:** quality control point/check, hasil pass/fail,
   quarantine, maintenance request, downtime dan equipment history. Odoo juga
   memisahkan [quality
   check](https://www.odoo.com/documentation/18.0/applications/inventory_and_mrp/quality/quality_management/quality_checks.html)
   dari transaksi produksi utamanya.
5. **Advanced Planning:** MPS, capacity/load planning, lead time, make-to-stock,
   make-to-order, multi-level BOM dan subcontracting. Subcontracting baru
   dibuka setelah arus komponen, receipt dan valuation disetujui.
6. **Manufacturing Finance:** Raw Material, WIP, Finished Goods, scrap,
   subcontract cost, overhead dan production variance mempunyai immutable
   source event serta account mapping tersendiri.

Boundary penting Manufacture:

- Product Bundle POS tetap bukan BOM;
- confirmation MO hanya mereservasi bahan; stock berkurang saat consumption
  yang sah dan finished goods bertambah saat production receipt yang sah;
- setiap lot/batch dan cost allocation harus dapat direkonsiliasi dengan FIFO,
  Stock Movement, WIP dan Journal;
- perubahan BOM tidak mengubah histori MO yang sudah dikonfirmasi atau selesai.

#### Produksi dengan hasil aktual yang tidak tetap

Kondisi bisnis user memungkinkan bahan dan BOM/recipe yang sama menghasilkan
jenis, grade, serta kuantitas barang jadi yang berbeda. Karena itu BOM tidak
boleh menjadi kontrak output final yang kaku. Kontrak kandidatnya:

- BOM/version menyimpan **baseline perencanaan**: input standar, operasi,
  perkiraan yield dan daftar kandidat output; bukan jumlah final yang wajib
  selalu tercapai;
- Manufacturing Order menyimpan rencana, sedangkan pelaksanaan mencatat
  konsumsi bahan aktual, waktu/overhead aktual, scrap, loss dan output aktual;
- satu MO dapat menghasilkan primary product, beberapa co-product/by-product,
  grade berbeda, dan scrap. Product serta kuantitas output dapat dipastikan
  setelah proses/quality grading, selama masih berada dalam output policy yang
  disetujui;
- output di luar policy atau perubahan material membutuhkan approval dan alasan,
  bukan sekadar edit tanpa audit;
- setiap output aktual memperoleh lot/batch sendiri dan bagian actual production
  cost sendiri. Batch itulah yang menjadi sumber FIFO/COGS ketika barang dijual;
- yield variance membandingkan baseline BOM dengan konsumsi dan hasil aktual,
  tetapi tidak mengubah histori atau memaksa koreksi kuantitas agar sama dengan
  rencana.

Joint/co-product cost allocation tidak boleh di-hardcode ke satu metode. Policy
per Company/BOM dapat memilih salah satu metode yang telah disetujui:

1. berdasarkan kuantitas atau berat ekuivalen;
2. berdasarkan standard cost;
3. berdasarkan relative sales value/NRV;
4. alokasi manual terkontrol dengan total 100%, alasan dan approval.

Metode, parameter, nilai pembagi dan hasil alokasi disimpan sebagai snapshot
immutable pada penyelesaian MO. Perubahan policy hanya berlaku untuk produksi
berikutnya. Jika total biaya aktual MO adalah `WIP total`, penutupan wajib
memenuhi:

```text
WIP total = jumlah cost seluruh output + scrap/variance yang diakui
```

Alur Finance kandidat untuk produksi variabel:

```text
Konsumsi bahan aktual       Dr WIP / Cr Raw Material Inventory
Tenaga kerja dan overhead   Dr WIP / Cr Payroll/Overhead Clearing
Penyelesaian multi-output   Dr setiap Finished Goods Batch / Cr WIP
Scrap atau selisih abnormal Dr Manufacturing Variance / Cr WIP
Dispatch barang jadi        Dr COGS / Cr Finished Goods Inventory
```

Dengan desain ini, COGS penjualan membaca biaya batch barang jadi aktual, bukan
harga rata-rata BOM dan bukan harga bahan mentah secara langsung. Revaluasi
biaya bahan/Supplier Invoice yang datang kemudian harus dialokasikan secara
traceable ke Raw Material tersisa, WIP, Finished Goods tersisa, dan COGS yang
sudah keluar sesuai lineage batch; tidak boleh membuat selisih tersembunyi.

#### Kontrak integrasi Finance lintas HR, Manufacture, dan Logistik

Tidak setiap aktivitas membuat Journal. Dokumen operasional lebih dulu menjadi
immutable source; hanya final value-bearing action yang membuat Financial Event
dan diproses oleh canonical Finance dispatcher.

- **HR:** Payroll approved membuat beban, benefit/pajak dan payroll payable;
  payroll paid menyelesaikan payable ke Bank. Tenaga kerja produksi hanya masuk
  WIP melalui allocation yang disetujui ke MO/Work Center.
- **Manufacture:** consumption, production completion, scrap/variance,
  subcontracting dan revaluation mempunyai event sendiri. Confirmation atau
  planning MO tidak membuat efek Finance final.
- **Logistik:** rute, GPS, ETA dan tanda tangan tidak membuat Journal. Shipping
  charge, carrier/fuel/toll expense dan COD handover dapat membuat event setelah
  sumbernya final dan disetujui.

Setiap event wajib tenant-scoped, versioned, idempotent, mempunyai account
mapping, business/effective date, open-period guard, immutable amount/account
snapshot, reversal path dan source-to-journal reconciliation. Modul tidak boleh
menulis langsung ke Journal atau memakai satu event generik untuk seluruh efek.

### Kandidat roadmap Logistik

Logistik memakai Surat Jalan/Delivery existing sebagai sumber, tetapi tidak
mengambil alih ownership Stock Movement atau Invoice. Tahapan kandidat:

1. **Proof of Delivery (prioritas awal):** Shipment/Trip, penugasan Driver dan
   kendaraan/carrier, daftar Surat Jalan, status berangkat/tiba/gagal,
   penerima, tanda tangan digital, foto bukti, catatan, waktu dan lokasi.
   Bukti harus immutable setelah diterima; koreksi memakai versi/audit baru.
2. **Route Planning:** alamat Customer tervalidasi/geocoded, titik awal/akhir,
   urutan stop, wilayah/rute tetap, kapasitas berat/volume kendaraan, jadwal,
   estimasi jarak/waktu dan tautan navigasi. Perubahan rute tidak boleh mengubah
   isi Surat Jalan.
3. **Delivery Execution:** aplikasi Driver, scan Surat Jalan/barcode, actual
   departure/arrival, failed delivery reason, partial delivery, redelivery,
   return-to-warehouse dan status sinkron yang aman ketika koneksi putus.
4. **Advanced Logistics:** route optimization, live location/ETA, geofence,
   carrier rate, manifest, konsolidasi muatan, COD handover/reconciliation,
   dashboard SLA dan biaya per rute/kendaraan.

Odoo mendokumentasikan route sebagai rangkaian aturan pergerakan serta pilihan
one-step, pick-and-ship, atau pick-pack-ship; MADS harus memilih alur sesuai
operasional nyata dan tidak membuka semuanya sekaligus. Referensi:
[routes/push-pull](https://www.odoo.com/documentation/17.0/applications/inventory_and_mrp/inventory/shipping_receiving/daily_operations/use_routes.html)
dan [barcode receipt/delivery](https://www.odoo.com/documentation/master/applications/inventory_and_mrp/barcode/operations/receipts_deliveries.html).

Boundary penting Logistik:

- Dispatch Inventory tetap satu-satunya pemilik pengurangan stok;
- tanda tangan digital membuktikan serah terima, bukan otorisasi untuk membuat
  Invoice, Journal, atau Stock Movement baru;
- data peta/GPS memerlukan consent, retention dan akses terbatas;
- provider peta, geocoding, optimasi, storage foto dan bandwidth wajib dihitung
  sebelum fitur aktif karena dapat menambah biaya eksternal.

### Urutan implementasi yang direkomendasikan

1. Stabilkan POS, Inventory, Purchasing dan Finance yang sedang digunakan.
2. Buka **Logistik Proof of Delivery** lebih dulu karena paling dekat dengan
   Surat Jalan dan Dispatch existing, tetapi tetap sebagai feature entitlement
   per Company.
3. Buka **Manufacture Foundation** bila bisnis benar-benar melakukan produksi;
   mulai dari BOM dan MO sederhana sebelum Work Center/Quality/MPS.
4. Buka **HR Foundation dan Attendance** sebagai domain terpisah. Payroll baru
   menyusul setelah kebijakan, compliance, security dan Finance mapping final.
5. Route optimization, live tracking, advanced Manufacture dan Talent
   Development tetap fase lanjutan berbasis kebutuhan serta hasil pengukuran.

Ketiga modul tidak disarankan dikerjakan dalam satu cutover. Masing-masing perlu
preflight, foundation, behavioral test, UI, postflight dan authenticated UAT
sendiri agar kegagalannya tidak menghambat operasional POS.

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
| 2026-09-03 | Kandidat roadmap HR mengacu pada kelompok fungsi Mekari Talenta; Manufacture mengacu pada konsep Odoo | NOTED, tetap DEFERRED |
| 2026-09-03 | Logistik diprioritaskan dari Proof of Delivery dan route planning; advanced optimization/live tracking menyusul | NOTED, tetap DEFERRED |
| 2026-09-03 | Tidak ada schema, UI, migration, entitlement, atau runtime modul baru yang dibuka dari catatan ini | CONFIRMED |
| 2026-09-03 | BOM Manufacture menjadi baseline; satu MO boleh menghasilkan multi-output/grade aktual dengan policy cost allocation tersnapshot | NOTED, tetap DEFERRED |
| 2026-09-03 | Finance lintas HR/Manufacture/Logistik memakai immutable source dan canonical Financial Event, bukan direct Journal write | NOTED, tetap DEFERRED |
