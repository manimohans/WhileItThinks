import { getInstallStatus } from '$lib/server/installCounter';

export async function load() {
  const status = await getInstallStatus();

  return {
    installCount: status.count,
    installLimit: status.limit,
    isLimitReached: status.isLimitReached
  };
}
