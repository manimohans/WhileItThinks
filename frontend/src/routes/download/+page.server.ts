import { getInstallCount } from '$lib/server/installCounter';

export async function load() {
  return {
    installCount: await getInstallCount()
  };
}
