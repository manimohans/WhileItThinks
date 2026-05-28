<script lang="ts">
  import type { PageData } from './$types';
  import { onMount } from 'svelte';

  const siteUrl = 'https://whileitthinks.com';
  let { data }: { data: PageData } = $props();

  const workflowStates = [
    {
      label: 'Agent working',
      title: 'Step away with confidence',
      detail: 'Claude Code or Codex is still running. Take the break instead of watching the terminal.'
    },
    {
      label: 'Useful pause',
      title: 'Reset your eyes',
      detail: 'WhileItThinks keeps the cue small, local, and timed to a real wait state.'
    },
    {
      label: 'Your turn',
      title: 'Return when input matters',
      detail: 'Come back when the agent needs review, approval, or the next instruction.'
    }
  ];

  const proofPoints = [
    'Built for Claude Code CLI, Claude Desktop Code, Codex CLI, and Codex Desktop',
    'Local receiver, local hook bridge, and sanitized local event storage',
    'No cloud account required for the core wait-state workflow'
  ];

  const benefits = [
    {
      title: 'Fewer wasted checks',
      text: 'WhileItThinks turns long agent waits into an obvious break and return loop.'
    },
    {
      title: 'Better timing than a timer',
      text: 'It reacts to real Claude Code and Codex lifecycle events instead of guessing.'
    },
    {
      title: 'A calmer local surface',
      text: 'The Mac app stays small, visual, and focused on the moment attention becomes useful again.'
    }
  ];

  const setupSteps = [
    'Open WhileItThinks on your Mac.',
    'Start the local receiver from the app.',
    'Enable Claude Code, Codex, or both.',
    'Trust the Codex hooks once in Codex CLI if prompted.',
    'Keep working normally and return when the cue changes.'
  ];

  const faqs = [
    {
      question: 'What is WhileItThinks?',
      answer:
        'WhileItThinks is a local-first macOS app that watches Claude Code and Codex wait states, then gives developers a small visual cue when it is a good moment to step away or return.'
    },
    {
      question: 'Does it support both Claude Code and Codex?',
      answer:
        'Yes. The launch path supports Claude Code CLI, the Claude Desktop Code tab, Codex CLI, and Codex Desktop after the one-time Codex hook trust step.'
    },
    {
      question: 'Does WhileItThinks send my code to a server?',
      answer:
        'No. The core workflow uses a local receiver and stores sanitized local metadata such as event type, duration, source, and safe command summaries.'
    },
    {
      question: 'How much does it cost?',
      answer:
        'The first 1,000 installs are free. After that, the lifetime license launch price steps up by one dollar for every 1,000 installs.'
    }
  ];

  let softwareJsonLd = $derived(
    JSON.stringify({
      '@context': 'https://schema.org',
      '@type': 'SoftwareApplication',
      name: 'WhileItThinks',
      applicationCategory: 'DeveloperApplication',
      operatingSystem: 'macOS 14+',
      url: siteUrl,
      downloadUrl: `${siteUrl}/download/app`,
      description:
        'WhileItThinks is a local-first macOS app that gives developers break and return cues while Claude Code and Codex are busy.',
      offers: {
        '@type': 'Offer',
        priceCurrency: 'USD',
        price: '0',
        availability: data.isLimitReached
          ? 'https://schema.org/SoldOut'
          : 'https://schema.org/InStock',
        description: `Lifetime license with launch pricing: first ${data.installLimit.toLocaleString()} installs are free, then pricing increases by $1 every 1,000 installs.`
      },
      featureList: [
        'Claude Code wait-state cues',
        'Codex wait-state cues',
        'Local macOS receiver',
        'Sanitized local metadata storage'
      ]
    }).replace(/</g, '\\u003c')
  );

  const faqJsonLd = JSON.stringify({
    '@context': 'https://schema.org',
    '@type': 'FAQPage',
    mainEntity: faqs.map((faq) => ({
      '@type': 'Question',
      name: faq.question,
      acceptedAnswer: {
        '@type': 'Answer',
        text: faq.answer
      }
    }))
  }).replace(/</g, '\\u003c');

  let structuredDataHead = $derived(
    '<scr' +
      `ipt type="application/ld+json">${softwareJsonLd}</scr` +
      'ipt><scr' +
      `ipt type="application/ld+json">${faqJsonLd}</scr` +
      'ipt>'
  );

  let activeState = $state(0);

  onMount(() => {
    const interval = window.setInterval(() => {
      activeState = (activeState + 1) % workflowStates.length;
    }, 3600);

    return () => {
      window.clearInterval(interval);
    };
  });
