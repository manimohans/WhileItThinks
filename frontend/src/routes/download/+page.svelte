<script lang="ts">
  import type { PageData } from './$types';

  const siteUrl = 'https://whileitthinks.com';
  const downloadPath = '/download/app';
  let { data }: { data: PageData } = $props();
  let email = $state('');
  let downloadLink = $state('');
  let downloadEmail = $state('');
  let formError = $state('');
  let isSubmitting = $state(false);

  const installSteps = [
    'Download the DMG.',
    'Drag WhileItThinks into Applications.',
    'Open the Mac app and start the local receiver.',
    'Enable Claude Code, Codex, or both from the app.'
  ];

  let downloadJsonLd = $derived(
    JSON.stringify({
      '@context': 'https://schema.org',
      '@type': 'SoftwareApplication',
      name: 'WhileItThinks',
      applicationCategory: 'DeveloperApplication',
      operatingSystem: 'macOS 14+',
      url: `${siteUrl}/download`,
      downloadUrl: `${siteUrl}${downloadPath}`,
      description:
        'Download WhileItThinks, the local-first macOS app that gives break and return cues for Claude Code and Codex.',
      offers: {
        '@type': 'Offer',
        priceCurrency: 'USD',
        price: '0',
        availability: data.isLimitReached
          ? 'https://schema.org/SoldOut'
          : 'https://schema.org/InStock'
      }
    }).replace(/</g, '\\u003c')
  );

  let structuredDataHead = $derived(
    '<scr' + `ipt type="application/ld+json">${downloadJsonLd}</scr` + 'ipt>'
  );

  function looksLikeEmail(value: string): boolean {
    return /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(value.trim());
  }

  async function requestDownload(event: SubmitEvent) {
    event.preventDefault();

    if (data.isLimitReached || isSubmitting) {
      return;
    }

    const requestedEmail = email.trim();
    downloadLink = '';
    downloadEmail = '';
    formError = '';

    if (!looksLikeEmail(requestedEmail)) {
      formError = 'Enter a valid email address.';
      return;
    }

    isSubmitting = true;

    try {
      const response = await fetch('/api/download-request', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({ email: requestedEmail })
      });
      const payload = (await response.json().catch(() => ({}))) as {
        downloadUrl?: unknown;
        email?: unknown;
        error?: unknown;
      };

      if (!response.ok) {
        formError =
          typeof payload.error === 'string' ? payload.error : 'Download link temporarily unavailable.';
        return;
      }

      if (typeof payload.downloadUrl !== 'string') {
        formError = 'Download link temporarily unavailable.';
        return;
      }

      downloadLink = payload.downloadUrl;
      downloadEmail = typeof payload.email === 'string' ? payload.email : requestedEmail;
    } catch {
      formError = 'Download link temporarily unavailable.';
    } finally {
      isSubmitting = false;
    }
  }
</script>

<svelte:head>
  <title>Download WhileItThinks for macOS</title>
  <meta
    name="description"
    content="Download WhileItThinks for macOS. Get local break and return cues while Claude Code and Codex are busy."
  />
  <meta name="robots" content="index,follow,max-image-preview:large,max-snippet:-1" />
  <link rel="canonical" href={`${siteUrl}/download`} />
  <link rel="icon" href="/logo.svg" type="image/svg+xml" />
  <meta property="og:type" content="website" />
  <meta property="og:url" content={`${siteUrl}/download`} />
  <meta property="og:title" content="Download WhileItThinks for macOS" />
  <meta
    property="og:description"
    content="Get the local-first Mac app that gives developers break and return cues for Claude Code and Codex."
  />
  <meta property="og:image" content={`${siteUrl}/og.png`} />
  <meta name="twitter:card" content="summary_large_image" />
  <meta name="twitter:title" content="Download WhileItThinks for macOS" />
  <meta
    name="twitter:description"
    content="Download the launch build for Claude Code and Codex wait-state cues."
  />
  <meta name="twitter:image" content={`${siteUrl}/og.png`} />
  {@html structuredDataHead}
</svelte:head>

