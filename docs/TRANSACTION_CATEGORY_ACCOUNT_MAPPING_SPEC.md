# Spesifikasi Transaction Category dan Account Mapping

**Status:** APPROVED untuk taxonomy, resolver, dan posting guard  
**Scope:** Kontrak system event, kategori transaksi, account function, mapping, versioning, dan missing-mapping queue  
**Bukan scope:** Implementasi schema/API/UI atau aktivasi journal production

---

## 1. Tujuan

Dokumen ini menjadi pusat routing jurnal. User boleh mengatur nama kategori dan akun company, tetapi sistem menjaga identitas business event, fungsi akun, arah accounting, serta histori mapping.

Baca bersama `FINANCE_CORE_ACCOUNTING_SPEC.md`, `FINANCE_INTEGRATION_NOTES.md`, spesifikasi source module, dan `FINANCE_MAPPING_REVIEW_2026-07-19.md`.

---

## 2. Empat Lapisan Konfigurasi

| Lapisan | Scope | Fungsi |
|---|---|---|
| System Event | Global/system-owned | Menetapkan `system_key`, event direction, required/optional account function, dan guard |
| Transaction Category | Per company | Nama/kode bisnis yang dipilih/dihasilkan source dan terikat ke satu system key/group |
| Transaction Rule Version | Per company/category | Memetakan account function ke Account ID dengan effective date |
| Category/Company Fallback | Per company | Mapping eksplisit jika function tertentu diizinkan fallback |

System key bukan COA dan tidak boleh berisi nomor akun hard-coded.

---

## 3. System Key

System key bersifat permanen dan dimiliki aplikasi. Registry awal mencakup keluarga berikut:

```text
SALE_POSTED
SALE_PAYMENT
SALES_RETURN
CUSTOMER_CREDIT_NOTE
CUSTOMER_DEBIT_NOTE
GOODS_RECEIPT
SUPPLIER_INVOICE
SUPPLIER_PAYMENT
PURCHASE_RETURN
SUPPLIER_CREDIT_NOTE
SUPPLIER_DEBIT_NOTE
STOCK_OPENING
STOCK_GAIN
STOCK_LOSS
STOCK_TRANSFER
EXPENSE_DISBURSEMENT
EXPENSE_SETTLEMENT
CASH_IN
CASH_DEPOSIT
CASH_VARIANCE
CUSTOMER_BALANCE_RECEIPT
CUSTOMER_BALANCE_USAGE
KETUL_CUSTOMER_INTAKE
KETUL_VENDOR_RESULT
KETUL_VENDOR_PAYMENT
MANUAL_JOURNAL
```

Varian seperti Cash/Tempo, Bank/Cash, tax on/off, dan physical/no-physical-return tidak perlu menciptakan system key sembarang jika dapat dinyatakan melalui source subtype, payment method, entitlement, dan required function condition.

Aturan:

- `system_key` tidak dapat dibuat/diubah oleh company user;
- key yang sudah pernah dipakai tidak dihapus atau dialihkan ke arti lain;
- event baru pada future Manufacture/HR/Logistik menambah registry baru tanpa mengubah arti event POS lama;
- satu posted source event memiliki system key dan idempotency identity yang jelas.

---

## 4. Transaction Category

Finance/Company Admin dapat membuat beberapa kategori untuk satu system key, misalnya `BENSIN`, `LISTRIK`, dan `ATK` untuk keluarga Expense.

Field konseptual minimum:

```text
id
company_id
code
name
system_key / allowed_system_group
description
is_active
created_by / updated_by
```

Guard:

- kode dan nama unik secara normalized dalam company;
- nama, kode, deskripsi, dan status boleh diubah;
- ikatan `system_key`, accounting direction, dan allowed account function terkunci setelah kategori dipakai;
- kategori inactive tetap tampil pada histori tetapi tidak dapat dipilih transaksi baru;
- kategori company A tidak dapat dipakai company B.

