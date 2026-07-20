const { createClient } = require('@supabase/supabase-js')
const fs = require('fs')
const path = require('path')

// Read env variables manually
const envPath = path.join(__dirname, '..', '.env.local')
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

const supabase = createClient(supabaseUrl, supabaseAnonKey)

async function inspect() {
  console.log('Connecting to Supabase:', supabaseUrl)
  
  // 1. Get profiles
  const { data: users, error: userErr } = await supabase.from('profiles').select('*')
  console.log('Profiles:', users, userErr)

  // 2. Get companies
  const { data: companies, error: compErr } = await supabase.from('companies').select('*')
  console.log('Companies:', companies, compErr)

  // 3. Get memberships
  const { data: memberships, error: memErr } = await supabase.from('company_memberships').select('*')
  console.log('Company Memberships:', memberships, memErr)
}

inspect()
