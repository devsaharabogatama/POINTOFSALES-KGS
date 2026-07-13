const { createClient } = require('@supabase/supabase-js')
const fs = require('fs')
const path = require('path')

// Read env variables manually from .env.local
const envPath = path.join(__dirname, '..', '.env.local')
if (!fs.existsSync(envPath)) {
  console.error('File .env.local tidak ditemukan! Silakan salin .env.example menjadi .env.local terlebih dahulu.')
  process.exit(1)
}

const envContent = fs.readFileSync(envPath, 'utf8')
const env = {}
envContent.split('\n').forEach(line => {
  const parts = line.split('=')
  if (parts.length >= 2) {
    env[parts[0].trim()] = parts.slice(1).join('=').trim()
  }
})

const supabaseUrl = env.NEXT_PUBLIC_SUPABASE_URL
const supabaseAnonKey = env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY

if (!supabaseUrl || !supabaseAnonKey) {
  console.error('Supabase URL atau Anon Key belum disetel di .env.local!')
  process.exit(1)
}

const supabase = createClient(supabaseUrl, supabaseAnonKey)

async function run() {
  console.log('Mendaftarkan user kasir1@kgs.com secara aman via Supabase Auth API...')
  const { data, error } = await supabase.auth.signUp({
    email: 'kasir1@kgs.com',
    password: 'password123',
    options: {
      data: {
        name: 'Kasir KGS Utama'
      }
    }
  })

  if (error) {
    console.error('Pendaftaran Gagal:', error.message)
  } else {
    console.log('========================================================')
    console.log('PENDAFTARAN USER SUKSES!')
    console.log('User ID Anda:', data.user.id)
    console.log('========================================================')
    console.log('\nJalankan SQL berikut di Supabase SQL Editor untuk menghubungkan user ke Company A:')
    console.log(`
-- 1. Buat Perusahaan
INSERT INTO companies (id, company_code, company_name, company_slug, status)
VALUES ('11111111-1111-1111-1111-111111111111', 'COMP-A', 'Company A', 'company-a', 'ACTIVE')
ON CONFLICT (id) DO NOTHING;

-- 2. Buat Toko
INSERT INTO stores (id, company_id, store_code, store_name, status)
VALUES ('11111111-1111-1111-1111-111111111112', '11111111-1111-1111-1111-111111111111', 'STORE-A', 'Store A', 'ACTIVE')
ON CONFLICT (id) DO NOTHING;

-- 3. Hubungkan User Anda ke Company A
INSERT INTO company_memberships (company_id, user_id, role_code, status)
VALUES ('11111111-1111-1111-1111-111111111111', '${data.user.id}', 'COMPANY_OWNER', 'ACTIVE')
ON CONFLICT DO NOTHING;

-- 4. Hubungkan User Anda ke Store A
INSERT INTO store_memberships (company_id, store_id, user_id, status)
VALUES ('11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111112', '${data.user.id}', 'ACTIVE')
ON CONFLICT DO NOTHING;

-- 5. Buat Gudang Default
INSERT INTO warehouses (company_id, code, name, is_active)
VALUES 
    ('11111111-1111-1111-1111-111111111111', 'GDS', 'Gudang Utama GDS', true),
    ('11111111-1111-1111-1111-111111111111', 'KGS', 'Toko Kasir KGS', true)
ON CONFLICT DO NOTHING;
    `)
  }
}

run()
