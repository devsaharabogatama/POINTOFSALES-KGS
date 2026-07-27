# Runbook G2 Fase 2 - Canonical Master API

**Scope:** Backend Backoffice untuk Product Category, UOM, dan Warehouse
**Requirement:** MST-002, MST-003, MST-004
**Dependency:** G2 fase 1 master-data foundation complete
**Status:** COMPLETE - LOCAL AUTHENTICATED SMOKE PASS

## Contract Keamanan

- Seluruh route memerlukan bearer token Supabase yang valid.
- `company_id` tidak diterima dari request body; server membaca active Company dari `user_active_company_contexts`.
- Query/mutation memakai Supabase client milik caller dan tetap melewati RLS.
- Service-role key tidak digunakan oleh route master.
- Update membutuhkan `masterVersion` dan memakai compare-and-set terhadap `master_version` database.
- Konflik tab/cache lama menghasilkan HTTP `409`, bukan overwrite diam-diam.
- Tidak tersedia endpoint `DELETE`; lifecycle memakai `isActive`.

## Endpoint

| Method | Route | Fungsi |
|---|---|---|
| GET/POST | `/api/master/product-categories` | List/create Category Company aktif |
| PATCH | `/api/master/product-categories/{id}` | Update/archive Category dengan version check |
| GET/POST | `/api/master/uoms` | List/create UOM dan precision contract |
| PATCH | `/api/master/uoms/{id}` | Update/archive UOM dengan version check |
| GET/POST | `/api/master/warehouses` | List/create Warehouse canonical |
| PATCH | `/api/master/warehouses/{id}` | Update/archive Warehouse dengan version check |

GET hanya mengembalikan master aktif. Tambahkan `?includeInactive=true` untuk
evaluasi/administrasi record nonaktif. Semua list dibatasi maksimal 200 row pada
fase awal; pagination cursor menjadi bagian import/list hardening berikutnya.

## Validasi Penting

- Category code dinormalisasi uppercase; Category name tidak boleh kosong/duplikat menurut constraint database.
- UOM integer wajib precision `0`; UOM decimal memakai precision `1..6`, default `3` pada create.
- Warehouse code hanya `A-Z`, panjang 1-5.
- Warehouse type hanya `CENTRAL`, `STORE`, `DAMAGED`, atau `TRANSIT`.
- Warehouse `STORE` wajib menunjuk Store aktif pada Company aktif.
- `allow_negative_stock` tidak dapat dikirim client dan selalu `false`.

## Local Smoke GET

Setelah login Backoffice dan memastikan Company aktif, buka Browser DevTools
Console pada origin Backoffice lalu jalankan:

```js
const authKey = Object.keys(localStorage).find(
  (key) => key.startsWith('sb-') && key.endsWith('-auth-token'),
)
const authValue = JSON.parse(localStorage.getItem(authKey))
const token = authValue.access_token
const headers = { Authorization: `Bearer ${token}` }

for (const path of [
  '/api/master/product-categories',
  '/api/master/uoms',
  '/api/master/warehouses',
]) {
  const response = await fetch(path, { headers })
  console.log(path, response.status, await response.json())
}
```

Expected: ketiga route HTTP `200`, `companyId` sama dengan Company aktif, dan
`data` masih array kosong bila belum ada master.

## Stop Condition

- `401`: login/session tidak valid; jangan bypass bearer validation.
- `400 ACTIVE_COMPANY_NOT_FOUND`: pilih Company aktif melalui Backoffice.
- `403`: role/RLS memang tidak mengizinkan aksi; jangan memakai service-role.
- `409`: refresh record dan ulangi edit berdasarkan `master_version` terbaru.
- Jangan melakukan POST test dengan data dummy permanen sebelum UI menyediakan workflow master yang jelas.

## Belum Termasuk

- Product dan Product-UOM atomic write API.
- Form/menu frontend Category, UOM, dan Warehouse berada pada G2 fase 3; lihat `G2_PHASE3_MASTER_UI_ROLLOUT.md`.
- Import dry-run/history/error rows.
- Pagination cursor dan cache payload version aggregate.
