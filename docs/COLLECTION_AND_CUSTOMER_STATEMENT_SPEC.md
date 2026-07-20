# Spesifikasi Collection TEMPO dan Customer Statement

**Status:** APPROVED untuk workflow, aging, assignment, follow-up, dan export boundary  
**Scope:** Penagihan manual piutang Customer TEMPO, in-app reminder, statement, dan retention operasional  
**Bukan scope:** WhatsApp/email automation, debt collector integration, legal/tax retention period, schema/API/UI

---

## 1. Tujuan

Dokumen ini mengatur cara Cashier, Store Manager, dan Finance memantau serta menindaklanjuti piutang tanpa mengubah outstanding secara diam-diam. Collection merupakan workflow operasional; nilai ledger hanya berubah melalui Payment, Debit/Credit Note, Write-off, atau Recovery yang sah.

Baca bersama `SALES_CUSTOMER_MASTERDATA_SPEC.md`, `POS_DEVELOPMENT_NOTES.md`, `FINANCE_INTEGRATION_NOTES.md`, `FINANCE_REPORTING_AND_CUTOFF_SPEC.md`, `DEBIT_CREDIT_NOTE_SPEC.md`, dan `EXTERNAL_EVIDENCE_LINK_POLICY.md`.

---

## 2. Reminder dan Performance Boundary

- Reminder tahap awal hanya in-app pada POS/Backoffice.
- Tidak ada WhatsApp, email, SMS, atau push eksternal otomatis.
- Badge dan daftar overdue dihitung dari open residual dan due date saat halaman dibuka.
- Sistem tidak membuat notification/reminder row baru setiap hari.
- Polling agresif, cron harian per Customer, dan Realtime per open invoice tidak diperlukan pada MVP.
- Follow-up event baru disimpan hanya ketika user melakukan aksi nyata.

Pendekatan ini menjaga database write, invocation, dan background processing tetap ringan untuk Supabase/Vercel free tier.

---

## 3. Aging Collection

Operational collection bucket:

```text
NOT_DUE
OVERDUE_1_7
OVERDUE_8_30
OVERDUE_31_60
OVERDUE_61_90
OVERDUE_GT_90
NO_DUE_DATE
```

- Aging dihitung dari residual open item terhadap `as_of` date, bukan original invoice amount.
- Dokumen partial payment tetap berada pada bucket sesuai residual dan due date.
- Dokumen tanpa due date tampil `NO_DUE_DATE` dan tidak otomatis dianggap overdue.
- Finance AR Aging dapat tetap menggabungkan `1-7` dan `8-30` menjadi bucket standar `1-30`; detail collection tidak mengubah angka laporan Finance.
- Aging adalah nilai turunan dan tidak perlu disimpan ulang setiap hari.

---

## 4. Assignment

Follow-up dapat ditugaskan kepada:

- Cashier;
- Store Manager;
- Finance;
- Company Admin/Super Admin sebagai authority lebih tinggi.

Assignment menyimpan:

```text
company_id
customer_id
source open item / collection case
responsible_role
responsible_user_id
assigned_by
assigned_at
follow_up_due_at
status
```

- Assignment wajib tenant-scoped.
- Perubahan assignee append-only dan menyimpan before/after, actor, waktu, serta alasan opsional.
- Satu Customer dapat memiliki beberapa open item, tetapi dapat dikelompokkan dalam satu collection case agar follow-up tidak berulang tanpa perlu.
- Source residual tetap ditelusuri per Pro Forma/Note.

---

## 5. Follow-up Log

Setiap aktivitas follow-up menyimpan:

```text
collection_case_id
customer_id
source document references
contacted_at
contact_method
result
note
promise_to_pay_date optional
promise_amount optional
next_action optional
next_follow_up_at optional
actor
evidence_url optional
```

Contact method minimum: `PHONE`, `CHAT_MANUAL`, `VISIT`, `IN_PERSON`, `OTHER`.

Result minimum: `NO_RESPONSE`, `CONTACTED`, `PROMISE_TO_PAY`, `DISPUTED`, `PAID_PENDING_VERIFICATION`, `RESOLVED`, `OTHER`.

Aturan:

- Log append-only dan tidak boleh mengganti histori lama.
- Evidence memakai URL eksternal sesuai `EXTERNAL_EVIDENCE_LINK_POLICY.md`; aplikasi tidak menyimpan binary.
- Follow-up/Promise tidak membuat journal, payment, credit note, atau perubahan outstanding.
- `PAID_PENDING_VERIFICATION` hanya status collection; Payment baru tercatat melalui menu Pembayaran TEMPO dan verifikasi yang berlaku.

---

## 6. Promise to Pay dan Due-date Correction

- Promise to Pay adalah komitmen operasional, bukan pembayaran.
- Promise tidak mengubah due date source, due status, atau residual.
- Promise dapat partial dan memiliki nominal/tanggal sendiri.
- Broken promise dihitung dari promise date yang lewat tanpa payment allocation yang cukup, tetapi tidak membuat write-off otomatis.
- Jika due date memang salah atau kebijakan berubah, Finance membuat audited due-date correction event berisi nilai lama/baru, alasan, actor, dan waktu.
- Correction tidak menghapus follow-up atau aging history sebelumnya.

---

## 7. Checkout dan Overdue Warning

- Customer overdue tetap dapat melakukan sale biasa atau TEMPO baru.
- POS menampilkan total outstanding, oldest due date, age bucket tertua, jumlah open item, dan warning limit/overdue.
- Cashier menentukan apakah TEMPO dilanjutkan dan acknowledgement disimpan dengan user, waktu, Customer, outstanding snapshot, dan reason opsional.
- Tidak ada approval Store Manager wajib untuk override pada scope awal.
- Customer inactive tidak dapat membuat TEMPO baru, tetapi collection/payment outstanding lama tetap dapat diselesaikan.

