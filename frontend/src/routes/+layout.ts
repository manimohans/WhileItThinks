import { browser, dev } from '$app/environment';
import { injectAnalytics } from '@vercel/analytics/sveltekit';

if (browser) {
  const isLocalhost = window.location.hostname === 'localhost' || window.location.hostname === '127.0.0.1';

  injectAnalytics({ mode: dev || isLocalhost ? 'development' : 'production' });
}
