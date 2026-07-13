import { NextResponse } from 'next/server'
import { createClient } from '@supabase/supabase-js'

export async function POST(request: Request) {
  try {
    const body = await request.json()
    const { email, password, name, role_code, company_id, store_id } = body

    if (!email || !password || !name || !role_code || !company_id) {
      return NextResponse.json({ error: 'Missing required fields: email, password, name, role_code, company_id' }, { status: 400 })
    }

    const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL || ''
    const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY

    if (!serviceRoleKey) {
      return NextResponse.json({ 
        error: 'SUPABASE_SERVICE_ROLE_KEY is not configured in .env.local on the server. Please add it to allow admin user creation.' 
      }, { status: 500 })
    }

    // Initialize Supabase admin client with service_role key to bypass RLS and create users
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

    // 2. Ensure profile is inserted (the handle_new_user trigger should run, but we make sure role and name are correct)
    const { error: profileErr } = await adminClient
      .from('profiles')
      .upsert({
        id: newUserId,
        email,
        name,
        role: (role_code === 'CASHIER' ? 'cashier' : 'cashier') // Map fallback role enum if needed
      })

    if (profileErr) {
      console.error('Profile upsert error:', profileErr)
      return NextResponse.json({ error: profileErr.message }, { status: 400 })
    }

    // 3. Create Company Membership (Role: COMPANY_OWNER, COMPANY_ADMIN, etc.)
    const { error: cmErr } = await adminClient
      .from('company_memberships')
      .insert({
        company_id,
        user_id: newUserId,
        role_code,
        status: 'ACTIVE'
      })

    if (cmErr) {
      console.error('Company membership creation error:', cmErr)
      return NextResponse.json({ error: cmErr.message }, { status: 400 })
    }

    // 4. Create Store Membership if store_id is provided
    if (store_id && store_id !== 'NONE') {
      const { error: smErr } = await adminClient
        .from('store_memberships')
        .insert({
          company_id,
          store_id,
          user_id: newUserId,
          status: 'ACTIVE'
        })

      if (smErr) {
        console.error('Store membership creation error:', smErr)
        return NextResponse.json({ error: smErr.message }, { status: 400 })
      }
    }

    return NextResponse.json({ success: true, userId: newUserId })
  } catch (error: any) {
    console.error('Staff creation API error:', error)
    return NextResponse.json({ error: error.message }, { status: 500 })
  }
}
