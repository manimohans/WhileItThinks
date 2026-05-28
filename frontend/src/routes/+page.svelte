<script lang="ts">
  import { onMount } from 'svelte';
  import { spring } from 'svelte/motion';

  const signalStates = [
    {
      label: 'Busy',
      status: 'agent is working',
      cue: 'Look away for 20 seconds'
    },
    {
      label: 'Break',
      status: 'good moment to blink',
      cue: 'Stretch your wrists'
    },
    {
      label: 'Your turn',
      status: 'needs you again',
      cue: 'Return to keyboard'
    }
  ];

  const workflowStatuses = ['agent thinking', 'still working'];

  let activeSignal = 0;
  let activeWorkflowStatus = 0;

  const tilt = spring(
    { rotateX: 0, rotateY: 0 },
    {
      stiffness: 0.08,
      damping: 0.42
    }
  );

  onMount(() => {
    const signalInterval = window.setInterval(() => {
      activeSignal = (activeSignal + 1) % signalStates.length;
    }, 2600);

    const workflowInterval = window.setInterval(() => {
      activeWorkflowStatus = (activeWorkflowStatus + 1) % workflowStatuses.length;
    }, 3200);

    return () => {
      window.clearInterval(signalInterval);
      window.clearInterval(workflowInterval);
    };
  });

  function handleTilt(event: PointerEvent) {
    const target = event.currentTarget;
    if (!(target instanceof HTMLElement)) return;

    const rect = target.getBoundingClientRect();
    const x = (event.clientX - rect.left) / rect.width - 0.5;
    const y = (event.clientY - rect.top) / rect.height - 0.5;

    tilt.set({
      rotateX: y * -5,
      rotateY: x * 7
    });
  }

  function resetTilt() {
    tilt.set({ rotateX: 0, rotateY: 0 });
  }
</script>

<svelte:head>
  <title>WhileItThinks | A tiny break buddy for Claude Code and Codex</title>
  <meta
    name="description"
    content="WhileItThinks is a local-first macOS app that gives developers tiny break and return cues while Claude Code and Codex are busy."
  />
  <link rel="icon" href="/logo.svg" type="image/svg+xml" />
</svelte:head>

<header class="site-header" aria-label="Primary navigation">
  <a class="brand" href="#top" aria-label="WhileItThinks home">
    <img src="/logo.svg" alt="" width="44" height="44" />
    <span>WhileItThinks</span>
  </a>
  <nav class="nav-links" aria-label="Landing page sections">
    <a href="#how">How it works</a>
    <a href="#signals">Workflow</a>
    <a href="#setup">Setup</a>
    <a href="#privacy">Privacy</a>
  </nav>
  <a class="nav-cta" href="/download">Download</a>
</header>