---

## 5. Account Function

System Event meminta fungsi akun, bukan kode COA tertentu. Katalog awal antara lain:

```text
CASH_DRAWER
MAIN_CASH
BANK
PAYMENT_CLEARING
CASH_IN_TRANSIT
CUSTOMER_RECEIVABLE
SUPPLIER_AP_PROVISIONAL
SUPPLIER_AP_FINAL
CUSTOMER_REFUND_LIABILITY
SUPPLIER_REFUND_RECEIVABLE
CUSTOMER_BALANCE_LIABILITY
SALES_REVENUE
SALES_RETURN_DISCOUNT
INVENTORY_ASSET
COGS
PURCHASE_PRICE_VARIANCE
EXPENSE
OUTSTANDING_EXPENSE
INPUT_TAX
OUTPUT_TAX
ROUNDING_GAIN
ROUNDING_LOSS
CASH_SHORTAGE_CONTROL
CASH_OVERAGE_LIABILITY
```

Setiap System Event mendefinisikan:

- function `REQUIRED`, `CONDITIONAL`, atau `OPTIONAL`;
- debit/credit direction atau rule per kondisi;
- account type/normal balance yang kompatibel;
- fallback yang diizinkan;
- dimension, tax, currency, party, dan reconciliation requirement.

Contoh `SALE_POSTED` membutuhkan penerimaan `CASH_DRAWER/CUSTOMER_RECEIVABLE`, `SALES_REVENUE`, `INVENTORY_ASSET`, dan `COGS`; `OUTPUT_TAX` conditional ketika Sales Tax aktif dan source memiliki tax.

---

## 6. Resolver COA

Resolver berjalan per account function:

```text
1. Transaction Rule pada Transaction Category aktif
2. Product Category atau Expense Category fallback, hanya jika event/function mengizinkan
3. Company fallback yang dikonfigurasi eksplisit dan compatible
4. Tidak ditemukan -> HOLD/ERROR, tanpa partial journal
```

Ketentuan:

- Product Category dapat menjadi fallback untuk revenue, inventory, HPP, dan tax yang diizinkan.
- Expense Category menjadi sumber/fallback akun Expense sesuai definisi event.
- Payment Method menyelesaikan function Kas/Bank/Clearing terkait.
- Company fallback bukan tebakan sistem; Finance harus mengisinya secara eksplisit.
- Product Master tidak memiliki COA override pada scope sekarang.
- Resolver menyimpan account ID dan rule-version snapshot pada source/journal.

---

## 7. Transaction Rule Version

Mapping bersifat versioned dan effective-dated:

```text
company_id
transaction_category_id
system_key
account_function
account_id
effective_from
effective_to
version
status
approved_by
```

- Perubahan mapping membuat versi baru, bukan menimpa histori.
- Transaksi memakai versi efektif pada accounting/event date sesuai period policy.
- Perubahan hanya memengaruhi event baru atau event yang belum posted.
- Draft dapat di-resolve ulang saat posting; posted source tidak berubah.
- Overlap effective period untuk kombinasi yang sama ditolak.

---

## 8. Validasi Sebelum Posting

Server wajib memvalidasi:

- authenticated actor dan authority;
- source/category/account berada pada company yang sama;
- system key sesuai source type;
- kategori dan rule aktif/effective;
- seluruh required function berhasil di-resolve;
- account aktif, postable leaf, dan type/function compatible;
- currency dan exchange context compatible;
- required party/reconciliation reference tersedia;
- dimension company/store/warehouse/session valid;
- entitlement dan tax condition valid;
- total debit sama dengan total credit;
- period open;
- idempotency key belum pernah diposting.

Validasi dan posting terjadi server-side dalam satu transaksi database.

---

## 9. HOLD/ERROR Queue

Jika mapping tidak lengkap atau invalid:

