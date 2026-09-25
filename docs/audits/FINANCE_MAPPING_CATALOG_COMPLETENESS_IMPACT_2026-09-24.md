# Finance Mapping Catalog Completeness — Impact Audit

Status: `DATABASE VERIFIED; CLIENT/SMOKE/UAT PENDING`  
Requirement: `FIN-002`, `FIN-003`, `PUR-004`  
Gate: additive G6 Finance master correction

## Outcome

Menyelaraskan katalog fungsi akun dengan runtime aktif tanpa mengubah rumus
jurnal atau mapping akun Company. Scope ini memperbaiki tiga gap:

1. katalog `PURCHASE_RETURN` tertinggal dari enam fungsi akun yang dipakai
   runtime posting;
2. API dan editor mengabaikan `optional_account_functions`;
3. user belum dapat melihat apakah mapping efektif suatu proses lengkap,
   hilang, ambigu, atau mengarah ke akun invalid.

## Existing execution path

- UI: `FinanceMasterView` membaca `/api/master/finance-masters`.
- API: route tersebut membaca `account_functions`, `system_events`, COA,
  kategori, rule, dan fallback dalam active Company.
- Mutation mapping: tetap melalui RPC versioned existing; patch ini tidak
  menambah mutation endpoint.
- Purchase Return runtime: `post_backoffice_purchase_return` selalu resolve
  `INVENTORY_ASSET` dan `SUPPLIER_AP_PROVISIONAL`; empat fungsi lain conditional.

## Impact map

### Direct impact

- `public.system_events` satu row `PURCHASE_RETURN`: metadata required dan
  conditional function diselaraskan dengan runtime.
- Finance Master API mengirim fungsi optional dan matriks completeness yang
  dihitung server-side pada timestamp response.
- Finance Master UI menampilkan tab kelengkapan serta memasukkan fungsi optional
  ke pilihan editor.

### Downstream impact

- Perubahan catalog dapat dipakai provisioning/audit berikutnya untuk menilai
  `SUPPLIER_AP_PROVISIONAL` sebagai wajib.
- Existing resolver, posting rule, COA, transaction rule, fallback, Event, dan
  Journal tidak diubah.
- Rule efektif yang sudah ada tetap menjadi sumber akun; patch tidak memilih
  akun atas nama Finance.

### Stock, payment, cashier session, dan Finance

- Stock/FIFO/Reservation: tidak berubah.
- Payment/Cashier Session: tidak berubah.
- Finance: satu metadata catalog row berubah; tidak ada Event/Journal baru,
  tidak ada journal repost, dan histori posted immutable.
- Audit: ledger migration ditambah; perubahan mapping user berikutnya tetap
  memakai audit/RPC existing.

### Compatibility

- Response API bersifat additive; field existing dipertahankan.
- UI lama tetap dapat mengabaikan `optional_account_functions` dan
  `mappingCompleteness`.
- Client baru dapat membaca database sebelum migration; fungsi optional tetap
  tersedia dari schema lama, sedangkan catalog `PURCHASE_RETURN` baru lengkap
  setelah migration.

### Concurrency, idempotency, retry

- Migration mengambil advisory lock dan menolak ledger duplicate.
- Tidak ada mutation transaksi baru sehingga tidak ada idempotency key bisnis
  baru.
- Mapping matrix hanya menilai konfigurasi eksplisit rule/fallback yang `ACTIVE`
  dan efektif pada timestamp server. Direct rule lebih dahulu; fallback hanya
  dinilai bila direct rule tidak ada. Compatibility lookup lama melalui
  `system_function_key` tidak diberi status hijau karena itu bukan pengganti
  review/mapping eksplisit Finance.

### Risiko regression

- Risiko utama adalah metadata catalog tidak sesuai runtime. Migration menjaga
  enam anchor literal pada fungsi posting sebelum update.
- Risiko kedua adalah indikator hijau palsu. Matrix menolak mapping ganda,
  account inactive/non-postable, dan account type tidak kompatibel.
- Conditional function yang belum dipetakan tetap ditandai perlu diperbaiki,
  karena cabang transaksi nyata dapat memerlukannya.

### Belum dapat dibuktikan lokal

- Exact runtime resolution Production KMS/SMS/LSM harus lulus preflight. Company
  lain tetap terlihat pada completeness UI tetapi tidak menjadi blocker rollout
  tiga entitas yang diminta user.
- Authenticated UI smoke per role/Company memerlukan database dan client target.

## Out of scope

- Supplier Refund Receipt/Offset runtime;
- Gross Sales Discount;
- perubahan Debit/Kredit atau amount expression;
- bulk apply workbook Finance;
- perubahan COA/mapping Production otomatis.

## Forward-fix / rollback note

Jangan menghapus migration ledger atau mengubah jurnal historis. Jika klasifikasi
catalog terbukti salah, buat forward migration yang mengoreksi tiga array pada
`PURCHASE_RETURN`. Client dapat di-rollback terpisah karena response API additive.
