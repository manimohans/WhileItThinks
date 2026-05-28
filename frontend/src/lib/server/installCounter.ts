import { env } from '$env/dynamic/private';

const COUNT_KEY = 'whileitthinks:install_count';
const COUNT_SEED = 12;

type UpstashResponse<T> = {
  result?: T;
  error?: string;
};

async function redisCommand<T>(command: Array<string | number>): Promise<T | null> {
  if (!env.UPSTASH_REDIS_REST_URL || !env.UPSTASH_REDIS_REST_TOKEN) {
    return null;
  }

  const response = await fetch(env.UPSTASH_REDIS_REST_URL, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${env.UPSTASH_REDIS_REST_TOKEN}`,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify(command)
  });

  if (!response.ok) {
    throw new Error(`Upstash command failed with HTTP ${response.status}`);
  }

  const payload = (await response.json()) as UpstashResponse<T>;
  if (payload.error) {
    throw new Error(payload.error);
  }

  return payload.result ?? null;
}

function asCount(value: unknown): number | null {
  if (value === null || value === undefined) {
    return null;
  }

  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : null;
}

export async function getInstallCount(): Promise<number> {
  try {
    return asCount(await redisCommand<string | number | null>(['GET', COUNT_KEY])) ?? COUNT_SEED;
  } catch {
    return COUNT_SEED;
  }
}

export async function incrementInstallCount(): Promise<number | null> {
  try {
    await redisCommand<string>(['SET', COUNT_KEY, COUNT_SEED, 'NX']);
    return asCount(await redisCommand<number>(['INCR', COUNT_KEY]));
  } catch {
    return null;
  }
}