- tidak ada partial journal;
- source business event tidak dihapus;
- financial posting masuk `PENDING_MAPPING`/`POSTING_ERROR` dengan reason code;
- Finance melihat missing function, attempted resolver level, source, company, rule version, dan retry count;
- setelah mapping diperbaiki, event dapat di-retry dengan idempotency key source yang sama;
- retry sukses tidak membuat journal duplicate;
- source operasional hanya boleh dianggap financially posted setelah acknowledgement sukses.

Reason minimum:

```text
MISSING_REQUIRED_FUNCTION
INACTIVE_ACCOUNT
INCOMPATIBLE_ACCOUNT_TYPE
INVALID_COMPANY_SCOPE
INVALID_DIMENSION
LOCKED_PERIOD
UNBALANCED_JOURNAL
RULE_VERSION_CONFLICT
```

---

## 10. Authority

| Aksi | Finance | Company Admin | Super Admin | Store Manager/Cashier |
|---|---:|---:|---:|---:|
| Kelola kategori company | Ya | Ya | Ya | Tidak |
| Kelola mapping/rule company | Ya | Ya | Ya | Tidak |
| Menyediakan template default | Tidak global | Tidak global | Ya | Tidak |
| Menangani pending mapping | Ya | Ya | Ya | Lihat status sesuai kebutuhan |
| Mengubah system key registry | Tidak | Tidak | Melalui release aplikasi resmi | Tidak |

Super Admin tidak dibatasi scope company, tetapi tetap melalui versioning, validation, dan audit resmi.

---

## 11. Reporting dan Audit

Minimum tersedia:

- daftar kategori dan rule aktif/inactive/effective future;
- missing mapping matrix per company, module, system key, category, dan function;
- rule change history before/after, actor, approval, dan waktu;
- source-to-journal drill-down dengan system key/category/rule snapshot;
- pending/error aging, retry history, dan resolution actor;
- export konfigurasi untuk review sebelum Finance enforcement diaktifkan.

---

## 12. Activation Gate

Sebelum enforcement production:

1. audit schema/data existing;
2. seed registry system key dan account function;
3. buat kategori/rule nullable tanpa langsung mengaktifkan posting;
4. backfill kategori source existing;
5. isi company/category/payment fallback;
6. jalankan missing-mapping report sampai bersih;
7. uji setiap event, reversal, idempotency, RLS, dan locked period;
8. siapkan rollout/rollback;
9. aktifkan posting per company secara terkontrol.

---

## 13. Guardrail AI Agent

- Jangan hard-code nomor/nama COA pada business logic.
- Jangan mengizinkan company membuat arti system key sendiri.
- Jangan mengubah system key/accounting direction kategori yang sudah dipakai.
- Jangan menebak account ketika resolver gagal.
- Jangan membuat partial journal.
- Jangan memperbarui mapping historis; buat versi baru.
- Jangan menjadikan UI hiding sebagai authorization.
- Jangan membuat schema/API/UI sebelum fase implementasi dibuka.

---

## 14. Decision Log

| Tanggal | Keputusan | Status |
|---|---|---|
| 2026-07-20 | Setiap business event memakai system key permanen | APPROVED |
| 2026-07-20 | Nama/kode kategori fleksibel, tetapi system key dan direction terkunci setelah dipakai | APPROVED |
| 2026-07-20 | Banyak kategori company dapat memakai satu system key | APPROVED |
| 2026-07-20 | System key mendefinisikan required account function, bukan nomor COA hard-coded | APPROVED |
| 2026-07-20 | Resolver: transaction mapping, category fallback, explicit company fallback, lalu HOLD/ERROR | APPROVED |
| 2026-07-20 | Mapping versioned/effective-dated dan tidak mengubah jurnal historis | APPROVED |
| 2026-07-20 | Server memvalidasi scope, account, currency, balance, dimension, entitlement, dan period | APPROVED |
| 2026-07-20 | Finance/Company Admin mengatur company mapping; Super Admin mengatur semua/template; Store Manager/Cashier tidak | APPROVED |
