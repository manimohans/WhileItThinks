<svelte:head>
  <title>Download WhileItThinks</title>
  <meta
    name="description"
    content="Download WhileItThinks, the local-first macOS app where Blink watches Claude Code and Codex wait states."
  />
  <link rel="icon" href="/logo.svg" type="image/svg+xml" />
</svelte:head>

<main class="download-page">
  <a class="brand" href="/" aria-label="Back to WhileItThinks home">
    <img src="/logo.svg" alt="" width="44" height="44" />
    <span>WhileItThinks</span>
  </a>

  <section class="download-panel" aria-labelledby="download-title">
    <p class="eyebrow">Download</p>
    <h1 id="download-title">The Mac app will be available here.</h1>
    <p>
      This page is wired up for the download flow. The actual checkout and app delivery step will
      land here when it is ready.
    </p>
    <div class="pricing-card" aria-label="Early access pricing">
      <span>Lifetime license</span>
      <strong>Installs 1-1,000: free</strong>
      <strong>Installs 1,001-2,000: $0.99</strong>
      <strong>Installs 2,001-3,000: $1.99</strong>
      <strong>Then +$1 every 1,000 installs</strong>
    </div>
    <div class="download-actions">
      <button class="button button-primary" type="button" disabled>Coming soon</button>
      <a class="button button-secondary" href="/#setup">Read setup steps</a>
    </div>
  </section>
</main>

<style>
  .download-page {
    display: grid;
    min-height: 100vh;
    align-content: center;
    gap: clamp(42px, 7vw, 72px);
    padding: clamp(24px, 6vw, 76px);
    background:
      linear-gradient(130deg, transparent 0 58%, rgba(113, 211, 255, 0.18) 58% 71%, transparent 71%),
      linear-gradient(26deg, transparent 0 67%, rgba(255, 106, 87, 0.12) 67% 76%, transparent 76%);
  }

  .brand {
    display: inline-flex;
    align-items: center;
    gap: 12px;
    width: fit-content;
    color: var(--ink);
    font-weight: 950;
  }

  .brand img {
    border: 3px solid var(--line);
    border-radius: 14px;
    box-shadow: 4px 4px 0 var(--shadow);
  }

  .brand span {
    font-size: clamp(1.05rem, 2vw, 1.4rem);
  }

  .download-panel {
    max-width: 860px;
  }

  .eyebrow {
    display: inline-block;
    margin: 0 0 22px;
    border: 3px solid var(--line);
    border-radius: 8px;
    padding: 9px 14px;
    background: var(--blue-soft);
    box-shadow: 5px 5px 0 var(--shadow);
    color: var(--muted);
    font-size: 0.82rem;
    font-weight: 950;
    letter-spacing: 0.18em;
    text-transform: uppercase;
  }

  h1 {
    max-width: 13ch;
    margin: 0;
    font-size: clamp(3rem, 8vw, 6.4rem);
    line-height: 0.96;
    letter-spacing: 0;
  }

  p {
    max-width: 68ch;
    margin: 26px 0 0;
    color: var(--muted);
    font-size: clamp(1rem, 1.7vw, 1.2rem);
    font-weight: 800;
    line-height: 1.8;
  }

  .download-actions {
    display: flex;
    flex-wrap: wrap;
    gap: 16px;
    margin-top: 32px;
  }

  .pricing-card {
    display: grid;
    gap: 10px;
    width: min(100%, 620px);
    margin-top: 28px;
    border: 3px solid var(--line);
    border-radius: 8px;
    padding: 18px;
    background: var(--amber-soft);
    box-shadow: 7px 7px 0 var(--shadow);
  }

  .pricing-card span {
    color: var(--muted);
    font-size: 0.8rem;
    font-weight: 950;
    letter-spacing: 0.16em;
    text-transform: uppercase;
  }

  .pricing-card strong {
    color: var(--ink);
    font-size: clamp(1rem, 1.6vw, 1.18rem);
    font-weight: 950;
  }

  .button {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    min-height: 58px;
    border: 3px solid var(--line);
    border-radius: 8px;
    padding: 0 24px;
    box-shadow: 7px 7px 0 var(--shadow);
    color: var(--ink);
    font: inherit;
    font-weight: 950;
    text-decoration: none;
  }

  .button-primary {
    background: var(--amber);
  }

  .button-secondary {
    background: var(--surface);
  }

  button:disabled {
    cursor: not-allowed;
    opacity: 0.72;
  }

  @media (max-width: 640px) {
    .download-page {
      align-content: start;
      padding-top: 28px;
    }

    .button {
      width: 100%;
    }
  }
</style>
