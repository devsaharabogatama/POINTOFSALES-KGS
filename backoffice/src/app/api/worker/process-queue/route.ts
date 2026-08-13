export async function POST() {
  return Response.json(
    {
      error: 'LEGACY_FINANCE_WORKER_RETIRED',
      message:
        'Gunakan controlled Finance posting queue. Worker lama tidak lagi menjadi execution path.',
    },
    { status: 410 },
  )
}
