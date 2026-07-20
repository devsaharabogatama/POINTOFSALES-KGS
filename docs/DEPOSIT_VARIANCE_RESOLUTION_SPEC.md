# Spesifikasi Resolusi Selisih Setoran Kas

**Status:** APPROVED untuk workflow dan accounting boundary  
**Scope:** Selisih antara setoran aktual dan expected deposit setelah Cashier Session ditutup  
**Bukan scope:** Selisih kas saat tutup sesi, implementasi schema/API/UI, dan integrasi bank otomatis

---

## 1. Tujuan

Dokumen ini menjadi sumber keputusan untuk pencatatan, investigasi, dan penyelesaian `deposit_variance` pada Setor Kas multi-sesi. Selisih setoran tidak boleh langsung dianggap kerugian atau pendapatan dan tidak boleh membuka kembali Cashier Session atau dokumen Setor Kas yang sudah final.

Dokumen ini wajib dibaca bersama:

- `POS_DEVELOPMENT_NOTES.md` untuk pembuatan dan approval Setor Kas;
- `FINANCE_INTEGRATION_NOTES.md` untuk source-event journal;
- `FINANCE_CORE_ACCOUNTING_SPEC.md` untuk account function dan posting rule;
- `EXTERNAL_EVIDENCE_LINK_POLICY.md` untuk bukti eksternal.

---

## 2. Batas Selisih Tutup Sesi dan Selisih Setoran

Kedua selisih harus dipisahkan agar masalah yang sama tidak dibukukan dua kali.

| Jenis | Dibandingkan | Titik kejadian | Source document |
|---|---|---|---|
| Session cash variance | expected cash hasil event posted vs actual closing cash fisik | Tutup Cashier Session | Session Closing |
| Deposit variance | expected deposit dari actual closing yang sudah diterima vs nominal aktual yang disetor | Approval Setor Kas | Cash Deposit |

Formula:

```text
expected_deposit
= actual_closing_cash
- next_session_float_reserved
- posted_deposit_allocations

deposit_variance
= actual_deposit_amount - expected_deposit
```

Konsekuensi:

- shortage/overage yang sudah diakui pada Session Closing tidak boleh diakui ulang sebagai deposit variance;
- deposit variance hanya menangkap perubahan atau kehilangan custody setelah angka actual closing diterima;
- kesalahan formula/source diperbaiki dengan reversal dan replacement event, bukan jurnal variance kedua;
- setiap exception menyimpan referensi Setor Kas dan seluruh Session asal.

---

## 3. Klasifikasi

| Kondisi | Rumus | Klasifikasi |
|---|---|---|
| Sama | `actual = expected` | `MATCHED` |
| Kurang | `actual < expected` | `UNDER_DEPOSIT` |
| Lebih | `actual > expected` | `OVER_DEPOSIT` |

Nilai variance disimpan sebagai signed amount untuk audit, tetapi workflow menggunakan `variance_type` eksplisit agar tidak bergantung pada interpretasi tanda.

---

## 4. Posting Awal Saat Setor Kas Disetujui

Approval harus membersihkan seluruh expected deposit dari Kas Laci. Nominal aktual masuk ke tujuan nyata, sedangkan perbedaannya masuk akun kontrol.

### 4.1 Setoran sesuai expected

```text
Debit  Kas dalam Perjalanan / Kas Besar     expected
Credit Kas Laci                             expected
```

### 4.2 Setoran kurang

Contoh expected Rp100.000 dan aktual Rp80.000:

```text
Debit  Kas dalam Perjalanan / Kas Besar      80.000
Debit  Selisih Setoran Kurang dalam Investigasi
                                               20.000
Credit Kas Laci                              100.000
```

`Selisih Setoran Kurang dalam Investigasi` adalah akun Aset kontrol yang reconcilable. Nilai belum otomatis menjadi piutang Cashier sampai Finance menetapkan responsible party.

### 4.3 Setoran lebih

Contoh expected Rp100.000 dan aktual Rp120.000:

```text
Debit  Kas dalam Perjalanan / Kas Besar     120.000
Credit Kas Laci                              100.000
Credit Selisih Kas Lebih Belum Diselesaikan  20.000
```

