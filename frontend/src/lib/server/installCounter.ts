import { env } from '$env/dynamic/private';

const DEFAULT_COUNT_KEY = 'whileitthinks:install_count';
const COUNT_SEED = 12;
const CLAIM_SCRIPT = `
local current = redis.call('GET', KEYS[1])
if not current then
  redis.call('SET', KEYS[1], ARGV[1])
  current = ARGV[1]
end

current = tonumber(current)
local limit = tonumber(ARGV[2])
if current >= limit then
  return {current, 0}
end

current = redis.call('INCR', KEYS[1])
return {current, 1}
`;

export const INSTALL_LIMIT = 1000;

export type InstallStatus = {
  count: number;
  limit: number;
  isLimitReached: boolean;
};

export type InstallClaim = InstallStatus & {
  claimed: boolean;
};

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

function getCountKey(): string {
  return env.INSTALL_COUNT_KEY || DEFAULT_COUNT_KEY;
}

function asCount(value: unknown): number | null {
  if (value === null || value === undefined) {
    return null;
  }

  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : null;
}

function toStatus(count: number): InstallStatus {
  return {
    count,
    limit: INSTALL_LIMIT,
    isLimitReached: count >= INSTALL_LIMIT
  };
}

export async function getInstallCount(): Promise<number> {
  try {
    return asCount(await redisCommand<string | number | null>(['GET', getCountKey()])) ?? COUNT_SEED;
  } catch {
    return COUNT_SEED;
  }
}

export async function getInstallStatus(): Promise<InstallStatus> {
  return toStatus(await getInstallCount());
}

function parseClaim(value: unknown): InstallClaim | null {
  if (!Array.isArray(value)) {
    return null;
  }

  const count = asCount(value[0]);
  const claimed = Number(value[1]) === 1;
  return count === null ? null : { ...toStatus(count), claimed };
}

export async function claimInstallDownload(): Promise<InstallClaim | null> {
  try {
    return parseClaim(
      await redisCommand<Array<number | string>>([
        'EVAL',
        CLAIM_SCRIPT,
        1,
        getCountKey(),
        COUNT_SEED,
        INSTALL_LIMIT
      ])
    );
  } catch {
    return null;
  }
}