</script>

<svelte:head>
  <title>WhileItThinks | Break cues for Claude Code and Codex</title>
  <meta
    name="description"
    content="WhileItThinks is a local-first macOS app that tells developers when Claude Code or Codex is busy, when to take a break, and when to return."
  />
  <meta
    name="keywords"
    content="WhileItThinks, Claude Code, Codex, macOS developer tool, AI coding agent, local-first app, coding workflow"
  />
  <meta name="robots" content="index,follow,max-image-preview:large,max-snippet:-1,max-video-preview:-1" />
  <link rel="canonical" href={siteUrl} />
  <link rel="icon" href="/logo.svg" type="image/svg+xml" />
  <meta property="og:type" content="website" />
  <meta property="og:url" content={siteUrl} />
  <meta property="og:title" content="WhileItThinks | Break cues for Claude Code and Codex" />
  <meta
    property="og:description"
    content="A local-first macOS app that gives developers calm break and return cues while Claude Code and Codex are busy."
  />
  <meta property="og:image" content={`${siteUrl}/og.png`} />
  <meta name="twitter:card" content="summary_large_image" />
  <meta name="twitter:title" content="WhileItThinks | Break cues for Claude Code and Codex" />
  <meta
    name="twitter:description"
    content="Stop watching agent spinners. WhileItThinks gives local break and return cues for Claude Code and Codex."
  />
  <meta name="twitter:image" content={`${siteUrl}/og.png`} />
  {@html structuredDataHead}
</svelte:head>

<header class="site-header" aria-label="Primary navigation">
  <a class="brand" href="#top" aria-label="WhileItThinks home">
    <img src="/logo.svg" alt="" width="42" height="42" />
    <span>WhileItThinks</span>
  </a>
  <nav class="nav-links" aria-label="Landing page sections">
    <a href="#benefits">Why it works</a>
    <a href="#workflow">Workflow</a>
    <a href="#privacy">Privacy</a>
    <a href="#faq">FAQ</a>
  </nav>
  <a class="nav-cta" href="/download">Download</a>
</header>