Kelebihan tetap menjadi Kewajiban sementara sampai sumber atau pemilik dana dipastikan.

### 4.4 Tujuan Bank

Kas dalam Perjalanan hanya sebesar nominal aktual. Setelah mutasi Bank cocok:

```text
Debit  Bank
Credit Kas dalam Perjalanan
```

Kombinasi approval dan konfirmasi Bank boleh atomic jika terjadi bersamaan, tetapi reference clearing wajib disimpan.

---

## 5. Lifecycle Exception

Status minimum:

```text
OPEN
-> UNDER_INVESTIGATION
-> PARTIALLY_RESOLVED
-> RESOLVED

OPEN / UNDER_INVESTIGATION / PARTIALLY_RESOLVED
-> WRITTEN_OFF
```

Aturan:

- exception dibuat otomatis hanya jika Setor Kas `APPROVED` dan variance bukan nol;
- Finance menetapkan atau mengubah responsible party dengan reason dan audit trail;
- penyelesaian boleh satu atau beberapa allocation event;
- `remaining_amount = original_variance - resolved_allocations`;
- `PARTIALLY_RESOLVED` dipakai bila masih ada residual;
- `RESOLVED` hanya jika residual nol;
- `WRITTEN_OFF` adalah resolusi final untuk residual yang disetujui, bukan penghapusan histori;
- perubahan setelah posting bersifat append-only.

---

## 6. Penyelesaian Setoran Kurang

### 6.1 Penanggung jawab ditetapkan

Jika Finance menyatakan nilai menjadi tanggung jawab Cashier/user tertentu:

```text
Debit  Piutang Kekurangan Kasir
Credit Selisih Setoran Kurang dalam Investigasi
```

Responsible party dapat berupa user internal atau pihak lain yang didukung master party di masa depan. Pemilihan selalu tenant-scoped.

### 6.2 Uang pengganti atau uang ditemukan

```text
Debit  Kas / Bank / Kas dalam Perjalanan
Credit Selisih Setoran Kurang dalam Investigasi
```

Jika sebelumnya sudah direklasifikasi menjadi tanggung jawab Cashier, sisi kredit menggunakan `Piutang Kekurangan Kasir`.

### 6.3 Koreksi source

Jika investigasi membuktikan expected deposit atau nominal aktual salah, sistem membuat reversal atas event yang keliru lalu replacement event yang benar. Jurnal posted lama tidak diedit dan tidak dihapus.

### 6.4 Write-off resmi

```text
Debit  Beban Selisih Kas
Credit Selisih Setoran Kurang dalam Investigasi / Piutang Kekurangan Kasir
```

Write-off wajib maker-checker: Finance mengajukan dan Company Admin/Super Admin menyetujui. Finance tidak boleh membuat dan menyetujui write-off yang sama sendirian.

---

## 7. Penyelesaian Setoran Lebih

### 7.1 Koreksi source

Finance mereklasifikasi atau melakukan reversal/replacement terhadap source yang benar. Setiap koreksi menyimpan sumber asal dan alasan.

### 7.2 Refund atau pengembalian kepada pihak yang berhak

```text
Debit  Selisih Kas Lebih Belum Diselesaikan
Credit Kas / Bank
```

Pihak penerima, metode, waktu, referensi, dan evidence URL disimpan.

### 7.3 Diakui sebagai pendapatan perusahaan

Hanya setelah investigasi menyatakan tidak ada kewajiban pengembalian:

```text
Debit  Selisih Kas Lebih Belum Diselesaikan
Credit Pendapatan Lain-lain
```

Finance mengajukan resolusi dan Company Admin/Super Admin menyetujui karena keputusan memengaruhi laba/rugi.

---

## 8. Data Audit Minimum

Exception dan allocation minimal menyimpan:

- `company_id`, `store_id`, `deposit_id`, dan daftar `session_id`;
- expected, actual, signed variance, variance type, original amount, resolved amount, dan remaining amount;
- status, opened/aging date, resolved date;
- responsible party type/id dan histori perubahannya;
- resolution type, amount, account mapping version, reason category, dan note;
- actor pembuat, reviewer/approver, timestamp, serta idempotency key;
- source correction/reversal/replacement reference;
- optional evidence URL sesuai `EXTERNAL_EVIDENCE_LINK_POLICY.md`.

