import { incrementInstallCount } from '$lib/server/installCounter';
import { redirect } from '@sveltejs/kit';

export async function GET() {
  await incrementInstallCount();
  redirect(302, '/downloads/WhileItThinks-0.1.0.dmg');
}