---

## 8. Escalation dan Write-off Boundary

- Escalation menggunakan aging, broken promise, dispute, dan assignment; tidak otomatis menuduh responsible user/Customer.
- Dokumen `>90` hari menjadi kandidat review Finance, bukan automatic write-off.
- Finance dapat mengajukan write-off partial/full dan Company Admin menyetujui dengan maker-checker sesuai Finance spec.
- Collection case dapat tetap menyimpan histori setelah write-off untuk kebutuhan Recovery.
- Payment setelah write-off memakai Recovery event dan tidak membuka jurnal lama.
- Legal/tax bad-debt compliance tetap keputusan terpisah sebelum digunakan untuk pelaporan resmi.

---

## 9. Customer Statement

Statement menghitung saldo berjalan dari source posted dan reconciliation allocation. Isi minimum:

- saldo awal dan akhir;
- Pro Forma/Sale TEMPO dan Invoice final;
- DP/cicilan/Payment allocation;
- Customer Debit/Credit Note;
- Sales Return/refund;
- write-off dan Recovery;
- due date, settlement status, due status, outstanding, serta running balance;
- source document, store, actor, dan date.

Filter minimum: Customer, company/store, date/as-of, settlement status, due status, aging bucket, dan source type.

Collection log tidak mengubah saldo Statement, tetapi dapat tersedia sebagai tab/detail operasional terpisah bagi role berwenang.

---

## 10. Export dan Retention

- Statement dibuat on-demand sebagai Excel/PDF.
- Scope awal tidak menyimpan file export permanen di Supabase Storage/database.
- Response/file sementara tidak boleh berisi secret dan harus mengikuti authority Customer/company.
- Export besar memakai pagination/streaming atau background job terkontrol hanya bila pengukuran membuktikan dibutuhkan.
- Source financial rows, reconciliation, write-off/recovery, dan follow-up log tidak dihapus otomatis selama masih memiliki outstanding atau menjadi bagian audit history.
- Archival/purge hanya boleh dirancang setelah volume nyata dan kebutuhan legal/tax retention dikonfirmasi; tidak boleh diasumsikan sekarang.

---

## 11. Role Boundary

| Aksi | Cashier | Store Manager | Finance | Company Admin | Super Admin |
|---|---:|---:|---:|---:|---:|
| Lihat warning saat POS | Ya | Ya | Ya | Ya | Ya |
| Lihat collection | Assigned/scope store | Scope store | Scope company | Scope company | Semua |
| Tambah follow-up | Ya sesuai scope | Ya | Ya | Ya | Ya |
| Assign/reassign | Tidak | Scope store | Scope company | Scope company | Semua |
| Due-date correction | Tidak | Tidak | Ya | Ya | Ya |
| Ajukan write-off | Tidak | Tidak | Ya | Ya sesuai workflow | Ya |
| Approve write-off maker lain | Tidak | Tidak | Tidak | Ya | Ya |
| Export Statement | Sesuai kebutuhan POS terbatas | Scope store | Scope company | Scope company | Semua |

Cashier tidak melihat COA, journal internal, atau alasan write-off sensitif. Enforcement wajib pada API/RPC/RLS, bukan hanya UI.

---

## 12. Reporting

Dashboard collection minimum:

- outstanding dan Customer count per aging bucket;
- assigned/unassigned case;
- due/broken promise;
- last follow-up dan next action;
- collection outcome dan payment conversion;
- overdue baru, tetap, terselesaikan, dan write-off candidate;
- filter company, store, Customer category, responsible user/role, dan date.

Dashboard memakai indexed aggregate/query on demand. Materialized summary/cache hanya ditambahkan setelah profiling menunjukkan kebutuhan.

---

## 13. Guardrail AI Agent

- Jangan membuat notification row harian untuk aging yang dapat dihitung.
- Jangan mengubah due date dari Promise to Pay.
- Jangan menganggap follow-up sebagai payment atau journal.
- Jangan auto-block TEMPO hanya karena overdue.
- Jangan auto-write-off berdasarkan umur.
- Jangan menyimpan file export/foto binary pada scope awal.
- Jangan menghapus histori collection/financial secara otomatis.
- Jangan membuat schema/API/UI sebelum fase implementasi dibuka.

---

## 14. Decision Log

| Tanggal | Keputusan | Status |
|---|---|---|
| 2026-07-20 | Reminder collection hanya in-app dan follow-up manual | APPROVED |
| 2026-07-20 | Operational aging memakai not-due, 1-7, 8-30, 31-60, 61-90, dan >90 | APPROVED |
| 2026-07-20 | Follow-up dapat ditugaskan ke Cashier, Store Manager, atau Finance | APPROVED |
| 2026-07-20 | Follow-up append-only menyimpan metode, hasil, Promise, next action, actor, dan optional evidence URL | APPROVED |
| 2026-07-20 | Promise tidak mengubah due date/outstanding; Finance due-date override memakai correction event | APPROVED |
| 2026-07-20 | Overdue tetap boleh sale/TEMPO baru dengan warning dan Cashier acknowledgement | APPROVED |
| 2026-07-20 | >90 hari hanya kandidat write-off review, bukan automatic write-off/delete | APPROVED |
| 2026-07-20 | Customer Statement Excel/PDF on-demand tanpa permanent export file atau daily reminder row | APPROVED |
