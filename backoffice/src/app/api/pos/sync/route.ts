import { NextResponse } from 'next/server'
import { apiError, requireCaller } from '@/lib/server-auth'

export async function POST(request: Request) {
  try {
    await requireCaller(request)
    return NextResponse.json(
      {
        error: 'OFFLINE_SYNC_NOT_ENABLED',
        message:
          'Offline allowance, queue acknowledgement, and conflict handling are not enabled yet. No Sale was written.',
      },
      { status: 409 },
    )
  } catch (error: unknown) {
    return apiError(error)
  }
}
