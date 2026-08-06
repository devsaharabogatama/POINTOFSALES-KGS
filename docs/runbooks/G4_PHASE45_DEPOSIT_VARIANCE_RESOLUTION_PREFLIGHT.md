# G4 Phase 45 — Deposit Variance Resolution Preflight

## Tujuan

Phase 44 Setor Kas operational UI sudah lolos smoke approval. Langkah berikut
tetap berada pada POS-008: audit SELECT-only sebelum workflow investigasi dan
penyelesaian setoran kurang/lebih dibuka.

Preflight ini memeriksa:

- coverage exception untuk Deposit approved yang memiliki variance;
- kecocokan source Deposit, Store, type, control account, dan original amount;
- rekonsiliasi original/resolved/remaining terhadap allocation append-only;
- lifecycle dan responsible party tenant-scoped;
- account/category readiness untuk recovery, receivable, refund, expense,
  dan other income;
- gap maker-checker, investigation metadata, resolution reference, RPC,
  serta Financial Event;
- browser direct-write boundary.

Preflight tidak melakukan resolution, write-off, refund, source correction,
bank matching, atau jurnal.

## Menjalankan

Jalankan seluruh file berikut di Supabase SQL Editor:

```text
supabase/diagnostics/g4_phase45_deposit_variance_resolution_preflight.sql
```

Kirim seluruh output `check_name,status,details`.

## Interpretasi

- `BLOCKER` wajib nol sebelum foundation dirancang.
- `BACKFILL` berarti mapping account function perlu disiapkan untuk Company
  yang sudah memiliki exception terbuka.
- `SETUP` di schema/RPC/status/event expected pada boundary Phase 43 dan menjadi
  input migration berikutnya.
- `PASS` membuktikan existing Deposit/exception tetap konsisten.
- `INFO` hanya inventory dan privilege snapshot.

## Boundary

Jangan mengedit Deposit approved, Session final, exception, allocation, atau
Financial Event secara manual. Resolution harus append-only dan tidak boleh
membuka kembali Setor Kas/Session. Write-off dan pengakuan other income wajib
maker-checker; Finance maker tidak boleh menyetujui tindakannya sendiri.