<main class="download-page">
  <a class="brand" href="/" aria-label="Back to WhileItThinks home">
    <img src="/logo.svg" alt="" width="42" height="42" />
    <span>WhileItThinks</span>
  </a>

  <section class="download-hero" aria-labelledby="download-title">
    <div class="download-copy">
      <p class="eyebrow">Download for macOS</p>
      <h1 id="download-title">Get the launch build.</h1>
      <p>
        {#if data.isLimitReached}
          The first {data.installLimit.toLocaleString()} free launch installs are claimed. Downloads
          are paused until paid checkout is ready.
        {:else}
          WhileItThinks gives developers a local break and return cue while Claude Code and Codex are
          busy. The first {data.installLimit.toLocaleString()} installs are free.
        {/if}
      </p>
      <p class="install-count">
        <span>{data.installCount.toLocaleString()}</span>
        launch installs claimed
      </p>
      <div class="download-actions">
        {#if data.isLimitReached}
          <button class="button button-primary" type="button" disabled>Download paused</button>
        {:else}
          <form class="email-gate" onsubmit={requestDownload}>
            <label for="download-email">Email address</label>
            <div class="email-row">
              <input
                id="download-email"
                bind:value={email}
                type="email"
                name="email"
                autocomplete="email"
                inputmode="email"
                maxlength="254"
                placeholder="you@example.com"
                required
                aria-describedby="download-email-status"
              />
              <button class="button button-primary" type="submit" disabled={isSubmitting}>
                {isSubmitting ? 'Preparing...' : 'Get download link'}
              </button>
            </div>
            <p id="download-email-status" class="form-status" aria-live="polite">
              {#if formError}
                {formError}
              {:else if downloadLink}
                Link ready for {downloadEmail}.
              {:else}
                Valid email required for the launch download.
              {/if}
            </p>
            {#if downloadLink}
              <a class="button button-primary download-link" href={downloadLink} rel="nofollow">
                Download DMG
              </a>
            {/if}
          </form>
        {/if}
      </div>
    </div>

    <div class="license-card" aria-label="Launch pricing">
      <span>Lifetime license</span>
      <strong>First {data.installLimit.toLocaleString()} installs: free</strong>
      <p>
        {#if data.isLimitReached}
          Downloads are paused until the paid checkout is ready.
        {:else}
          {data.installCount.toLocaleString()} installs claimed. Downloads pause at
          {data.installLimit.toLocaleString()} until paid checkout is ready.
        {/if}
      </p>
    </div>
  </section>

  <section class="install-section" aria-labelledby="install-title">
    <div>
      <p class="eyebrow eyebrow-muted">Setup</p>
      <h2 id="install-title">Install it once, then keep working normally.</h2>
    </div>
    <ol>
      {#each installSteps as step, index}
        <li>
          <span>{String(index + 1).padStart(2, '0')}</span>
          <p>{step}</p>
        </li>
      {/each}
    </ol>
  </section>
</main>

<style>
  :global(body) {
    background:
      linear-gradient(118deg, rgba(196, 232, 255, 0.55) 0 28%, transparent 28%),
      linear-gradient(20deg, transparent 0 66%, rgba(255, 218, 182, 0.55) 66%),
      var(--page);
  }

  .download-page {
    display: grid;
    gap: clamp(44px, 7vw, 82px);
    min-height: 100svh;
    padding: clamp(22px, 5vw, 70px);
  }

  .brand {
    display: inline-flex;
    align-items: center;
    gap: 12px;
    width: fit-content;
    color: var(--ink);
    font-family: var(--analog);
    font-size: clamp(1rem, 1.8vw, 1.35rem);
    font-weight: 950;
  }

  .brand img {
    border: 2px solid var(--ink);
    border-radius: 8px;
    background: var(--surface);
    box-shadow: 3px 3px 0 var(--shadow);
  }

  .download-hero,
  .install-section {
    display: grid;
    grid-template-columns: minmax(0, 0.95fr) minmax(300px, 0.62fr);
    gap: clamp(28px, 6vw, 74px);
    align-items: start;
    width: min(100%, 1180px);
    margin-inline: auto;
  }

  .download-copy {
    max-width: 720px;
  }

  .eyebrow {
    display: inline-flex;
    align-items: center;
    min-height: 32px;
    margin: 0 0 18px;
    border: 2px solid var(--ink);
    border-radius: 8px;
    padding: 0 12px;
    background: var(--blue-soft);
    color: var(--ink);
    font-family: var(--analog);
    font-size: 0.76rem;
    font-weight: 950;
    letter-spacing: 0.1em;
    text-transform: uppercase;
    box-shadow: 4px 4px 0 var(--shadow);
  }

  .eyebrow-muted {
    background: var(--surface);
  }

  h1,
  h2,
  p {
    margin-top: 0;
  }

  h1,
  h2 {
    color: var(--ink);
    letter-spacing: 0;
    text-wrap: balance;
  }

  h1 {
    max-width: 11ch;
    margin-bottom: 22px;
    font-size: clamp(3.4rem, 8vw, 6.5rem);
    line-height: 0.92;
  }

  h2 {
    margin-bottom: 0;
    font-size: clamp(2.3rem, 5vw, 4.8rem);
    line-height: 0.98;
  }

  p {
    color: var(--muted);
    font-size: clamp(1.05rem, 1.7vw, 1.25rem);
    line-height: 1.65;
  }

  .download-actions {
    display: flex;
    flex-wrap: wrap;
    align-items: flex-start;
    gap: 14px;
    margin-top: 28px;
  }

  .email-gate {
    display: grid;
    flex: 1 1 430px;
    gap: 12px;
    max-width: 620px;
  }

  .email-gate label {
    color: var(--ink);
    font-size: 0.86rem;
    font-weight: 850;
  }

  .email-row {
    display: flex;
    flex-wrap: wrap;
    gap: 12px;
  }

  .email-row input {
    flex: 1 1 230px;
    min-height: 52px;
    min-width: 0;
    border: 2px solid var(--ink);
    border-radius: 8px;
    padding: 0 16px;
    background: var(--surface);
    color: var(--ink);
    font: inherit;
    font-size: 1rem;
    box-shadow: 5px 5px 0 rgba(12, 25, 30, 0.16);
  }

  .email-row input:focus {
    outline: 3px solid rgba(255, 195, 73, 0.45);
    outline-offset: 2px;
  }

  .form-status {
    min-height: 1.5em;
    margin: 0;
    color: var(--muted);
    font-size: 0.95rem;
    line-height: 1.5;
  }

  .download-link {
    justify-self: start;
  }

  .install-count {
    display: inline-flex;
    align-items: center;
    gap: 10px;
    margin: 6px 0 0;
    border: 2px solid var(--ink);
    border-radius: 999px;
    padding: 8px 14px;
    background: var(--surface);
    color: var(--muted);
    font-size: 0.95rem;
    font-weight: 800;
    line-height: 1.2;
    box-shadow: 4px 4px 0 rgba(12, 25, 30, 0.16);
  }

  .install-count span {
    color: var(--ink);
    font-family: var(--analog);
    font-weight: 950;
  }

  .button {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    min-height: 52px;
    border: 2px solid var(--ink);
    border-radius: 8px;
    padding: 0 22px;
    color: var(--ink);
    font-weight: 850;
    line-height: 1;
    text-align: center;
    box-shadow: 5px 5px 0 var(--shadow);
  }

  button.button {
    cursor: default;
    font: inherit;
  }

  .button:disabled {
    background: var(--surface);
    color: var(--muted);
    opacity: 0.72;
  }

  .button-primary {
    background: var(--amber);
  }

  .license-card {
    display: grid;
    gap: 12px;
    border: 2px solid var(--ink);
    border-radius: 8px;
    padding: clamp(20px, 3vw, 28px);
    background: var(--amber-soft);
    box-shadow: 8px 8px 0 var(--shadow);
  }

  .license-card span {
    color: var(--coral);
    font-family: var(--analog);
    font-size: 0.76rem;
    font-weight: 950;
    letter-spacing: 0.1em;
    text-transform: uppercase;
  }

  .license-card strong {
    color: var(--ink);
    font-size: clamp(1.5rem, 3vw, 2.2rem);
    line-height: 1.05;
  }

  .license-card p {
    margin-bottom: 0;
  }

  .install-section {
    align-items: start;
    padding-top: clamp(24px, 4vw, 48px);
    border-top: 1px solid rgba(23, 35, 41, 0.14);
  }

  ol {
    display: grid;
    gap: 12px;
    margin: 0;
    padding: 0;
    list-style: none;
  }

  li {
    display: grid;
    grid-template-columns: 54px minmax(0, 1fr);
    gap: 14px;
    align-items: start;
    border: 2px solid var(--ink);
    border-radius: 8px;
    padding: 15px;
    background: var(--surface);
    box-shadow: 5px 5px 0 rgba(12, 25, 30, 0.18);
  }

  li span {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 44px;
    height: 34px;
    border: 2px solid var(--ink);
    border-radius: 999px;
    background: var(--blue-soft);
    font-family: var(--analog);
    font-size: 0.78rem;
    font-weight: 950;
  }

  li p {
    margin: 3px 0 0;
    color: var(--ink);
    font-size: 1rem;
    font-weight: 750;
  }

  @media (max-width: 860px) {
    .download-hero,
    .install-section {
      grid-template-columns: 1fr;
    }

    h1 {
      font-size: clamp(3rem, 14vw, 4.2rem);
    }
  }

  @media (max-width: 520px) {
    .download-page {
      padding-inline: 14px;
    }

    .download-actions,
    .button {
      width: 100%;
    }

    li {
      grid-template-columns: 46px minmax(0, 1fr);
    }

    li span {
      width: 38px;
    }
  }
</style>
