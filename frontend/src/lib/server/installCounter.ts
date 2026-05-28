import { env } from '$env/dynamic/private';
import { redisCommand } from '$lib/server/redis';

const DEFAULT_COUNT_KEY = 'whileitthinks:install_count';
const COUNT_SEED = 12;
const CLAIM_SCRIPT = `
local token = redis.call('GET', KEYS[2])
if not token then
  return {0, 0, 'invalid-token'}
end

local current = redis.call('GET', KEYS[1])
if not current then
  redis.call('SET', KEYS[1], ARGV[1])
  current = ARGV[1]
end

current = tonumber(current)
local limit = tonumber(ARGV[2])
if current >= limit then
  return {current, 0, 'limit'}
end

current = redis.call('INCR', KEYS[1])
redis.call('DEL', KEYS[2])
return {current, 1, 'claimed'}
`;

export const INSTALL_LIMIT = 1000;

export type InstallStatus = {
  count: number;
  limit: number;
  isLimitReached: boolean;
};

export type InstallClaim = InstallStatus & {
  claimed: boolean;
  reason: 'claimed' | 'limit' | 'invalid-token';
};

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

  const reason = value[2];
  if (reason !== 'claimed' && reason !== 'limit' && reason !== 'invalid-token') {
    return null;
  }

  const count = asCount(value[0]) ?? COUNT_SEED;
  const claimed = Number(value[1]) === 1;
  return { ...toStatus(count), claimed, reason };
}

export async function claimInstallDownload(tokenKey: string): Promise<InstallClaim | null> {
  try {
    return parseClaim(
      await redisCommand<Array<number | string>>([
        'EVAL',
        CLAIM_SCRIPT,
        2,
        getCountKey(),
        tokenKey,
        COUNT_SEED,
        INSTALL_LIMIT
      ])
    );
  } catch {
    return null;
  }
}
