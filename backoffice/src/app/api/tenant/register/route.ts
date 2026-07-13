import { NextResponse } from 'next/server'
import { createClient } from '@supabase/supabase-js'

export async function POST(request: Request) {
  try {
    const body = await request.json()
    const { email, password, name, company_code, company_name } = body

    if (!email || !password || !name || !company_code || !company_name) {
      return NextResponse.json({ error: 'Missing required fields: email, password, name, company_code, company_name' }, { status: 400 })
    }

    const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL || ''
    const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY

    if (!serviceRoleKey) {
      return NextResponse.json({ 
        error: 'SUPABASE_SERVICE_ROLE_KEY is not configured in .env.local on the server. Please add it to allow admin registration.' 
      }, { status: 500 })
    }

    // Initialize Supabase admin client
    const adminClient = createClient(supabaseUrl, serviceRoleKey, {
      auth: {
        autoRefreshToken: false,
        persistSession: false
      }
    })

    // 1. Create the user account in auth.users
    const { data: authUser, error: authErr } = await adminClient.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: { name }
    })

    if (authErr) {
      console.error('Admin Auth createUser error:', authErr)
      return NextResponse.json({ error: authErr.message }, { status: 400 })
    }

    const newUserId = authUser.user.id
    const companyId = crypto.randomUUID()
    const storeId = crypto.randomUUID()

    // 2. Insert Profile as 'owner'
    const { error: profileErr } = await adminClient
      .from('profiles')
      .upsert({
        id: newUserId,
        email,
        name,
        role: 'owner'
      })

    if (profileErr) {
      console.error('Profile upsert error:', profileErr)
      return NextResponse.json({ error: profileErr.message }, { status: 400 })
    }

    // 3. Create Company (Completely unique tenant)
    const { error: compErr } = await adminClient
      .from('companies')
      .insert({
        id: companyId,
        company_code,
        company_name,
        company_slug: company_code.toLowerCase().replace(/\s+/g, '-'),
        status: 'ACTIVE'
      })

    if (compErr) {
      console.error('Company creation error:', compErr)
      return NextResponse.json({ error: compErr.message }, { status: 400 })
    }

    // 4. Create default Store
    const { error: storeErr } = await adminClient
      .from('stores')
      .insert({
        id: storeId,
        company_id: companyId,
        store_code: 'STORE-MAIN',
        store_name: 'Main Store',
        status: 'ACTIVE'
      })

    if (storeErr) {
      console.error('Store creation error:', storeErr)
      return NextResponse.json({ error: storeErr.message }, { status: 400 })
    }

    // 5. Create default warehouses (GDS & KGS)
    const { error: whErr } = await adminClient
      .from('warehouses')
      .insert([
        { company_id: companyId, code: 'GDS', name: 'Gudang Utama GDS', is_active: true },
        { company_id: companyId, code: 'KGS', name: 'Toko Kasir KGS', is_active: true }
      ])

    if (whErr) {
      console.error('Warehouses creation error:', whErr)
      return NextResponse.json({ error: whErr.message }, { status: 400 })
    }

    // 6. Link User to Company as OWNER
    const { error: cmErr } = await adminClient
      .from('company_memberships')
      .insert({
        company_id: companyId,
        user_id: newUserId,
        role_code: 'COMPANY_OWNER',
        status: 'ACTIVE'
      })

    if (cmErr) {
      console.error('Company membership creation error:', cmErr)
      return NextResponse.json({ error: cmErr.message }, { status: 400 })
    }

    // 7. Link User to Store
    const { error: smErr } = await adminClient
      .from('store_memberships')
      .insert({
        company_id: companyId,
        store_id: storeId,
        user_id: newUserId,
        status: 'ACTIVE'
      })

    if (smErr) {
      console.error('Store membership creation error:', smErr)
      return NextResponse.json({ error: smErr.message }, { status: 400 })
    }

    return NextResponse.json({ success: true, userId: newUserId, companyId })
  } catch (error: any) {
    console.error('Tenant registration error:', error)
    return NextResponse.json({ error: error.message }, { status: 500 })
  }
}
