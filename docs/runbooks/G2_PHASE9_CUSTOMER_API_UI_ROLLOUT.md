# Runbook G2 Fase 9 - Customer API/UI Smoke Test

**Scope:** Backoffice Customer dan Customer Category canonical  
**Dependency:** Customer foundation `20260722010000` complete  
**Status:** READY FOR MANUAL SMOKE TEST

## Perubahan

- menu Pelanggan sekarang memakai API canonical tenant aktif;
- tersedia tab Daftar Customer dan Kategori Customer;
- kode Customer dapat dikosongkan saat create agar dibuat otomatis;
- `Pelanggan Umum` dan kategori sistem `Umum` terlihat tetapi tidak dapat diedit;
- role Customer manager dapat mengubah identitas;
- hanya Owner/Admin/Finance/Accounting yang dapat mengubah batas dan termin
  kredit;
- saldo hanya ditampilkan sebagai read-only dan tidak pernah dikirim sebagai
  input RPC;
- mutation tetap melalui guarded RPC, optimistic version, tenant scope, dan
  audit database.

## Manual Smoke Test

1. Restart Backoffice lalu login dan pilih Company aktif.
2. Buka menu **Pelanggan**; pastikan `Pelanggan Umum` tampil tanpa error dan
   tombol edit tidak tersedia pada baris tersebut.
3. Buka tab **Kategori Customer**, buat satu kategori baru, lalu edit namanya.
4. Buat Customer baru dengan kode dikosongkan; pastikan kode otomatis
   `CUST-xxxxxx` tampil setelah refresh.
5. Edit identitas Customer dan simpan.
6. Dengan Owner/Admin/Finance/Accounting, ubah batas kredit atau termin dan
   pastikan tersimpan. Pastikan field saldo tetap tidak dapat diedit.
7. Nonaktifkan Customer biasa dan pastikan status berubah tanpa mengganggu
   menu Product, Supplier, Master Data, Finance, Tim, dan Company.

## Expected

- tidak ada notifikasi error atau request API gagal;
- Category dan Customer hanya berasal dari Company aktif;
- Customer sistem tetap immutable;
- saldo tidak berubah akibat create/edit Customer;
- menu existing tetap dapat dibuka.

## Belum Termasuk

- Customer Balance ledger/correction;
- TEMPO/AR dan Customer Statement;
- Pricelist, Tax, Customer quick-create POS, import/export Customer;
- perubahan checkout, Finance posting, Purchase, atau stock.
