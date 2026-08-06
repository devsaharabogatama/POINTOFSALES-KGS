# G4 Phase 21 — Offline Checkout Queue Preflight

## Outcome

Preflight ini menentukan apakah server, data operasional, dan scope UAT sudah
aman untuk mulai menghubungkan Keranjang PWA ke retained Offline queue.
Preflight tidak membuka checkout Offline dan tidak membuat transaksi.

## File

`supabase/diagnostics/g4_phase21_offline_checkout_queue_preflight.sql`

Jalankan seluruh file pada Supabase SQL Editor dan kirim semua baris hasil,
termasuk `SETUP` serta `INFO`.

## Safety

- satu statement `WITH ... SELECT`;
- tidak ada DDL, DML, TEMP table, function side effect, atau privilege change;
- hanya mengembalikan aggregate count;
- tidak mengembalikan nama Product, Customer, user, atau payload transaksi.

Verifikasi lokal 30 Juli 2026:

- executable statement: `1`;
- executable mutation line: `0`;
- pasangan kurung: `170/170`;
- SHA-256:
  `11300EA1F048A3372BD73A19EC0720C599DACEEC5074C8A40CD37B29D1BADBB0`;
- `git diff --check`: PASS.

## Interpretasi

- `BLOCKER`: jangan membuka Keranjang Offline; perbaiki invariant terlebih
  dahulu.
- `SETUP`: server aman tetapi scope disposable UAT belum lengkap. Expected bila
  entitlement masih disabled, Terminal belum eligible, Session belum dibuka,
  atau allowance belum diterbitkan.
- `PASS`: invariant siap.
- `INFO`: inventory saja.

`offline_checkout_uat_scope = SETUP` bukan bug selama Offline sengaja belum
diaktifkan. Aktivasi tidak dilakukan oleh file ini.

## Pemeriksaan utama

- migration Phase-11/12/14 applied;
- enam guarded RPC tersedia dan executable oleh `authenticated`;
- browser tidak mempunyai direct write ke submission, allowance, Sale,
  Payment, Stock, FIFO, atau Movement;
- Company/Terminal/Session disposable UAT lengkap;
- allowance aktif tenant-safe, non-Bundle, Base-UOM valid, dan tidak melebihi
  stock;
- Product allowance mempunyai Sales UOM aktif;
- Session mempunyai Payment Method Offline eligible;
- tidak ada submission lama berstatus nonterminal;
- client transaction ID dan posting key tidak duplikat;
- submission `POSTED` mempunyai Sale Offline final;
- Stock–Movement–FIFO tetap rekonsiliasi;
- guard penutupan Session masih aktif.

## Boundary setelah hasil

Jangan langsung mengaktifkan tombol pembayaran Offline hanya karena preflight
PASS. Implementasi berikutnya masih wajib:

1. validasi cache exact-scope dan freshness sebelum queue;
2. validasi allowance lokal per Product dan Base UOM;
3. payload snapshot harga/discount/tax/payment yang cocok dengan RPC Phase-12;
4. Slip Offline dengan watermark, bukan invoice final;
5. list/status/retry/conflict queue;
6. network-loss/reconnect UAT;
7. explicit confirmation bahwa barang/pembayaran baru boleh diserahkan setelah
   aturan Offline terpenuhi.

## Rollback

Tidak ada rollback database karena preflight hanya membaca. Hapus file lokal
diagnostic/runbook bila phase dibatalkan; tidak ada state Supabase berubah.
