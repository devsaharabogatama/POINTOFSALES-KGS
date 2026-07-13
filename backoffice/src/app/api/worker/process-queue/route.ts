import { NextResponse } from 'next/server'
import { supabase } from '@/lib/supabase'

export async function POST(request: Request) {
  try {
    // Optionally check for auth token/cron key to secure the worker
    const authHeader = request.headers.get('authorization')
    const cronKey = process.env.CRON_SECRET
    
    if (cronKey && authHeader !== `Bearer ${cronKey}`) {
      return NextResponse.json({ error: 'Unauthorized worker invocation.' }, { status: 401 })
    }

    // Call the Postgres RPC function which handles the event queue processing inside database transaction
    const { data, error } = await supabase.rpc('process_financial_events_queue')

    if (error) {
      console.error('Worker queue processing error:', error)
      return NextResponse.json({ error: error.message }, { status: 400 })
    }

    return NextResponse.json({ 
      success: true, 
      processed: data?.processed || 0,
      errors: data?.errors || 0,
      details: data?.results || []
    })
  } catch (error: any) {
    console.error('Worker route error:', error)
    return NextResponse.json({ error: error.message }, { status: 500 })
  }
}

// Support GET requests for easy testing / manual trigger via browser/cron curl
export async function GET(request: Request) {
  try {
    const { data, error } = await supabase.rpc('process_financial_events_queue')

    if (error) {
      return NextResponse.json({ error: error.message }, { status: 400 })
    }

    return NextResponse.json({ 
      success: true, 
      processed: data?.processed || 0,
      errors: data?.errors || 0,
      details: data?.results || []
    })
  } catch (error: any) {
    return NextResponse.json({ error: error.message }, { status: 500 })
  }
}