<main id="top">
  <section class="hero" aria-labelledby="hero-title">
    <div class="hero-copy">
      <p class="eyebrow">For agentic coding</p>
      <h1 id="hero-title">Stop babysitting spinners.</h1>
      <p class="hero-lede">
        WhileItThinks sits beside Claude Code and Codex, notices when the agent is busy or waiting
        for you, then calls you back when attention is useful again.
      </p>
      <div class="hero-actions" aria-label="Primary actions">
        <a class="button button-primary" href="/download">Download</a>
        <a class="button button-secondary" href="#signals">Watch the workflow</a>
      </div>
      <p class="tool-line">
        Made for <strong>Claude Code</strong> and <strong>Codex</strong>. Local on your Mac, quiet
        about your work, clear when you should come back.
      </p>
      <p class="pricing-note">
        Lifetime license: free for the first 100 users, $0.99 for users 101-1,000,
        then $4.99.
      </p>
    </div>

    <div
      class="motion-stage"
      role="group"
      aria-label="Animated WhileItThinks raccoon supervising agent work"
      onpointermove={handleTilt}
      onpointerleave={resetTilt}
    >
      <div
        class="stage-card"
        style={`transform: rotateX(${$tilt.rotateX}deg) rotateY(${$tilt.rotateY}deg);`}
      >
        <div class="signal-tape" aria-hidden="true">
          <span>ask sent</span>
          <span>agent busy</span>
          <span>blink break</span>
          <span>your turn</span>
        </div>

        <svg class="sleep-raccoon" viewBox="0 0 430 360" role="img" aria-labelledby="raccoon-title raccoon-desc">
          <title id="raccoon-title">A sleepy WhileItThinks raccoon</title>
          <desc id="raccoon-desc">The WhileItThinks raccoon blinks and stretches while Claude Code and Codex run in the background.</desc>

          <path class="angle-band band-blue" d="M16 62H332L292 128H16Z" />
          <path class="angle-band band-coral" d="M292 128H414L374 198H252Z" />
          <path class="angle-band band-amber" d="M48 240H290L260 300H18Z" />

          <g class="zzz zzz-one"><text x="305" y="78">z</text></g>
          <g class="zzz zzz-two"><text x="346" y="54">Z</text></g>
          <g class="zzz zzz-three"><text x="374" y="92">z</text></g>

          <ellipse class="desk-shadow" cx="218" cy="305" rx="150" ry="24" />
          <rect class="monitor" x="48" y="190" width="334" height="94" rx="13" />
          <path class="monitor-line line-a" d="M88 223H185" />
          <path class="monitor-line line-b" d="M88 251H152" />
          <path class="monitor-line line-c" d="M244 237H338" />

          <g class="tail">
            <path d="M103 235C52 228 36 166 79 132C122 98 166 135 147 174C136 199 116 212 103 235Z" />
            <path d="M64 164C85 166 106 179 123 200" />
            <path d="M84 136C113 141 136 157 150 181" />
          </g>

          <g class="raccoon-body">
            <path class="ear outer-left" d="M145 122L104 69L115 157Z" />
            <path class="ear outer-right" d="M281 122L322 69L311 157Z" />
            <path class="ear inner-left" d="M146 125L118 89L126 148Z" />
            <path class="ear inner-right" d="M280 125L308 89L300 148Z" />
            <ellipse class="head" cx="214" cy="183" rx="109" ry="93" />
            <path class="mask" d="M107 167C128 127 177 121 214 156C251 121 300 127 321 167C299 214 253 219 214 186C175 219 129 214 107 167Z" />
            <ellipse class="muzzle" cx="214" cy="222" rx="57" ry="36" />
            <circle class="eye-base" cx="174" cy="167" r="15" />
            <circle class="eye-base" cx="254" cy="167" r="15" />
            <path class="sleep-eye" d="M158 168C167 177 181 177 190 168" />
            <path class="sleep-eye" d="M238 168C247 177 261 177 270 168" />
            <ellipse class="nose" cx="214" cy="206" rx="19" ry="12" />
            <path class="mouth" d="M202 228C209 234 219 234 226 228" />
            <path class="whisker whisker-coral" d="M174 223L102 235" />
            <path class="whisker" d="M175 238L110 257" />
            <path class="whisker whisker-gold" d="M254 223L326 235" />
            <path class="whisker" d="M253 238L318 257" />
          </g>

          <g class="paw paw-left">
            <path d="M141 259C162 244 189 257 188 280C187 303 148 307 132 287C125 278 130 267 141 259Z" />
            <path d="M156 271L149 283" />
            <path d="M170 271L168 285" />
          </g>
          <g class="paw paw-right">
            <path d="M287 259C266 244 239 257 240 280C241 303 280 307 296 287C303 278 298 267 287 259Z" />
            <path d="M272 271L279 283" />
            <path d="M258 271L260 285" />
          </g>
        </svg>

        <div class="live-card" aria-live="polite">
          <span>{signalStates[activeSignal].label}</span>
          <strong>{signalStates[activeSignal].status}</strong>
          <p>{signalStates[activeSignal].cue}</p>
        </div>
      </div>
    </div>
  </section>

  <section class="how-section" id="how" aria-labelledby="how-title">
    <div class="section-heading">
      <p class="eyebrow eyebrow-coral">What changes</p>
      <h2 id="how-title">The agent keeps working. You get a cleaner wait.</h2>
    </div>
    <div class="flow-grid">
      <article class="flow-card flow-blue">
        <span>01</span>
        <h3>Ask the agent</h3>
        <p>Start work in Claude Code or Codex as usual.</p>
      </article>
      <article class="flow-card flow-amber">
        <span>02</span>
        <h3>The cue appears</h3>
        <p>When there is a real wait, it gives you a tiny cue instead of making you stare.</p>
      </article>
      <article class="flow-card flow-coral">
        <span>03</span>
        <h3>You get called back</h3>
        <p>When attention helps again, you return without camping on the terminal.</p>
      </article>
    </div>
  </section>

  <section class="signals-section" id="signals" aria-labelledby="signals-title">
    <div class="signals-copy">
      <p class="eyebrow">Workflow sketch</p>
      <h2 id="signals-title">Ask, step away, come back.</h2>
      <p>
        No extra dashboard to watch. Just a small local companion that turns agent waits into a
        cleaner loop.
      </p>
    </div>
    <div class="workflow-stage" aria-label="Coding workflow example">
      <div class="workflow-window terminal-window">
        <div class="window-bar">
          <span></span><span></span><span></span>
          <strong>Claude Code / Codex</strong>
        </div>
        <div class="terminal-body">
          <p class="typed-line"><span>$</span> make the settings screen clearer</p>
          <div class="terminal-status" aria-live="polite" aria-label="Agent status">
            {#key activeWorkflowStatus}
              <p>{workflowStatuses[activeWorkflowStatus]}<span aria-hidden="true">...</span></p>
            {/key}
          </div>
        </div>
      </div>

      <div class="workflow-window companion-window">
        <div class="notification-raccoon" aria-hidden="true">
          <img src="/logo.svg" alt="" width="52" height="52" />
        </div>
        <div class="notification-copy">
          <span>WhileItThinks</span>
          <strong>Blink. Shoulders down.</strong>
          <p>Claude Code / Codex is still busy.</p>
        </div>
        <div class="notification-state" aria-hidden="true">
          <span></span>
          <span></span>
          <span></span>
        </div>
      </div>
    </div>
  </section>

  <section class="privacy-section" id="privacy" aria-labelledby="privacy-title">
    <div class="privacy-card">
      <p class="eyebrow eyebrow-coral">Privacy defaults</p>
      <h2 id="privacy-title">Local-first because your work is your work.</h2>
      <p>
        WhileItThinks is designed around simple local cues. It does not need to turn your coding
        session into a content feed.
      </p>
    </div>
    <div class="privacy-list" aria-label="Privacy summary">
      <div>
        <strong>Local</strong>
        <span>Runs on your Mac, beside the tools you already use.</span>
      </div>
      <div>
        <strong>Quiet</strong>
        <span>Keeps the product surface focused on break and return cues.</span>
      </div>
      <div>
        <strong>Small</strong>
        <span>Built for a tiny workflow moment, not another dashboard habit.</span>
      </div>
    </div>
  </section>

  <section class="setup-section" id="setup" aria-labelledby="setup-title">
    <div class="setup-intro">
      <p class="eyebrow">Setup</p>
      <h2 id="setup-title">Simple setup for Claude Code and Codex.</h2>
      <p>
        Open the Mac app, start the local helper, enable Claude Code or Codex, then approve Codex
        once in Codex CLI if prompted.
      </p>
    </div>
    <div class="setup-guides" aria-label="Tool setup instructions">
      <article class="tool-guide guide-claude">
        <div class="guide-heading">
          <span>Claude Code</span>
          <strong>Fast path</strong>
        </div>
        <ol class="step-list">
          <li><span>1</span><p>Open WhileItThinks on your Mac.</p></li>
          <li><span>2</span><p>Start the local helper from the app.</p></li>
          <li><span>3</span><p>Choose <strong>Claude Code</strong>.</p></li>
          <li><span>4</span><p>Open Claude Code CLI or the desktop Code tab.</p></li>
          <li><span>5</span><p>Take the break cue. Come back when it says your turn.</p></li>
        </ol>
        <p class="guide-note">Enable it once, then keep working normally.</p>
      </article>

      <article class="tool-guide guide-codex">
        <div class="guide-heading">
          <span>Codex</span>
          <strong>One-time trust</strong>
        </div>
        <ol class="step-list">
          <li><span>1</span><p>Open WhileItThinks on your Mac.</p></li>
          <li><span>2</span><p>Start the local helper from the app.</p></li>
          <li><span>3</span><p>Choose <strong>Codex</strong>.</p></li>
          <li><span>4</span><p>Approve WhileItThinks once in Codex CLI if prompted.</p></li>
          <li><span>5</span><p>Use Codex CLI or Codex Desktop like normal.</p></li>
          <li><span>6</span><p>Take the break cue. Come back when it says your turn.</p></li>
        </ol>
        <p class="guide-note">Codex Desktop works after the one-time CLI approval.</p>
      </article>
    </div>
  </section>
</main>

<footer class="site-footer">
  <span>WhileItThinks</span>
  <a href="#top">Back to top</a>
</footer>

<style>
  .site-header {
    position: sticky;
    top: 0;
    z-index: 20;
    display: grid;
    grid-template-columns: 1fr auto 1fr;
    align-items: center;
    gap: 24px;
    min-height: 72px;
    padding: 12px clamp(18px, 5vw, 96px);
    border-bottom: 2px solid rgba(22, 35, 31, 0.12);
    background: rgba(247, 251, 255, 0.9);
    backdrop-filter: blur(16px);
  }

  .brand {
    display: inline-flex;
    align-items: center;
    gap: 12px;
    min-width: 0;
    font-family: var(--analog);
    font-size: clamp(1.25rem, 2vw, 1.8rem);
    font-weight: 900;
    line-height: 1;
  }

  .brand img {
    width: 44px;
    height: 44px;
    border: 2px solid var(--page);
    border-radius: 14px;
    box-shadow: 0 2px 0 var(--line);
  }

  .nav-links {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: clamp(18px, 3vw, 36px);
    color: var(--muted);
    font-family: var(--analog);
    font-weight: 850;
  }

  .nav-links a {
    border-bottom: 2px solid transparent;
    padding-block: 4px;
  }

  .nav-links a:hover {
    color: var(--ink);
    border-color: var(--coral);
  }

  .nav-cta,
  .button {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    min-height: 50px;
    border: 3px solid var(--line);
    border-radius: 7px;
    padding: 0 22px;
    font-family: var(--analog);
    font-weight: 950;
    line-height: 1;
    box-shadow: 7px 7px 0 var(--shadow);
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

  .button:hover,
  .nav-cta:hover {
    transform: translate(3px, 3px);
    box-shadow: 4px 4px 0 var(--shadow);
  }

  .hero {
    position: relative;
    display: grid;
    grid-template-columns: minmax(0, 0.95fr) minmax(390px, 1.05fr);
    gap: clamp(32px, 5vw, 76px);
    align-items: center;
    min-height: calc(100vh - 92px);
    padding: clamp(26px, 4vw, 60px) clamp(18px, 8vw, 112px) clamp(40px, 6vw, 76px);
    overflow: hidden;
  }

  .hero::before {
    content: "";
    position: absolute;
    inset: 8% -12% auto 42%;
    height: 54%;
    background: var(--blue-soft);
    border: 3px solid rgba(22, 35, 31, 0.1);
    transform: skewX(-15deg);
    z-index: -1;
  }

  .hero::after {
    content: "";
    position: absolute;
    right: -10%;
    bottom: 4%;
    width: 58%;
    height: 18%;
    background: var(--amber-soft);
    border: 3px solid rgba(22, 35, 31, 0.12);
    transform: skewX(18deg);
    z-index: -1;
  }

  .hero-copy {
    position: relative;
    z-index: 2;
    min-width: 0;
    width: 100%;
    max-width: 760px;
  }

  .eyebrow {
    display: inline-flex;
    align-items: center;
    min-height: 34px;
    margin: 0 0 22px;
    border: 3px solid var(--line);
    border-radius: 7px;
    padding: 0 16px;
    background: var(--blue-soft);
    color: var(--ink);
    font-family: var(--analog);
    font-size: 0.82rem;
    font-weight: 950;
    letter-spacing: 0.18em;
    text-transform: uppercase;
    box-shadow: 5px 5px 0 var(--shadow);
  }

  .eyebrow-coral {
    background: var(--coral-soft);
  }

  h1,
  h2 {
    margin: 0;
    font-family: var(--analog);
    font-weight: 900;
    line-height: 0.95;
  }

  h1 {
    max-width: 820px;
    font-size: clamp(3.45rem, 5.35vw, 6.2rem);
  }

  .hero-lede {
    max-width: 740px;
    margin: 18px 0 0;
    color: var(--muted);
    font-size: clamp(1.08rem, 1.8vw, 1.54rem);
    font-weight: 750;
    line-height: 1.46;
  }

  .hero-actions {
    display: flex;
    flex-wrap: wrap;
    gap: 16px;
    margin-top: 22px;
  }

  .tool-line {
    max-width: 660px;
    margin-top: 22px;
    color: var(--muted);
    font-size: 0.98rem;
    font-weight: 800;
    line-height: 1.55;
  }

  .tool-line strong {
    color: var(--ink);
    font-family: var(--analog);
    font-size: 1.08em;
  }

  .pricing-note {
    width: fit-content;
    max-width: min(100%, 680px);
    margin: 18px 0 0;
    border: 3px solid var(--line);
    border-radius: 8px;
    padding: 12px 14px;
    background: var(--amber-soft);
    box-shadow: 5px 5px 0 var(--shadow);
    color: var(--ink);
    font-size: 0.92rem;
    font-weight: 950;
    line-height: 1.5;
  }

  .motion-stage {
    min-width: 0;
    width: 100%;
    perspective: 1000px;
  }

  .stage-card {
    position: relative;
    width: 100%;
    max-width: 640px;
    margin-left: auto;
    overflow: hidden;
    border: 3px solid var(--line);
    border-radius: 8px;
    padding: clamp(18px, 3vw, 26px);
    background:
      linear-gradient(150deg, rgba(255, 255, 255, 0.75), transparent 45%),
      var(--blue);
    box-shadow: 16px 16px 0 var(--shadow);
    transform-style: preserve-3d;
    transition: transform 120ms ease-out;
  }

  .signal-tape {
    display: flex;
    flex-wrap: wrap;
    width: 100%;
    gap: 10px;
  }

  .signal-tape span {
    border: 2px solid var(--line);
    border-radius: 999px;
    padding: 8px 14px;
    background: var(--surface);
    font-family: var(--analog);
    font-size: 0.76rem;
    font-weight: 950;
    letter-spacing: 0.12em;
    text-transform: uppercase;
    white-space: nowrap;
  }

  .signal-tape span:nth-child(2) {
    background: var(--coral-soft);
  }

  .signal-tape span:nth-child(3) {
    background: var(--amber-soft);
  }

  .signal-tape span:nth-child(4) {
    background: var(--blue-soft);
  }

  .sleep-raccoon {
    display: block;
    width: 100%;
    height: min(38vw, 300px);
    margin-top: 12px;
  }

  .angle-band {
    opacity: 0.8;
  }

  .band-blue {
    fill: var(--blue);
  }

  .band-coral {
    fill: var(--coral);
  }

  .band-amber {
    fill: var(--amber-soft);
  }

  .desk-shadow {
    fill: rgba(16, 32, 30, 0.18);
  }

  .monitor {
    fill: var(--surface);
    stroke: var(--line);
    stroke-width: 5;
  }

  .monitor-line {
    fill: none;
    stroke-linecap: round;
    stroke-width: 10;
  }

  .line-a {
    stroke: var(--blue);
  }

  .line-b {
    stroke: var(--coral);
  }

  .line-c {
    stroke: var(--amber);
  }

  .tail path:first-child {
    fill: var(--fur);
    stroke: var(--line);
    stroke-width: 5;
  }

  .tail path:not(:first-child) {
    fill: none;
    stroke: var(--line);
    stroke-linecap: round;
    stroke-width: 10;
  }

  .raccoon-body {
    animation: sleepy-breathe 4s ease-in-out infinite;
    transform-origin: 214px 222px;
  }

  .ear.outer-left,
  .ear.outer-right {
    fill: var(--line);
  }

  .ear.inner-left,
  .ear.inner-right {
    fill: var(--fur);
  }

  .head,
  .paw path:first-child {
    fill: #b9c9bd;
    stroke: var(--line);
    stroke-width: 5;
  }

  .mask {
    fill: var(--line);
  }

  .muzzle {
    fill: #f3dfbf;
  }

  .eye-base {
    fill: #fff8df;
  }

  .sleep-eye {
    fill: none;
    stroke: #11191b;
    stroke-linecap: round;
    stroke-width: 8;
    animation: sleepy-blink 5.6s ease-in-out infinite;
  }

  .nose {
    fill: #11191b;
  }

  .mouth,
  .whisker {
    fill: none;
    stroke: #7a817d;
    stroke-linecap: round;
    stroke-width: 5;
  }

  .whisker-coral {
    stroke: var(--coral);
  }

  .whisker-gold {
    stroke: var(--amber);
  }

  .mouth {
    stroke: #7a5d46;
  }

  .paw path:not(:first-child) {
    fill: none;
    stroke: #7a817d;
    stroke-linecap: round;
    stroke-width: 5;
  }

  .paw-left {
    animation: paw-stretch-left 6s ease-in-out infinite;
    transform-origin: 160px 280px;
  }

  .paw-right {
    animation: paw-stretch-right 6s ease-in-out infinite;
    transform-origin: 260px 280px;
  }

  .zzz text {
    fill: var(--coral);
    font-family: var(--analog);
    font-size: 36px;
    font-weight: 900;
  }

  .zzz-one {
    animation: zzz-float 4.2s ease-in-out infinite;
  }

  .zzz-two {
    animation: zzz-float 4.2s ease-in-out 0.7s infinite;
  }

  .zzz-three {
    animation: zzz-float 4.2s ease-in-out 1.4s infinite;
  }

  .live-card {
    display: grid;
    gap: 6px;
    border: 3px solid var(--line);
    border-radius: 8px;
    padding: 14px 16px;
    background: var(--surface);
    box-shadow: 7px 7px 0 rgba(16, 32, 29, 0.28);
  }

  .live-card span {
    color: var(--coral);
    font-family: var(--analog);
    font-size: 0.78rem;
    font-weight: 950;
    letter-spacing: 0.14em;
    text-transform: uppercase;
  }

  .live-card strong {
    font-family: var(--analog);
    font-size: clamp(1.55rem, 2.7vw, 2.1rem);
    line-height: 0.95;
  }

  .live-card p {
    margin: 0;
    color: var(--muted);
    font-weight: 850;
  }

  .how-section,
  .signals-section,
  .privacy-section,
  .setup-section {
    width: min(100%, 1280px);
    margin: 0 auto;
    padding: clamp(70px, 8vw, 118px) clamp(18px, 5vw, 56px);
    scroll-margin-top: 86px;
  }

  .how-section {
    position: relative;
  }

  .how-section::before {
    content: "";
    position: absolute;
    inset: 22% 4% auto auto;
    width: 44%;
    height: 26%;
    background: var(--coral-soft);
    border: 3px solid rgba(22, 35, 31, 0.1);
    transform: skewX(-18deg);
    z-index: -1;
  }

  .section-heading {
    max-width: 940px;
  }

  .section-heading h2,
  .signals-copy h2,
  .privacy-card h2,
  .setup-intro h2 {
    font-size: clamp(2.8rem, 5.4vw, 5.6rem);
  }

  .flow-grid {
    display: grid;
    grid-template-columns: repeat(3, minmax(0, 1fr));
    gap: 18px;
    margin-top: 44px;
  }

  .flow-card {
    min-height: 255px;
    border: 3px solid var(--line);
    border-radius: 8px;
    padding: 24px;
    box-shadow: 8px 8px 0 var(--shadow);
  }

  .flow-card span {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 46px;
    height: 36px;
    margin-bottom: 34px;
    border-radius: 999px;
    background: var(--surface);
    font-weight: 950;
  }

  .flow-card h3 {
    margin: 0 0 12px;
    font-family: var(--analog);
    font-size: 2rem;
    line-height: 1;
  }

  .flow-card p,
  .signals-copy p,
  .privacy-card p,
  .setup-intro p,
  .guide-note,
  .privacy-list span {
    color: var(--muted);
    font-size: 1.05rem;
    font-weight: 750;
    line-height: 1.6;
  }

  .flow-blue {
    background: var(--blue-soft);
  }

  .flow-amber {
    background: var(--amber-soft);
  }

  .flow-coral {
    background: var(--coral-soft);
  }

  .signals-section {
    display: grid;
    grid-template-columns: minmax(0, 0.8fr) minmax(360px, 0.9fr);
    gap: clamp(32px, 6vw, 80px);
    align-items: start;
    background:
      linear-gradient(110deg, rgba(185, 232, 255, 0.56), transparent 30%),
      var(--surface);
    border-block: 3px solid rgba(22, 35, 31, 0.12);
    max-width: none;
    width: 100%;
  }

  .signals-section > * {
    width: min(100%, 1280px);
  }

  .signals-copy {
    justify-self: end;
    max-width: 560px;
  }

  .workflow-stage {
    position: relative;
    display: grid;
    width: min(100%, 760px);
    min-height: 455px;
    padding-bottom: 12px;
  }

  .workflow-window {
    border: 3px solid var(--line);
    border-radius: 8px;
    background: var(--surface);
    box-shadow: 10px 10px 0 var(--shadow);
  }

  .terminal-window {
    align-self: start;
    justify-self: start;
    width: min(100%, 720px);
    z-index: 2;
  }

  .window-bar {
    display: flex;
    align-items: center;
    gap: 8px;
    min-height: 46px;
    border-bottom: 3px solid var(--line);
    padding: 0 14px;
    background: var(--blue-soft);
  }

  .window-bar span {
    width: 12px;
    height: 12px;
    border: 2px solid var(--line);
    border-radius: 999px;
    background: var(--coral);
  }

  .window-bar span:nth-child(2) {
    background: var(--amber);
  }

  .window-bar span:nth-child(3) {
    background: var(--blue);
  }

  .window-bar strong {
    margin-left: auto;
    color: var(--muted);
    font-family: var(--analog);
    font-size: 0.78rem;
    font-weight: 950;
    letter-spacing: 0.12em;
    text-transform: uppercase;
  }

  .terminal-body {
    display: grid;
    gap: 16px;
    min-height: 260px;
    padding: clamp(22px, 3vw, 34px);
    background: #10221f;
    color: #fffefa;
    font-family: var(--analog);
    font-weight: 800;
  }

  .terminal-body p {
    margin: 0;
  }

  .typed-line {
    position: relative;
    width: 100%;
    max-width: 40ch;
    overflow: hidden;
    color: var(--amber);
    white-space: nowrap;
  }

  .typed-line::after {
    content: "";
    display: inline-block;
    width: 0.72ch;
    height: 1.05em;
    margin-left: 0.28ch;
    background: currentColor;
    transform: translateY(0.16em);
    animation: caret-blink 1.15s steps(2, end) infinite;
  }

  .typed-line span {
    color: var(--blue);
  }

  .terminal-status {
    min-height: clamp(2.1rem, 4.4vw, 3rem);
  }

  .terminal-status p {
    color: var(--surface);
    font-size: clamp(1.3rem, 3vw, 2rem);
    letter-spacing: 0;
    animation: status-fade 520ms ease both;
  }

  .companion-window {
    position: relative;
    justify-self: end;
    display: grid;
    grid-template-columns: auto minmax(0, 1fr) auto;
    gap: 16px;
    align-items: center;
    width: min(92%, 560px);
    margin-top: -24px;
    margin-right: 22px;
    padding: 16px 18px;
    background:
      linear-gradient(145deg, rgba(185, 232, 255, 0.82), rgba(255, 228, 217, 0.62)),
      var(--surface);
    z-index: 3;
    animation: companion-float 6.5s ease-in-out infinite;
  }

  .notification-raccoon img {
    display: block;
    border: 2px solid var(--line);
    border-radius: 15px;
    background: var(--surface);
    box-shadow: 4px 4px 0 var(--shadow);
  }

  .notification-copy span {
    display: block;
    margin-bottom: 5px;
    color: var(--coral);
    font-family: var(--analog);
    font-size: 0.78rem;
    font-weight: 950;
    letter-spacing: 0.12em;
    text-transform: uppercase;
  }

  .notification-copy strong {
    display: block;
    font-family: var(--analog);
    font-size: clamp(1.35rem, 2.4vw, 1.9rem);
    line-height: 1;
  }

  .notification-copy p {
    margin: 7px 0 0;
    color: var(--muted);
    font-size: 0.96rem;
    font-weight: 850;
    line-height: 1.35;
  }

  .notification-state {
    display: flex;
    gap: 7px;
  }

  .notification-state span {
    width: 9px;
    height: 9px;
    border: 2px solid var(--line);
    border-radius: 999px;
    background: var(--blue);
    animation: state-pulse 2.8s ease-in-out infinite;
  }

  .notification-state span:nth-child(2) {
    background: var(--amber);
    animation-delay: 0.22s;
  }

  .notification-state span:nth-child(3) {
    background: var(--coral);
    animation-delay: 0.44s;
  }

  .privacy-section {
    display: grid;
    grid-template-columns: minmax(0, 0.95fr) minmax(320px, 0.65fr);
    gap: clamp(32px, 6vw, 80px);
    align-items: center;
  }

  .privacy-card {
    max-width: 760px;
  }

  .privacy-list {
    display: grid;
    gap: 12px;
    border: 3px solid var(--line);
    border-radius: 8px;
    padding: 22px;
    background: var(--blue-soft);
    box-shadow: 10px 10px 0 var(--shadow);
  }

  .privacy-list div {
    border: 1px solid rgba(22, 35, 31, 0.16);
    border-radius: 7px;
    padding: 18px;
    background: var(--surface);
  }

  .privacy-list div:nth-child(2) {
    background: var(--blue-soft);
  }

  .privacy-list div:nth-child(3) {
    background: var(--coral-soft);
  }

  .privacy-list strong {
    display: block;
    margin-bottom: 7px;
    font-family: var(--analog);
    font-size: 1.8rem;
    line-height: 1;
  }

  .privacy-list span {
    display: block;
  }

  .setup-section {
    display: grid;
    gap: clamp(28px, 5vw, 58px);
    max-width: none;
    width: 100%;
    background:
      linear-gradient(115deg, var(--coral-soft) 0 30%, transparent 30%),
      linear-gradient(75deg, transparent 0 56%, var(--blue-soft) 56% 78%, transparent 78%),
      var(--surface);
    border-top: 3px solid rgba(22, 35, 31, 0.12);
  }

  .setup-intro {
    max-width: 820px;
    margin-inline: auto;
    text-align: center;
  }

  .setup-guides {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 18px;
    width: min(100%, 1180px);
    margin: 0 auto;
  }

  .tool-guide {
    display: flex;
    flex-direction: column;
    min-width: 0;
    border: 3px solid var(--line);
    border-radius: 8px;
    padding: clamp(20px, 3vw, 28px);
    background: var(--surface);
    box-shadow: 10px 10px 0 var(--shadow);
  }

  .guide-claude {
    background:
      linear-gradient(150deg, rgba(227, 246, 255, 0.92), rgba(255, 254, 250, 0.88) 48%),
      var(--surface);
  }

  .guide-codex {
    background:
      linear-gradient(150deg, rgba(255, 228, 217, 0.92), rgba(255, 254, 250, 0.88) 48%),
      var(--surface);
  }

  .guide-heading {
    display: flex;
    align-items: end;
    justify-content: space-between;
    gap: 16px;
    margin-bottom: 22px;
    padding-bottom: 18px;
    border-bottom: 2px solid rgba(20, 35, 31, 0.16);
  }

  .guide-heading span {
    font-family: var(--analog);
    font-size: clamp(2rem, 4vw, 3rem);
    font-weight: 900;
    line-height: 0.95;
  }

  .guide-heading strong {
    color: var(--coral);
    font-family: var(--analog);
    font-size: 0.78rem;
    font-weight: 950;
    letter-spacing: 0.12em;
    text-transform: uppercase;
    white-space: nowrap;
  }

  .step-list {
    display: grid;
    gap: 12px;
    margin: 0;
    padding: 0;
    list-style: none;
  }

  .step-list li {
    display: grid;
    grid-template-columns: 34px minmax(0, 1fr);
    gap: 12px;
    align-items: start;
  }

  .step-list li > span {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 34px;
    height: 34px;
    border: 2px solid var(--line);
    border-radius: 999px;
    background: var(--blue-soft);
    font-weight: 950;
    line-height: 1;
  }

  .guide-codex .step-list li > span {
    background: var(--amber-soft);
  }

  .step-list p {
    margin: 0;
    color: var(--ink);
    font-size: 1rem;
    font-weight: 780;
    line-height: 1.48;
  }

  .step-list strong {
    font-weight: 950;
  }

  .guide-note {
    margin: auto 0 0;
    padding-top: 20px;
  }

  .site-footer {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 18px;
    padding: 28px clamp(18px, 5vw, 96px);
    color: var(--muted);
    font-family: var(--analog);
    font-weight: 850;
  }

  .site-footer span {
    color: var(--ink);
    font-family: var(--analog);
    font-size: 1.3rem;
    font-weight: 900;
  }

  @keyframes caret-blink {
    0%,
    44% {
      opacity: 1;
    }
    45%,
    100% {
      opacity: 0;
    }
  }

  @keyframes status-fade {
    0% {
      opacity: 0;
      transform: translateY(5px);
    }
    100% {
      opacity: 1;
      transform: translateY(0);
    }
  }

  @keyframes companion-float {
    0%,
    100% {
      transform: translateY(0);
    }
    50% {
      transform: translateY(-3px);
    }
  }

  @keyframes state-pulse {
    0%,
    100% {
      transform: translateY(0);
      opacity: 0.72;
    }
    46% {
      transform: translateY(-2px);
      opacity: 1;
    }
  }

  @keyframes sleepy-breathe {
    0%,
    100% {
      transform: translateY(0) scale(1);
    }
    50% {
      transform: translateY(4px) scale(1.015);
    }
  }

  @keyframes sleepy-blink {
    0%,
    56%,
    100% {
      transform: translateY(0);
    }
    60%,
    68% {
      transform: translateY(7px);
    }
  }

  @keyframes paw-stretch-left {
    0%,
    52%,
    100% {
      transform: rotate(0deg) translateX(0);
    }
    64%,
    76% {
      transform: rotate(-7deg) translateX(-10px);
    }
  }

  @keyframes paw-stretch-right {
    0%,
    52%,
    100% {
      transform: rotate(0deg) translateX(0);
    }
    64%,
    76% {
      transform: rotate(7deg) translateX(10px);
    }
  }

  @keyframes zzz-float {
    0% {
      opacity: 0;
      transform: translateY(16px) scale(0.82);
    }
    30% {
      opacity: 1;
    }
    100% {
      opacity: 0;
      transform: translateY(-22px) scale(1.08);
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .typed-line::after,
    .terminal-status p,
    .companion-window,
    .notification-state span,
    .raccoon-body,
    .sleep-eye,
    .paw-left,
    .paw-right,
    .zzz-one,
    .zzz-two,
    .zzz-three {
      animation: none;
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
    .signals-section,
    .privacy-section,
    .setup-section {
      grid-template-columns: 1fr;
    }

    .hero {
      padding-top: 44px;
    }

    .stage-card {
      margin: 0;
    }

    .signals-section > *,
    .signals-copy {
      justify-self: auto;
      width: 100%;
      max-width: none;
    }

    .setup-guides {
      grid-template-columns: 1fr;
    }
  }

  @media (max-width: 720px) {
    .site-header {
      min-height: 64px;
      gap: 12px;
    }

    .brand {
      font-size: 1.2rem;
    }

    .brand img {
      width: 38px;
      height: 38px;
    }

    .nav-cta {
      min-height: 42px;
      padding: 0 14px;
      box-shadow: 5px 5px 0 var(--shadow);
    }

    .hero {
      min-height: auto;
      padding-bottom: 60px;
    }

    h1 {
      font-size: clamp(3.1rem, 16vw, 4.7rem);
    }

    .hero-lede {
      line-height: 1.55;
    }

    .flow-grid {
      grid-template-columns: 1fr;
    }

    .signal-tape {
      width: 100%;
      flex-wrap: wrap;
      animation: none;
    }

    .signal-tape span {
      white-space: normal;
    }

    .workflow-stage {
      min-height: auto;
    }

    .terminal-window,
    .companion-window {
      width: 100%;
    }

    .companion-window {
      margin: -12px 0 0;
    }

    .terminal-body {
      min-height: 220px;
    }

    .typed-line {
      animation: none;
      max-width: none;
      white-space: normal;
    }

    .site-footer {
      align-items: flex-start;
      flex-direction: column;
    }
  }

  @media (max-width: 430px) {
    .site-header {
      padding-inline: 14px;
    }

    .brand span {
      max-width: 132px;
    }

    .nav-cta {
      font-size: 0.86rem;
    }

    .hero,
    .how-section,
    .signals-section,
    .privacy-section,
    .setup-section {
      padding-inline: 14px;
    }

    .eyebrow {
      font-size: 0.68rem;
      letter-spacing: 0.13em;
    }

    h1 {
      font-size: clamp(2.75rem, 15vw, 3.5rem);
    }

    .button {
      width: 100%;
    }

    .stage-card {
      box-shadow: 8px 8px 0 var(--shadow);
    }
  }
</style>
