# Backoffice Sales Authenticated Read Smoke — Step 6/6.1

Status: `LOCAL READY; AUTHENTICATED DEVELOPMENT EXECUTION PENDING`.

Target hanya isolated Development `fkywtxucmyjvpwdiqpix`. Script menolak ref
production dan existing staging, memakai publishable key, lalu meminta email dan
password secara interaktif. Password dan access token tidak ditulis ke file atau
output.

## Impact map

- Direct: login Supabase Development dan GET terhadap context, SO, DO/SJ,
  Invoice, Delivered Not Invoiced, serta katalog Data Exchange.
- Downstream: membuktikan token user, active Company, role/capability dan route
  Next benar-benar mencapai RPC Development.
- Mutation: tidak ada mutation dokumen, Stock/FIFO, Invoice, Payment, Finance,
  session kasir, feature setting, atau database.
- Belum dibuktikan oleh substep ini: mutation E2E, second-Company isolation,
  concurrency, POS Retail regression, export download, dan visual UAT.

## Menjalankan

1. Jalankan Backoffice melalui environment guard Development.
2. Dari terminal kedua di folder `backoffice`, jalankan:

   ```powershell
   npm.cmd run smoke:backoffice-sales
   ```

3. Jika server memakai port lain:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\smoke-backoffice-sales-development.ps1 -BaseUrl http://localhost:3001
   ```

4. Masukkan user Development saat diminta. Hasil sah harus berakhir dengan:

   ```text
   AUTHENTICATED_SMOKE=PASS
   MUTATIONS=NONE
   PRODUCTION_AND_EXISTING_STAGING_ACCESS=DENIED
   ```

Jangan menaruh password/token pada command line, screenshot, chat, Git, atau
file env. Kegagalan satu check adalah blocker; kirim hanya tabel check/error
tanpa credential.

## Compatibility dan next boundary

Script tidak mengubah runtime aplikasi dan dapat dihapus tanpa rollback data.
Setelah PASS, Step 6/6.2 menutup authenticated mutation matrix dan
multi-Company/role denial memakai fixture terkontrol. Production compatibility
dan POS regression tetap gate terpisah setelah Development UAT.
