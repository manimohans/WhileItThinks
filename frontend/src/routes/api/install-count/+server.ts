import { getInstallCount } from '$lib/server/installCounter';
import { json } from '@sveltejs/kit';

export async function GET() {
  return json({
    count: await getInstallCount()
  });
}