Evidence URL tidak membuktikan transaksi dengan sendirinya. Finance tetap melakukan verifikasi.

---

## 9. Authority

| Aksi | Cashier | Store Manager | Finance | Company Admin | Super Admin |
|---|---:|---:|---:|---:|---:|
| Melihat variance dari setoran sendiri | Ya | Sesuai store | Sesuai company | Sesuai company | Semua company |
| Menambah catatan/evidence | Ya, sebelum approval | Ya | Ya | Ya | Ya |
| Investigasi dan memilih responsible party | Tidak | Monitor | Ya | Ya | Ya |
| Membuat allocation resolution | Tidak | Tidak | Ya | Ya | Ya |
| Approve write-off/Pendapatan Lain | Tidak | Tidak | Tidak sebagai maker yang sama | Ya | Ya |
| Reopen session/deposit final | Tidak | Tidak | Tidak | Tidak | Tidak |

Authority harus ditegakkan di RLS/API/RPC, bukan hanya menyembunyikan menu.

---

## 10. Reporting dan Reconciliation

Finance memiliki daftar exception dengan filter company, store, Cashier, responsible party, type, status, age bucket, dan date range.

Laporan minimum menampilkan:

- original, resolved, dan remaining amount;
- aging `0-7`, `8-30`, `31-60`, `61-90`, dan `>90` hari;
- source Setor Kas dan Session;
- resolution history dan evidence link;
- saldo akun kontrol vs total exception terbuka.

Reconciliation wajib membuktikan:

```text
Saldo Selisih Setoran Kurang dalam Investigasi
= total remaining UNDER_DEPOSIT yang belum direklasifikasi

Saldo Piutang Kekurangan Kasir
= total remaining shortage yang sudah ditetapkan ke Cashier

Saldo Selisih Kas Lebih Belum Diselesaikan
= total remaining OVER_DEPOSIT dan cash overage lain yang memakai akun tersebut
```

---

## 11. Guardrail Implementasi

- Semua amount menggunakan precision currency company dan server-side validation.
- Approval Setor Kas, journal, exception, dan allocation awal harus atomic.
- Idempotency wajib pada submit, approval, bank confirmation, dan resolution.
- Allocation tidak boleh melebihi residual.
- Resolution tidak boleh lintas company atau memakai party/account dari tenant lain.
- Dokumen Setor Kas dan Session yang final tetap immutable.
- Tidak ada upload binary pada scope awal; bukti memakai external HTTPS/Drive link.
- Jangan membuat schema/API/UI sebelum fase implementasi dibuka secara eksplisit.

---

## 12. Decision Log

| Tanggal | Keputusan | Status |
|---|---|---|
| 2026-07-20 | Setoran aktual diposting sesuai nominal nyata; expected tetap dibersihkan penuh dari Kas Laci melalui akun kontrol variance | APPROVED |
| 2026-07-20 | Under-deposit masuk akun kontrol Aset dan baru menjadi Piutang Kekurangan Kasir setelah responsible party ditetapkan | APPROVED |
| 2026-07-20 | Over-deposit masuk Kewajiban Selisih Kas Lebih dan tidak otomatis menjadi pendapatan | APPROVED |
| 2026-07-20 | Finance memilih responsible party secara auditable | APPROVED |
| 2026-07-20 | Under-deposit dapat diselesaikan dengan uang pengganti, uang ditemukan, source correction, atau write-off resmi | APPROVED |
| 2026-07-20 | Over-deposit dapat diselesaikan dengan source correction, refund/pengembalian, atau Pendapatan Lain setelah keputusan Finance | APPROVED |
| 2026-07-20 | Resolution append-only dan tidak membuka kembali Session/Setor Kas final | APPROVED |
| 2026-07-20 | Exception mendukung OPEN, UNDER_INVESTIGATION, PARTIALLY_RESOLVED, RESOLVED, WRITTEN_OFF, aging, dan evidence URL | APPROVED |
