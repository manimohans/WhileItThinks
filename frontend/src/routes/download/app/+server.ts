import appDmg from '$lib/server/assets/WhileItThinks-0.1.0.dmg';
import { getDownloadTokenKey, isDownloadToken } from '$lib/server/downloadAccess';
import { claimInstallDownload, INSTALL_LIMIT } from '$lib/server/installCounter';
import { read } from '$app/server';
import { error } from '@sveltejs/kit';
import type { RequestHandler } from './$types';

export const GET: RequestHandler = async ({ url }) => {
  const token = url.searchParams.get('token')?.trim() ?? '';
  if (!isDownloadToken(token)) {
    error(403, 'Enter a valid email address to get a download link.');
  }

  const claim = await claimInstallDownload(getDownloadTokenKey(token));

  if (!claim) {
    error(503, 'Download temporarily unavailable.');
  }

  if (claim.reason === 'invalid-token') {
    error(403, 'Enter a valid email address to get a download link.');
  }

  if (!claim.claimed) {
    error(403, `The first ${INSTALL_LIMIT.toLocaleString()} free launch installs are claimed.`);
  }

  const asset = read(appDmg);
  const headers = new Headers(asset.headers);
  headers.set('Content-Disposition', 'attachment; filename="WhileItThinks-0.1.0.dmg"');
  headers.set('Content-Type', 'application/x-apple-diskimage');
  headers.set('Cache-Control', 'private, no-store');

  return new Response(asset.body, {
    headers,
    status: 200
  });
};
