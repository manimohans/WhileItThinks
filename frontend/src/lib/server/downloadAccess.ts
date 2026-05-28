import { env } from '$env/dynamic/private';
import { getInstallStatus } from '$lib/server/installCounter';
import { redisCommand } from '$lib/server/redis';

const DEFAULT_EMAIL_SET_KEY = 'whileitthinks:download_emails';
const DEFAULT_EMAIL_META_KEY = 'whileitthinks:download_email_requested_at';
const DEFAULT_TOKEN_PREFIX = 'whileitthinks:download_token:';
const DOWNLOAD_TOKEN_TTL_SECONDS = 60 * 60 * 24 * 7;
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;
const TOKEN_PATTERN = /^[a-f0-9-]{36}$/i;

type DownloadAccessResult =
  | {
      ok: true;
      downloadUrl: string;
      email: string;
      expiresInSeconds: number;
    }
  | {
      ok: false;
      error: string;
      status: number;
    };

function getEmailSetKey(): string {
  return env.DOWNLOAD_EMAIL_SET_KEY || DEFAULT_EMAIL_SET_KEY;
}

function getEmailMetaKey(): string {
  return env.DOWNLOAD_EMAIL_META_KEY || DEFAULT_EMAIL_META_KEY;
}

function getTokenPrefix(): string {
  return env.DOWNLOAD_TOKEN_PREFIX || DEFAULT_TOKEN_PREFIX;
}

function normalizeEmail(email: string): string {
  return email.trim().toLowerCase();
}

export function getDownloadTokenKey(token: string): string {
  return `${getTokenPrefix()}${token}`;
}

export function isDownloadToken(token: string): boolean {
  return TOKEN_PATTERN.test(token);
}

export function isValidEmail(email: string): boolean {
  const normalized = normalizeEmail(email);
  return normalized.length <= 254 && EMAIL_PATTERN.test(normalized);
}

export async function createDownloadAccess(email: string): Promise<DownloadAccessResult> {
  const normalizedEmail = normalizeEmail(email);

  if (!isValidEmail(normalizedEmail)) {
    return {
      ok: false,
      error: 'Enter a valid email address.',
      status: 400
    };
  }

  const status = await getInstallStatus();
  if (status.isLimitReached) {
    return {
      ok: false,
      error: `The first ${status.limit.toLocaleString()} free launch installs are claimed.`,
      status: 403
    };
  }

  const token = crypto.randomUUID();
  const now = new Date().toISOString();
  const tokenPayload = JSON.stringify({
    email: normalizedEmail,
    createdAt: now
  });

  try {
    const tokenCreated = await redisCommand<string>([
      'SET',
      getDownloadTokenKey(token),
      tokenPayload,
      'EX',
      DOWNLOAD_TOKEN_TTL_SECONDS,
      'NX'
    ]);

    if (tokenCreated !== 'OK') {
      return {
        ok: false,
        error: 'Download link temporarily unavailable.',
        status: 503
      };
    }

    await redisCommand<number>(['SADD', getEmailSetKey(), normalizedEmail]);
    await redisCommand<number>(['HSET', getEmailMetaKey(), normalizedEmail, now]);

    return {
      ok: true,
      downloadUrl: `/download/app?token=${encodeURIComponent(token)}`,
      email: normalizedEmail,
      expiresInSeconds: DOWNLOAD_TOKEN_TTL_SECONDS
    };
  } catch {
    return {
      ok: false,
      error: 'Download link temporarily unavailable.',
      status: 503
    };
  }
}
