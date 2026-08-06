# G4 Phase 15 — Offline PWA Catalog Cache Foundation

## Outcome

Menambahkan cache snapshot katalog authoritative ke IndexedDB PWA tanpa
membuka checkout Offline. Cache hanya dapat diisi melalui RPC Phase 14 dan
selalu terikat pada exact Company, Store, Terminal, Gudang, Cashier Session,
serta Cashier yang sedang aktif.

## Implementasi

- Dexie schema v4 menambah `offline_catalog_snapshots`;
- primary key adalah `cashierSessionId`, sehingga satu Session hanya mempunyai
  satu snapshot aktif pada perangkat;
- payload menyimpan Product-UOM, base price, Pricelist/rule, Sales Tax metadata,
  Payment Method, stock Gudang, dan active allowance;
- setiap refresh memvalidasi exact scope response terhadap scope PWA;
- payload disimpan bersama canonical JSONB SHA-256 dan diverifikasi ulang saat
  dibaca;
- mismatch hash/version membuat cache invalid dan tidak dapat dipakai;
- invalidation menyimpan waktu dan alasan, bukan menghapus record;
- freshness tidak memakai TTL bisnis hard-coded. Caller wajib memberikan
  `maxAgeMs` ketika cache akan digunakan. Ini mempertahankan keputusan bahwa
  allowance tidak expired otomatis selama Terminal masih offline;
- sisa allowance lokal dihitung dari server remaining quantity dikurangi semua
  queue pada `catalogVersion` yang sama. Record `INVALIDATED` tidak dihitung;
- queue `POSTED` tetap dihitung sampai snapshot server yang lebih baru diambil,
  agar cache lama tidak dapat memakai allowance dua kali.

## File

- `pwa/src/lib/db.ts`;
- `pwa/src/lib/offlineCatalog.ts`;
- `pwa/src/lib/offline.ts` sebagai retained queue dependency.

## Verifikasi Lokal

Dari folder `pwa`:

```powershell
npm.cmd run lint
npm.cmd run build
```

Hasil 30 Juli 2026:

- `oxlint`: PASS;
- TypeScript + Vite production build: PASS;
- PWA service worker/precache generation: PASS.

## Boundary

- `offline_pos_enabled` tetap disabled;
- Terminal policy tidak dibuat otomatis;
- cache belum direfresh dari flow UI karena tidak ada Terminal Offline-enabled
  pada data live;
- Keranjang belum dapat membuat `OfflineSalePayload`;
- queue belum menjadi execution path tombol bayar;
- Slip Offline, retry/conflict UI, dan network-loss UAT belum dibuka;
- direct table write dan service-role tidak ditambahkan;
- Customer Balance, Ketul, TEMPO fisik, Return, Expense, Goods Receipt,
  Adjustment, serta Stock Opname tetap tidak tersedia Offline.

## Manual Smoke yang Belum Berlaku

Authenticated cache smoke baru boleh dilakukan setelah Super Admin secara
eksplisit:

1. memilih Terminal UAT untuk Offline;
2. mengaktifkan entitlement pada Company UAT;
3. membuka Cashier Session pada Terminal tersebut;
4. menerbitkan allowance untuk Product yang akan diuji.

Aktivasi tersebut bukan bagian Phase 15 local foundation dan tidak dilakukan
otomatis oleh kode.

## Next Safe Step

Bangun read-only status/cache UX pada PWA: indikator Online/Offline, timestamp
snapshot terakhir, freshness, Terminal/Session scope, dan sisa allowance lokal.
UX belum boleh mengaktifkan checkout Offline. Setelah authenticated cache smoke
dan allowance reconciliation lulus, baru buka gate payload Keranjang,
Slip Offline, retained queue list, retry/status, dan conflict handling.