<main id="top">
  <section class="hero" aria-labelledby="hero-title">
    <div class="hero-copy">
      <p class="eyebrow">macOS app for agentic coding</p>
      <h1 id="hero-title">WhileItThinks for Claude Code and Codex.</h1>
      <p class="hero-lede">
        Stop watching agent spinners. WhileItThinks notices real wait states, gives you a quiet break
        cue, and calls you back when your attention is useful again.
      </p>

      <div class="hero-actions" aria-label="Primary actions">
        <a class="button button-primary" href="/download">
          {data.isLimitReached ? 'View download status' : 'Download free launch build'}
        </a>
        <a class="button button-secondary" href="#workflow">See how it works</a>
      </div>

      <p class="install-count">
        <span>{data.installCount.toLocaleString()}</span>
        launch installs claimed
      </p>

      <ul class="proof-list" aria-label="Product proof points">
        {#each proofPoints as point}
          <li>{point}</li>
        {/each}
      </ul>
    </div>

    <div class="product-demo" aria-label="WhileItThinks workflow preview">
      <div class="demo-toolbar">
        <span></span>
        <span></span>
        <span></span>
        <strong>WhileItThinks</strong>
      </div>
      <div class="demo-grid">
        <div class="terminal-pane" aria-label="Agent terminal status">
          <p class="terminal-command"><span>$</span> codex "make onboarding clearer"</p>
          <p class="terminal-muted">running checks...</p>
          <p class="terminal-output">agent is working</p>
        </div>
        <div class="cue-pane" aria-live="polite">
          <img src="/logo.svg" alt="" width="64" height="64" />
          <span>{workflowStates[activeState].label}</span>
          <strong>{workflowStates[activeState].title}</strong>
          <p>{workflowStates[activeState].detail}</p>
        </div>
      </div>
      <div class="demo-footer" aria-hidden="true">
        <span>ask sent</span>
        <span>local receiver</span>
        <span>break cue</span>
        <span>your turn</span>
      </div>
    </div>
  </section>

  <section class="benefits-section" id="benefits" aria-labelledby="benefits-title">
    <div class="section-heading">
      <p class="eyebrow eyebrow-muted">Why it works</p>
      <h2 id="benefits-title">The agent keeps working. You get a cleaner wait.</h2>
      <p>
        WhileItThinks is for the specific moment when an AI coding agent is busy enough that watching
        it wastes focus, but close enough that you still need to come back.
      </p>
    </div>

    <div class="benefit-grid">
      {#each benefits as benefit}
        <article class="benefit-card">
          <h3>{benefit.title}</h3>
          <p>{benefit.text}</p>
        </article>
      {/each}
    </div>
  </section>

  <section class="workflow-section" id="workflow" aria-labelledby="workflow-title">
    <div class="workflow-copy">
      <p class="eyebrow">Workflow</p>
      <h2 id="workflow-title">Ask, step away, return on signal.</h2>
      <p>
        No second dashboard to monitor. The Mac app sits beside Claude Code and Codex, watches the
        local events those tools already emit, and keeps the cue small.
      </p>
    </div>

    <ol class="timeline" aria-label="WhileItThinks workflow">
      {#each setupSteps as step, index}
        <li>
          <span>{String(index + 1).padStart(2, '0')}</span>
          <p>{step}</p>
        </li>
      {/each}
    </ol>
  </section>

  <section class="privacy-section" id="privacy" aria-labelledby="privacy-title">
    <div class="privacy-copy">
      <p class="eyebrow eyebrow-muted">Privacy defaults</p>
      <h2 id="privacy-title">Local-first because developer work should stay local.</h2>
      <p>
        WhileItThinks uses a local receiver, local hooks, and sanitized metadata. It is built around
        attention cues, not a cloud feed of your coding sessions.
      </p>
    </div>

    <div class="privacy-grid" aria-label="Privacy summary">
      <article>
        <h3>Local receiver</h3>
        <p>Runs on your Mac and listens to local Claude Code and Codex events.</p>
      </article>
      <article>
        <h3>Sanitized metadata</h3>
        <p>Stores timing, source, event kind, and safe summaries instead of raw project content.</p>
      </article>
      <article>
        <h3>Small surface</h3>
        <p>Focused on break and return cues, not replacing the tools where you already work.</p>
      </article>
    </div>
  </section>

  <section class="pricing-section" aria-labelledby="pricing-title">
    <div>
      <p class="eyebrow">Launch pricing</p>
      <h2 id="pricing-title">Start free. Keep the license for life.</h2>
      <p>
        {#if data.isLimitReached}
          <strong>All {data.installLimit.toLocaleString()} free installs are claimed.</strong>
          Downloads are paused until paid checkout is ready.
        {:else}
          <strong>
            {data.installCount.toLocaleString()} of {data.installLimit.toLocaleString()} free
            installs claimed.
          </strong>
          After that, downloads pause until paid checkout is ready.
        {/if}
      </p>
    </div>
    <a class="button button-primary" href="/download">
      {data.isLimitReached ? 'View download status' : 'Get the Mac app'}
    </a>
  </section>

  <section class="faq-section" id="faq" aria-labelledby="faq-title">
    <div class="section-heading">
      <p class="eyebrow eyebrow-muted">FAQ</p>
      <h2 id="faq-title">Answers for developers comparing AI coding workflow tools.</h2>
    </div>
    <div class="faq-list">
      {#each faqs as faq}
        <article>
          <h3>{faq.question}</h3>
          <p>{faq.answer}</p>
        </article>
      {/each}
    </div>
  </section>
</main>

<footer class="site-footer">
  <span>WhileItThinks</span>
  <nav aria-label="Footer navigation">
    <a href="/download">Download</a>
    <a href="#privacy">Privacy</a>
    <a href="#top">Back to top</a>
  </nav>
</footer>

<style>
  :global(html) {
    scroll-behavior: smooth;
  }

  :global(body) {
    background:
      linear-gradient(116deg, rgba(196, 232, 255, 0.45) 0 20%, transparent 20% 100%),
      linear-gradient(20deg, transparent 0 67%, rgba(255, 218, 182, 0.5) 67% 100%),
      var(--page);
    color: var(--ink);
  }

  .site-header {
    position: sticky;
    top: 0;
    z-index: 20;
    display: grid;
    grid-template-columns: 1fr auto 1fr;
    align-items: center;
    gap: 24px;
    min-height: 72px;
    padding: 12px clamp(18px, 5vw, 84px);
    border-bottom: 1px solid rgba(23, 35, 41, 0.12);
    background: rgba(249, 250, 247, 0.9);
    backdrop-filter: blur(18px);
  }

  .brand,
  .nav-links,
  .site-footer nav {
    display: inline-flex;
    align-items: center;
  }

  .brand {
    gap: 12px;
    width: fit-content;
    color: var(--ink);
    font-family: var(--analog);
    font-size: clamp(1rem, 1.8vw, 1.35rem);
    font-weight: 950;
    letter-spacing: 0;
  }

  .brand img {
    width: 42px;
    height: 42px;
    border: 2px solid var(--ink);
    border-radius: 8px;
    background: var(--surface);
    box-shadow: 3px 3px 0 var(--shadow);
  }

  .nav-links {
    justify-content: center;
    gap: clamp(18px, 3vw, 34px);
    color: var(--muted);
    font-size: 0.95rem;
    font-weight: 750;
  }

  .nav-links a,
  .site-footer a {
    border-bottom: 2px solid transparent;
    padding-block: 5px;
  }

  .nav-links a:hover,
  .site-footer a:hover {
    color: var(--ink);
    border-color: var(--coral);
  }

  .nav-cta,
  .button {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    min-height: 48px;
    border: 2px solid var(--ink);
    border-radius: 8px;
    padding: 0 20px;
    color: var(--ink);
    font-weight: 850;
    line-height: 1;
    text-align: center;
    box-shadow: 5px 5px 0 var(--shadow);
    transition:
      transform 160ms ease,
      box-shadow 160ms ease;
  }

  .nav-cta,
  .button-primary {
    background: var(--amber);
  }

  .button-secondary {
    background: var(--surface);
  }

  .nav-cta {
    justify-self: end;
  }

  .nav-cta:hover,
  .button:hover {
    transform: translate(2px, 2px);
    box-shadow: 3px 3px 0 var(--shadow);
  }

  .hero {
    display: grid;
    grid-template-columns: minmax(0, 0.94fr) minmax(390px, 1.06fr);
    gap: clamp(34px, 5vw, 78px);
    align-items: center;
    width: min(100%, 1440px);
    min-height: min(720px, calc(100svh - 128px));
    margin: 0 auto;
    padding: clamp(34px, 5vw, 62px) clamp(18px, 7vw, 92px);
  }

  .hero-copy {
    max-width: 680px;
  }

  .eyebrow {
    display: inline-flex;
    align-items: center;
    width: fit-content;
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
  h3,
  p {
    margin-top: 0;
  }

  h1,
  h2,
  h3 {
    color: var(--ink);
    letter-spacing: 0;
    text-wrap: balance;
    overflow-wrap: normal;
  }

  h1 {
    max-width: 15ch;
    margin-bottom: 22px;
    font-size: clamp(3.4rem, 6.35vw, 6rem);
    line-height: 0.92;
  }

  h2 {
    margin-bottom: 18px;
    font-size: clamp(2.35rem, 5vw, 5rem);
    line-height: 0.98;
  }

  h3 {
    margin-bottom: 12px;
    font-size: clamp(1.25rem, 2vw, 1.65rem);
    line-height: 1.08;
  }

  p {
    color: var(--muted);
    font-size: 1.03rem;
    line-height: 1.65;
  }

  .hero-lede {
    max-width: 650px;
    margin-bottom: 26px;
    font-size: clamp(1.13rem, 2vw, 1.42rem);
    line-height: 1.5;
  }

  .hero-actions {
    display: flex;
    flex-wrap: wrap;
    gap: 14px;
    margin-bottom: 24px;
  }

  .proof-list {
    display: grid;
    gap: 10px;
    margin: 0;
    padding: 0;
    list-style: none;
  }

  .install-count {
    display: inline-flex;
    align-items: center;
    gap: 10px;
    margin: 0 0 22px;
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

  .proof-list li {
    position: relative;
    padding-left: 22px;
    color: var(--muted);
    font-size: 0.98rem;
    font-weight: 700;
    line-height: 1.45;
  }

  .proof-list li::before {
    content: "";
    position: absolute;
    top: 0.55em;
    left: 0;
    width: 9px;
    height: 9px;
    border-radius: 999px;
    background: var(--coral);
    box-shadow: 0 0 0 4px rgba(255, 109, 92, 0.16);
  }

  .product-demo {
    position: relative;
    min-width: 0;
    border: 2px solid var(--ink);
    border-radius: 8px;
    overflow: hidden;
    background: var(--surface);
    box-shadow: 14px 14px 0 var(--shadow);
  }

  .product-demo::before {
    content: "";
    position: absolute;
    inset: 54px 0 auto;
    height: 45%;
    background:
      linear-gradient(120deg, transparent 0 18%, rgba(134, 204, 234, 0.36) 18% 44%, transparent 44%),
      var(--blue-soft);
    z-index: 0;
  }

  .demo-toolbar {
    position: relative;
    z-index: 1;
    display: flex;
    align-items: center;
    gap: 8px;
    min-height: 52px;
    border-bottom: 2px solid var(--ink);
    padding: 0 16px;
    background: var(--surface);
  }

  .demo-toolbar span {
    width: 12px;
    height: 12px;
    border: 2px solid var(--ink);
    border-radius: 999px;
  }

  .demo-toolbar span:nth-child(1) {
    background: var(--coral);
  }

  .demo-toolbar span:nth-child(2) {
    background: var(--amber);
  }

  .demo-toolbar span:nth-child(3) {
    background: var(--blue);
  }

  .demo-toolbar strong {
    margin-left: auto;
    color: var(--muted);
    font-family: var(--analog);
    font-size: 0.78rem;
    font-weight: 950;
    letter-spacing: 0.1em;
    text-transform: uppercase;
  }

  .demo-grid {
    position: relative;
    z-index: 1;
    display: grid;
    grid-template-columns: minmax(0, 0.95fr) minmax(240px, 0.78fr);
    gap: 18px;
    padding: clamp(18px, 3vw, 30px);
  }

  .terminal-pane,
  .cue-pane {
    border: 2px solid var(--ink);
    border-radius: 8px;
    box-shadow: 6px 6px 0 rgba(12, 25, 30, 0.24);
  }

  .terminal-pane {
    min-height: 310px;
    padding: 24px;
    background: #101f1d;
    color: var(--surface);
    font-family: var(--analog);
  }

  .terminal-command,
  .terminal-muted,
  .terminal-output {
    font-family: var(--analog);
    line-height: 1.45;
  }

  .terminal-command {
    margin-bottom: 36px;
    color: var(--amber);
    font-size: clamp(0.98rem, 1.5vw, 1.18rem);
  }

  .terminal-command span {
    color: var(--blue);
  }

  .terminal-muted {
    margin-bottom: 10px;
    color: rgba(255, 254, 250, 0.68);
  }

  .terminal-output {
    color: var(--surface);
    font-size: clamp(1.55rem, 3vw, 2.45rem);
  }

  .cue-pane {
    align-self: end;
    display: grid;
    gap: 9px;
    padding: 18px;
    background: var(--surface);
  }

  .cue-pane img {
    width: 64px;
    height: 64px;
    border: 2px solid var(--ink);
    border-radius: 8px;
    background: var(--blue-soft);
  }

  .cue-pane span {
    color: var(--coral);
    font-family: var(--analog);
    font-size: 0.74rem;
    font-weight: 950;
    letter-spacing: 0.1em;
    text-transform: uppercase;
  }

  .cue-pane strong {
    color: var(--ink);
    font-size: clamp(1.35rem, 2vw, 1.72rem);
    line-height: 1.05;
  }

  .cue-pane p {
    margin-bottom: 0;
  }

  .demo-footer {
    position: relative;
    z-index: 1;
    display: flex;
    flex-wrap: wrap;
    gap: 10px;
    padding: 0 clamp(18px, 3vw, 30px) clamp(18px, 3vw, 30px);
  }

  .demo-footer span {
    border: 1px solid var(--ink);
    border-radius: 999px;
    padding: 7px 10px;
    background: var(--amber-soft);
    color: var(--ink);
    font-family: var(--analog);
    font-size: 0.72rem;
    font-weight: 950;
    text-transform: uppercase;
  }

  .benefits-section,
  .workflow-section,
  .privacy-section,
  .faq-section {
    width: min(100%, 1280px);
    margin: 0 auto;
    padding: clamp(64px, 8vw, 110px) clamp(18px, 5vw, 56px);
    scroll-margin-top: 84px;
  }

  .benefits-section {
    padding-top: clamp(42px, 5vw, 60px);
  }

  .section-heading {
    max-width: 930px;
  }

  .section-heading > p:last-child,
  .workflow-copy p,
  .privacy-copy p,
  .pricing-section p {
    max-width: 720px;
    font-size: clamp(1.04rem, 1.5vw, 1.18rem);
  }

  .pricing-section strong {
    color: var(--ink);
  }

  .benefit-grid {
    display: grid;
    grid-template-columns: repeat(3, minmax(0, 1fr));
    gap: 16px;
    margin-top: 34px;
  }

  .benefit-card,
  .privacy-grid article,
  .faq-list article {
    border: 2px solid var(--ink);
    border-radius: 8px;
    padding: clamp(20px, 3vw, 26px);
    background: var(--surface);
    box-shadow: 7px 7px 0 var(--shadow);
  }

  .benefit-card:nth-child(1) {
    background: var(--blue-soft);
  }

  .benefit-card:nth-child(2) {
    background: var(--amber-soft);
  }

  .benefit-card:nth-child(3) {
    background: var(--coral-soft);
  }

  .benefit-card p,
  .privacy-grid p,
  .faq-list p {
    margin-bottom: 0;
  }

  .workflow-section {
    display: grid;
    grid-template-columns: minmax(0, 0.85fr) minmax(360px, 0.9fr);
    gap: clamp(34px, 6vw, 80px);
    align-items: start;
    max-width: none;
    width: 100%;
    background:
      linear-gradient(105deg, rgba(196, 232, 255, 0.65), transparent 38%),
      var(--surface);
    border-block: 1px solid rgba(23, 35, 41, 0.12);
  }

  .workflow-copy {
    justify-self: end;
    width: min(100%, 560px);
  }

  .timeline {
    display: grid;
    gap: 14px;
    width: min(100%, 680px);
    margin: 0;
    padding: 0;
    list-style: none;
  }

  .timeline li {
    display: grid;
    grid-template-columns: 58px minmax(0, 1fr);
    gap: 14px;
    align-items: start;
    border: 2px solid var(--ink);
    border-radius: 8px;
    padding: 16px;
    background: var(--surface);
    box-shadow: 5px 5px 0 rgba(12, 25, 30, 0.18);
  }

  .timeline span {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 46px;
    height: 36px;
    border: 2px solid var(--ink);
    border-radius: 999px;
    background: var(--blue-soft);
    font-family: var(--analog);
    font-size: 0.78rem;
    font-weight: 950;
  }

  .timeline p {
    margin: 4px 0 0;
    color: var(--ink);
    font-weight: 750;
  }

  .privacy-section {
    display: grid;
    grid-template-columns: minmax(0, 0.95fr) minmax(320px, 0.75fr);
    gap: clamp(34px, 6vw, 80px);
    align-items: center;
  }

  .privacy-copy {
    max-width: 780px;
  }

  .privacy-grid {
    display: grid;
    gap: 12px;
  }

  .privacy-grid article:nth-child(2) {
    background: var(--blue-soft);
  }

  .privacy-grid article:nth-child(3) {
    background: var(--coral-soft);
  }

  .pricing-section {
    display: grid;
    grid-template-columns: minmax(0, 1fr) auto;
    gap: 28px;
    align-items: center;
    width: min(100% - 36px, 1180px);
    margin: clamp(26px, 5vw, 52px) auto;
    border: 2px solid var(--ink);
    border-radius: 8px;
    padding: clamp(24px, 4vw, 38px);
    background: var(--amber-soft);
    box-shadow: 9px 9px 0 var(--shadow);
  }

  .pricing-section h2 {
    font-size: clamp(2rem, 4vw, 3.8rem);
  }

  .faq-list {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 16px;
    margin-top: 34px;
  }

  .site-footer {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 18px;
    padding: 30px clamp(18px, 5vw, 84px);
    color: var(--muted);
  }

  .site-footer span {
    color: var(--ink);
    font-family: var(--analog);
    font-size: 1.15rem;
    font-weight: 950;
  }

  .site-footer nav {
    gap: 20px;
    font-weight: 750;
  }

  @media (prefers-reduced-motion: reduce) {
    :global(html) {
      scroll-behavior: auto;
    }

    .nav-cta,
    .button {
      transition: none;
    }
  }

  @media (max-width: 1060px) {
    .site-header {
      grid-template-columns: 1fr auto;
    }

    .nav-links {
      display: none;
    }

    .hero,
    .workflow-section,
    .privacy-section,
    .pricing-section {
      grid-template-columns: 1fr;
    }

    .hero {
      min-height: auto;
    }

    .workflow-copy {
      justify-self: auto;
      width: 100%;
    }

    .pricing-section {
      align-items: start;
    }

    .pricing-section .button {
      width: fit-content;
    }
  }

  @media (max-width: 760px) {
    .site-header {
      min-height: 64px;
      gap: 12px;
      padding-inline: 14px;
    }

    .brand {
      gap: 9px;
      font-size: 0.95rem;
    }

    .brand img {
      width: 34px;
      height: 34px;
    }

    .nav-cta {
      min-height: 42px;
      padding: 0 14px;
      font-size: 0.9rem;
      box-shadow: 4px 4px 0 var(--shadow);
    }

    .hero {
      padding: 40px 14px 58px;
    }

    h1 {
      max-width: 11ch;
      font-size: clamp(3rem, 14vw, 4.1rem);
      line-height: 0.95;
    }

    h2 {
      font-size: clamp(2.15rem, 10vw, 3.35rem);
    }

    .hero-actions,
    .button,
    .pricing-section .button {
      width: 100%;
    }

    .proof-list {
      display: none;
    }

    .demo-grid {
      grid-template-columns: 1fr;
    }

    .terminal-pane {
      min-height: 220px;
    }

    .benefit-grid,
    .faq-list {
      grid-template-columns: 1fr;
    }

    .timeline li {
      grid-template-columns: 48px minmax(0, 1fr);
      padding: 14px;
    }

    .timeline span {
      width: 40px;
    }

    .site-footer {
      align-items: flex-start;
      flex-direction: column;
    }

    .site-footer nav {
      flex-wrap: wrap;
    }
  }

  @media (max-width: 430px) {
    .product-demo {
      box-shadow: 8px 8px 0 var(--shadow);
    }

    .demo-toolbar strong {
      max-width: 150px;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }

    .demo-footer span {
      font-size: 0.66rem;
    }
  }
</style>
