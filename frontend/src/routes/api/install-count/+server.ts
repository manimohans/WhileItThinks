import { getInstallStatus } from '$lib/server/installCounter';
import { json } from '@sveltejs/kit';

export async function GET() {
  const status = await getInstallStatus();

  return json({
    available: !status.isLimitReached,
    count: status.count,
    limit: status.limit
  });
}
