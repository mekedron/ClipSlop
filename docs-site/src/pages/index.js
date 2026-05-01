import clsx from 'clsx';
import Link from '@docusaurus/Link';
import useBaseUrl from '@docusaurus/useBaseUrl';
import useDocusaurusContext from '@docusaurus/useDocusaurusContext';
import Layout from '@theme/Layout';

import styles from './index.module.css';

const FEATURES = [
  {
    title: 'Quick Paste',
    blurb:
      'Assign any prompt to a global hotkey. Captures selected text, runs the prompt, pastes the result back — you never leave your app.',
    example: 'select text → ⌃⌘G → grammar fixed',
    to: '/docs/how-it-works',
    linkLabel: 'How Quick Paste works →',
  },
  {
    title: 'Full pipeline',
    blurb:
      'Chain unlimited transformations with single-key navigation. Translate → Rewrite → Format. Every step saved, branch from anywhere.',
    example: '⌃⌘C → R → B → T → E → done',
    to: '/docs/how-it-works',
    linkLabel: 'See the prompt tree →',
  },
  {
    title: 'Multi-provider',
    blurb:
      'Sign in with ChatGPT (free), use API keys for OpenAI or Anthropic, or run locally with Ollama. Mix providers per prompt.',
    example: 'ChatGPT · Claude · Ollama · CLI',
    to: '/docs/providers/chatgpt',
    linkLabel: 'Pick a provider →',
  },
];

const PROMPT_GROUPS = [
  {key: 'T', label: 'Translate', detail: '18 languages'},
  {key: 'R', label: 'Rewrite', detail: '7 tones'},
  {key: 'F', label: 'Format', detail: 'Grammar · Email · Markdown'},
  {key: 'D', label: 'Dev', detail: 'Comments · Logs · Stack traces'},
  {key: 'A', label: 'Analyze', detail: 'Summary · TL;DR'},
  {key: 'C', label: 'Convert', detail: 'HTML ↔ Markdown'},
];

function Hero() {
  return (
    <section className={styles.hero}>
      <div className={styles.heroInner}>
        <div className={styles.eyebrow}>AI text transformations for macOS</div>
        <h1 className={styles.heroTitle}>
          Select text. Press a hotkey.
          <br />
          <span className={styles.heroAccent}>Grammar fixed.</span>
        </h1>
        <p className={styles.heroLead}>
          ClipSlop is a free, open-source keyboard-first AI writing tool. Fix
          grammar, translate, rewrite, format — all without leaving the app
          you&apos;re typing in.
        </p>
        <div className={styles.heroCtas}>
          <Link
            className={clsx(styles.btn, styles.btnPrimary)}
            href="https://github.com/mekedron/ClipSlop/releases/latest">
            Download for macOS
          </Link>
          <Link className={clsx(styles.btn, styles.btnGhost)} to="/docs/intro">
            Read the docs
          </Link>
        </div>
        <div className={styles.heroMeta}>
          <span>★ Open source · MIT</span>
          <span aria-hidden="true">·</span>
          <span>macOS 14+</span>
          <span aria-hidden="true">·</span>
          <span>ChatGPT · Claude · Ollama</span>
        </div>
      </div>
    </section>
  );
}

function Features() {
  return (
    <section className={styles.section}>
      <div className={styles.featuresGrid}>
        {FEATURES.map((f) => (
          <div key={f.title} className={styles.featureCard}>
            <h3 className={styles.featureTitle}>{f.title}</h3>
            <p className={styles.featureBlurb}>{f.blurb}</p>
            <code className={styles.featureExample}>{f.example}</code>
            <Link className={styles.featureLink} to={f.to}>
              {f.linkLabel}
            </Link>
          </div>
        ))}
      </div>
    </section>
  );
}

function Screenshot() {
  return (
    <section className={clsx(styles.section, styles.screenshotSection)}>
      <video
        src={useBaseUrl('/demos/videos/quick-paste.webm')}
        className={styles.screenshot}
        autoPlay
        loop
        muted
        playsInline
        controls
      />
      <p className={styles.screenshotCaption}>
        Quick Paste in action — select, hit a hotkey, transformed text appears.
      </p>
    </section>
  );
}

function Prompts() {
  return (
    <section className={clsx(styles.section, styles.promptsSection)}>
      <div className={styles.eyebrow}>Built-in prompts</div>
      <h2 className={styles.sectionTitle}>Six prompt groups, ready to go</h2>
      <p className={styles.sectionLead}>
        Single-key mnemonics open each group. Add your own in Settings → Prompts.
      </p>
      <div className={styles.promptsGrid}>
        {PROMPT_GROUPS.map((p) => (
          <div key={p.key} className={styles.promptCard}>
            <div className={styles.promptKey}>[{p.key}]</div>
            <div className={styles.promptLabel}>{p.label}</div>
            <div className={styles.promptDetail}>{p.detail}</div>
          </div>
        ))}
      </div>
      <Link className={styles.promptsLink} to="/docs/built-in-prompts">
        See the full prompt catalogue →
      </Link>
    </section>
  );
}

function BottomCta() {
  return (
    <section className={clsx(styles.section, styles.bottomCta)}>
      <h2 className={styles.bottomTitle}>Free, open source, MIT.</h2>
      <p className={styles.bottomLead}>
        No subscriptions. No lock-in. Bring your own AI provider.
      </p>
      <div className={styles.heroCtas}>
        <Link
          className={clsx(styles.btn, styles.btnPrimary)}
          href="https://github.com/mekedron/ClipSlop">
          View on GitHub
        </Link>
        <Link
          className={clsx(styles.btn, styles.btnGhost)}
          href="https://buymeacoffee.com/mekedron">
          Buy me a coffee ☕
        </Link>
      </div>
    </section>
  );
}

export default function Home() {
  const {siteConfig} = useDocusaurusContext();
  return (
    <Layout
      title={siteConfig.title}
      description="ClipSlop — free, open-source AI writing tool for macOS. Fix grammar, translate, rewrite, format with a hotkey. Works in any app.">
      <main className={styles.landing}>
        <Hero />
        <Features />
        <Screenshot />
        <Prompts />
        <BottomCta />
      </main>
    </Layout>
  );
}
