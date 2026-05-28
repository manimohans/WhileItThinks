import { createDownloadAccess } from '$lib/server/downloadAccess';
import { json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';

export const POST: RequestHandler = async ({ request }) => {
  let email = '';

  try {
    const body = (await request.json()) as { email?: unknown };
    email = typeof body.email === 'string' ? body.email : '';
  } catch {
    return json({ error: 'Enter a valid email address.' }, { status: 400 });
  }

  const result = await createDownloadAccess(email);
  if (!result.ok) {
    return json({ error: result.error }, { status: result.status });
  }

  return json(result);
};
