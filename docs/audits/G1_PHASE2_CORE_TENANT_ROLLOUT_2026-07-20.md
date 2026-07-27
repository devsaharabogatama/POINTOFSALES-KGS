# Evidence G1 Fase 2 — Core Tenant Consistency

**Tanggal:** 2026-07-20  
**Requirement:** TEN-001  
**Status:** COMPLETE berdasarkan rollout manual dan konfirmasi user.

## Evidence

- Migration `20260720120000` telah dijalankan pada Supabase aktif.
- Preflight, postflight, dan behavioral constraint test dikonfirmasi aman oleh user.
- Compatibility query Product → Stock → Warehouse telah menghasilkan HTTP 200.
- Backoffice dan PWA lint/build PASS setelah relationship hint eksplisit ditambahkan.
- User mengonfirmasi notifikasi gagal memuat data Company/frontend sudah tidak muncul dan local smoke aman.

Raw export preflight/postflight fase 2 tidak disimpan di repository. Status di atas adalah evidence rollout manual yang dikonfirmasi user, bukan hasil eksekusi database oleh agent.

## Compatibility

- FK single-ID legacy tetap tersedia.
- Composite tenant FK tetap menjadi invariant database.
- Query PostgREST embed pada relasi yang ambigu wajib memakai nama FK eksplisit.

## Boundary Berikutnya

Fase 2 tidak menambahkan UI Product/UOM/Warehouse. UI tersebut tetap masuk G2 setelah seluruh boundary G1 selesai.
