import { createAdminClient } from '@/lib/server-auth'

export async function POST(request: Request) {
  const cronSecret = process.env.CRON_SECRET
  if (!cronSecret || request.headers.get('authorization') !== `Bearer ${cronSecret}`) {
    return Response.json({ error: 'UNAUTHORIZED_WORKER_INVOCATION' }, { status: 401 })
  }

  try {
    const { data, error } = await createAdminClient().rpc('process_financial_events_queue')
    if (error) return Response.json({ error: error.message }, { status: 400 })
    return Response.json({ success: true, result: data })
  } catch (error) {
    const message = error instanceof Error ? error.message : 'UNKNOWN_WORKER_ERROR'
    return Response.json({ error: message }, { status: 500 })
  }
}
