import {useEffect, useRef, useState} from 'react';
import clsx from 'clsx';
import Link from '@docusaurus/Link';
import useDocusaurusContext from '@docusaurus/useDocusaurusContext';
import Layout from '@theme/Layout';

import styles from './index.module.css';

const PROMPTS = [
  {key: 'T', label: 'Translate', anchor: 'translate', color: 't', detail: '18 languages — English, Finnish, Russian, Spanish, French, German, +12 more'},
  {key: 'R', label: 'Rewrite',   anchor: 'rewrite',   color: 'r', detail: '7 tones — Neutral, Professional, Warm, Business, Playful, Biblical, Elaborate'},
  {key: 'F', label: 'Format',    anchor: 'format',    color: 'f', detail: 'Fix Grammar, Clean Up, Email, Markdownify, HTMLify, Reformat, Beautify Code'},
  {key: 'D', label: 'Dev',       anchor: 'dev',       color: 'd', detail: 'Add Comments, Clean Logs, Explain Code & Stack Traces, Naming, Beautify'},
  {key: 'A', label: 'Analyze',   anchor: 'analyze',   color: 'a', detail: 'Summary, TL;DR, Explain Simply, Condense 20%'},
  {key: 'C', label: 'Convert',   anchor: 'convert',   color: 'c', detail: 'HTML ↔ Markdown — preserve structure, strip cruft'},
];

const COMPARE_ROWS = [
  {label: 'Inline (no app switch)',
    cells: [
      {kind: 'yes', text: '✓ Quick Paste'},
      {kind: 'yes', text: '✓'},
      {kind: 'maybe', text: '≈ launcher'},
      {kind: 'yes', text: '✓'},
      {kind: 'no', text: '✗ browser tab'},
    ]},
  {label: 'Prompt chaining',
    cells: [
      {kind: 'yes', text: '✓ unlimited + branching'},
      {kind: 'maybe', text: '≈ sequential, no history'},
      {kind: 'maybe', text: '≈ limited'},
      {kind: 'no', text: '✗ one-shot'},
      {kind: 'no', text: '✗ manual'},
    ]},
  {label: 'Step history & branching',
    cells: [
      {kind: 'yes', text: '✓ full history tree'},
      {kind: 'no', text: '✗'},
      {kind: 'no', text: '✗'},
      {kind: 'no', text: '✗'},
      {kind: 'maybe', text: '≈ scroll up'},
    ]},
  {label: 'Bring your own provider',
    cells: [
      {kind: 'yes', text: '✓ ChatGPT/Claude/Ollama/CLI'},
      {kind: 'yes', text: '✓ 37+'},
      {kind: 'maybe', text: '≈ Pro plan'},
      {kind: 'no', text: '✗ proprietary'},
      {kind: 'no', text: '✗ OpenAI only'},
    ]},
  {label: 'Run locally (Ollama / MLX)',
    cells: [
      {kind: 'yes', text: '✓ Ollama'},
      {kind: 'yes', text: '✓'},
      {kind: 'no', text: '✗'},
      {kind: 'no', text: '✗'},
      {kind: 'no', text: '✗'},
    ]},
  {label: 'Screen OCR (text from image)',
    cells: [
      {kind: 'yes', text: '✓ ⇧⌘2'},
      {kind: 'no', text: '✗'},
      {kind: 'no', text: '✗'},
      {kind: 'no', text: '✗'},
      {kind: 'maybe', text: '≈ uploads'},
    ]},
  {label: 'Open source',
    cells: [
      {kind: 'yes', text: '✓ MIT'},
      {kind: 'no', text: '✗'},
      {kind: 'no', text: '✗'},
      {kind: 'no', text: '✗'},
      {kind: 'no', text: '✗'},
    ]},
  {label: 'Price',
    cells: [
      {kind: 'yes', text: 'Free'},
      {kind: 'maybe', text: '$29 / $5 mo'},
      {kind: 'maybe', text: '~$8 mo'},
      {kind: 'no', text: '$12 mo'},
      {kind: 'no', text: '$20 mo'},
    ]},
];

const COMPARE_COLS = ['ClipSlop', 'RewriteBar', 'Raycast AI', 'Grammarly', 'ChatGPT (web)'];

function Hero() {
  return (
    <section className={styles.hero}>
      <div className={styles.wrap}>
        <div className={styles.eyebrow}>Free &amp; open source · macOS 14+</div>
        <h1 className={styles.h1}>
          Select text. <em>Press a hotkey.</em>
          <br />
          <span className={styles.h1Accent}>Grammar fixed.</span>
        </h1>
        <p className={styles.lede}>
          ClipSlop is a keyboard-first AI writing tool for macOS. Fix grammar,
          translate, rewrite, format — all without leaving the app you&rsquo;re
          typing in. Bring your own AI provider; no subscription, no lock-in.
        </p>
        <div className={styles.heroCtas}>
          <Link
            className={clsx(styles.btn, styles.btnPrimary)}
            href="https://github.com/mekedron/ClipSlop/releases/latest">
            <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
              <path d="M17.05 20.28c-.98.95-2.05.8-3.08.35-1.09-.46-2.09-.48-3.24 0-1.44.62-2.2.44-3.06-.35C2.79 15.25 3.51 7.59 9.05 7.31c1.35.07 2.29.74 3.08.8 1.18-.24 2.31-.93 3.57-.84 1.51.12 2.65.72 3.4 1.8-3.12 1.87-2.38 5.98.48 7.13-.57 1.5-1.31 2.99-2.54 4.09l.01-.01M12.03 7.25c-.15-2.23 1.66-4.07 3.74-4.25.29 2.58-2.34 4.5-3.74 4.25z" />
            </svg>
            Download for Mac
          </Link>
          <Link className={clsx(styles.btn, styles.btnGhost)} to="/docs/intro">
            Read the docs <span className={styles.arrow}>→</span>
          </Link>
        </div>
        <div className={styles.heroMeta}>
          <span>★ MIT License</span>
          <span className={styles.heroMetaDot}>·</span>
          <span>macOS 14 Sonoma+</span>
          <span className={styles.heroMetaDot}>·</span>
          <span>ChatGPT · Claude · Ollama</span>
          <span className={styles.heroMetaDot}>·</span>
          <span>~12 MB</span>
        </div>
      </div>
      <Demo />
    </section>
  );
}

function Demo() {
  const boxRef = useRef(null);
  const beforeRef = useRef(null);
  const afterRef = useRef(null);
  const ctrlRef = useRef(null);
  const cmdRef = useRef(null);
  const gRef = useRef(null);
  const [done, setDone] = useState(false);
  const [statusText, setStatusText] = useState(
    'Press ⌃⌘G to fix grammar in place',
  );
  const timeoutsRef = useRef([]);

  useEffect(() => {
    if (typeof window === 'undefined') return;
    const reduceMotion = window.matchMedia(
      '(prefers-reduced-motion: reduce)',
    ).matches;

    const reset = () => {
      timeoutsRef.current.forEach(clearTimeout);
      timeoutsRef.current = [];
      boxRef.current?.classList.remove(styles.focused);
      ctrlRef.current?.classList.remove(styles.pressed);
      cmdRef.current?.classList.remove(styles.pressed);
      gRef.current?.classList.remove(styles.pressed);
      if (beforeRef.current) beforeRef.current.style.opacity = 1;
      if (afterRef.current) afterRef.current.style.opacity = 0;
      setDone(false);
      setStatusText('Press ⌃⌘G to fix grammar in place');
    };

    const play = () => {
      reset();
      const t = (ms, fn) => {
        timeoutsRef.current.push(setTimeout(fn, ms));
      };
      t(600,  () => boxRef.current?.classList.add(styles.focused));
      t(1200, () => ctrlRef.current?.classList.add(styles.pressed));
      t(1350, () => cmdRef.current?.classList.add(styles.pressed));
      t(1500, () => gRef.current?.classList.add(styles.pressed));
      t(1700, () => setStatusText('processing'));
      t(2100, () => {
        ctrlRef.current?.classList.remove(styles.pressed);
        cmdRef.current?.classList.remove(styles.pressed);
        gRef.current?.classList.remove(styles.pressed);
      });
      t(2700, () => {
        if (beforeRef.current) beforeRef.current.style.opacity = 0;
        if (afterRef.current) afterRef.current.style.opacity = 1;
      });
      t(3100, () => {
        setDone(true);
        setStatusText('Pasted in place · 4 corrections · 580ms');
      });
      if (!reduceMotion) {
        t(7000, play);
      }
    };

    if (reduceMotion) {
      // Show the "after" state directly, no animation loop
      if (beforeRef.current) beforeRef.current.style.opacity = 0;
      if (afterRef.current) afterRef.current.style.opacity = 1;
      setDone(true);
      setStatusText('Pasted in place · 4 corrections · 580ms');
      return undefined;
    }

    const node = boxRef.current;
    if (!node) return undefined;
    const io = new IntersectionObserver(
      (entries) => {
        entries.forEach((e) => {
          if (e.isIntersecting) play();
        });
      },
      {threshold: 0.4},
    );
    io.observe(node);

    return () => {
      timeoutsRef.current.forEach(clearTimeout);
      io.disconnect();
    };
  }, []);

  const replay = () => {
    timeoutsRef.current.forEach(clearTimeout);
    timeoutsRef.current = [];
    // Re-trigger play loop from scratch
    const event = new Event('replay');
    boxRef.current?.dispatchEvent(event);
    // Easiest: simulate by toggling and letting useEffect's handler re-run
    if (boxRef.current) {
      boxRef.current.classList.remove(styles.focused);
      // Using a microtask to let the DOM settle, then call IntersectionObserver-style play
      setTimeout(() => {
        // Manually replicate the play sequence
        const ctrl = ctrlRef.current;
        const cmd = cmdRef.current;
        const g = gRef.current;
        const before = beforeRef.current;
        const after = afterRef.current;
        const t = (ms, fn) => timeoutsRef.current.push(setTimeout(fn, ms));
        boxRef.current?.classList.remove(styles.focused);
        ctrl?.classList.remove(styles.pressed);
        cmd?.classList.remove(styles.pressed);
        g?.classList.remove(styles.pressed);
        if (before) before.style.opacity = 1;
        if (after) after.style.opacity = 0;
        setDone(false);
        setStatusText('Press ⌃⌘G to fix grammar in place');
        t(300,  () => boxRef.current?.classList.add(styles.focused));
        t(700,  () => ctrl?.classList.add(styles.pressed));
        t(850,  () => cmd?.classList.add(styles.pressed));
        t(1000, () => g?.classList.add(styles.pressed));
        t(1200, () => setStatusText('processing'));
        t(1500, () => {
          ctrl?.classList.remove(styles.pressed);
          cmd?.classList.remove(styles.pressed);
          g?.classList.remove(styles.pressed);
        });
        t(1900, () => {
          if (before) before.style.opacity = 0;
          if (after)  after.style.opacity = 1;
        });
        t(2300, () => {
          setDone(true);
          setStatusText('Pasted in place · 4 corrections · 580ms');
        });
      }, 30);
    }
  };

  return (
    <div className={styles.demo}>
      <div className={clsx(styles.floatTile, styles.floatTileL, styles.tileT)}>
        <span className={styles.floatBadge}>T</span>Translate → English
      </div>
      <div className={clsx(styles.floatTile, styles.floatTileR, styles.tileR)}>
        <span className={styles.floatBadge}>F</span>Fix Grammar · ⌃⌘G
      </div>

      <div className={styles.demoWindow}>
        <div className={styles.demoTitlebar}>
          <div className={styles.traffic}><span /><span /><span /></div>
          <div className={styles.demoTitle}>
            <span className={styles.demoAppName}>
              <span className={styles.demoAppIcon} />
              {' Notes — Untitled'}
            </span>
          </div>
        </div>
        <div className={styles.demoBody}>
          <div className={styles.demoTextboxLabel}>
            <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" aria-hidden="true">
              <path d="M12 20h9" /><path d="M16.5 3.5a2.121 2.121 0 0 1 3 3L7 19l-4 1 1-4L16.5 3.5z" />
            </svg>
            You&apos;re typing
          </div>
          <div className={styles.demoTextbox} ref={boxRef}>
            <div className={styles.demoTextStage}>
              <div className={clsx(styles.demoText, styles.demoTextBefore)} ref={beforeRef}>
                i <span className={styles.err}>recieved</span> your email yesterday and{' '}
                <span className={styles.err}>i</span> wanted{' '}
                <span className={styles.err}>too</span> say thanks for{' '}
                <span className={styles.err}>there</span> quick reply.
              </div>
              <div className={clsx(styles.demoText, styles.demoTextAfter)} ref={afterRef}>
                <span className={styles.fix}>I received</span> your email yesterday and{' '}
                <span className={styles.fix}>I</span> wanted{' '}
                <span className={styles.fix}>to</span> say thanks for{' '}
                <span className={styles.fix}>your</span> quick reply.
              </div>
            </div>
          </div>

          <div className={styles.demoHotkey}>
            <div className={styles.keys}>
              <kbd ref={ctrlRef}>⌃</kbd>
              <span className={styles.keysPlus}>+</span>
              <kbd ref={cmdRef}>⌘</kbd>
              <span className={styles.keysPlus}>+</span>
              <kbd ref={gRef}>G</kbd>
              <span className={styles.keysLabel}>Fix Grammar</span>
            </div>
          </div>

          <div className={clsx(styles.demoStatus, done && styles.demoStatusDone)}>
            <span className={styles.pulse} />
            <span>{statusText}</span>
          </div>

          <button className={styles.demoReplay} onClick={replay} type="button">
            <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
              <polyline points="23 4 23 10 17 10" />
              <path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10" />
            </svg>
            Replay
          </button>
        </div>
      </div>
      <p className={styles.demoCaption}>
        No copying, no tabs, no dialog boxes. Result pastes back where the cursor is.
      </p>
    </div>
  );
}

function HowItWorks() {
  return (
    <section className={styles.sec} id="how">
      <div className={styles.wrap}>
        <div className={styles.secHead}>
          <div className={styles.secEyebrow}>How it works</div>
          <h2 className={styles.h2}>Two modes. <em>Both</em> ridiculously fast.</h2>
          <p className={styles.secLede}>
            Use a single hotkey for one-shot fixes, or chain prompts together for
            the full pipeline. ClipSlop lives in your menu bar; you live in your editor.
          </p>
        </div>
        <div className={styles.steps}>
          <div className={styles.step}>
            <div className={styles.stepNum}>01</div>
            <div className={clsx(styles.stepIcon, styles.stepIconMagenta)}>
              <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
                <path d="M9 11l3 3 8-8" />
                <path d="M20 12v6a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h9" />
              </svg>
            </div>
            <h3>Quick Paste</h3>
            <p>
              Bind any prompt to a global hotkey. ClipSlop captures the selection,
              transforms it, pastes it back — entirely in the background.
            </p>
            <div className={styles.terminal}>
              select text <span className={styles.termArrow}>→</span>{' '}
              <span className={styles.ks}>⌃</span>
              <span className={styles.ks}>⌘</span>
              <span className={styles.ks}>G</span>{' '}
              <span className={styles.termArrow}>→</span>{' '}
              <span className={styles.ok}>grammar fixed ✓</span>
            </div>
          </div>

          <div className={styles.step}>
            <div className={styles.stepNum}>02</div>
            <div className={clsx(styles.stepIcon, styles.stepIconBlue)}>
              <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
                <circle cx="6" cy="6" r="3" />
                <circle cx="6" cy="18" r="3" />
                <path d="M11 6h5a4 4 0 0 1 4 4v0a4 4 0 0 1-4 4H8" />
              </svg>
            </div>
            <h3>Full pipeline</h3>
            <p>
              Need more than one step? Drill through the prompt tree with single-key
              mnemonics. Every result is saved as a step you can branch from.
            </p>
            <div className={styles.terminal}>
              <span className={styles.ks}>⌃</span>
              <span className={styles.ks}>⌘</span>
              <span className={styles.ks}>C</span>{' '}
              <span className={styles.termArrow}>→</span>{' '}
              <span className={styles.ks}>R</span>
              <span className={styles.ks}>B</span>{' '}
              <span className={styles.termArrow}>→</span>{' '}
              <span className={styles.ks}>T</span>
              <span className={styles.ks}>E</span>{' '}
              <span className={styles.termArrow}>→</span>{' '}
              <span className={styles.ks}>F</span>
              <span className={styles.ks}>E</span>
            </div>
          </div>

          <div className={styles.step}>
            <div className={styles.stepNum}>03</div>
            <div className={clsx(styles.stepIcon, styles.stepIconMint)}>
              <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
                <path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8" />
                <path d="M21 3v5h-5" />
                <path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16" />
                <path d="M3 21v-5h5" />
              </svg>
            </div>
            <h3>Branch &amp; revisit</h3>
            <p>
              Hit ←/→ to walk the whole transformation chain. Don&rsquo;t like a
              result? Branch from any step. History is kept in-session, never on disk.
            </p>
            <div className={styles.terminal}>
              <span className={styles.ks}>←</span> back &nbsp;
              <span className={styles.ks}>→</span> forward &nbsp;
              <span className={styles.ks}>⌘E</span> edit
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}

function Terminals() {
  return (
    <section className={clsx(styles.sec, styles.secTight)}>
      <div className={styles.wrap}>
        <div className={styles.secHead}>
          <div className={styles.secEyebrow}>Real workflows</div>
          <h2 className={styles.h2}>
            Single-key mnemonics, <em>infinite</em> chains.
          </h2>
          <p className={styles.secLede}>
            The prompt tree is keyboard navigable. Each folder picks its prompt
            with a single letter. Translate to English, then rewrite for
            business, then format as email — three keystrokes after the trigger.
          </p>
        </div>

        <div className={styles.terminals}>
          <div className={styles.term}>
            <div className={styles.termHead}>
              <div className={styles.termTraffic}><span /><span /><span /></div>
              <div className={styles.termTitle}>FIX EMAIL DRAFT</div>
            </div>
            <div className={styles.termBody}>
              <div className={styles.termLine}><span className={styles.termPrompt}>›</span> select Slack message</div>
              <div className={styles.termLine}>
                <span className={styles.termPrompt}>›</span> press{' '}
                <span className={clsx(styles.termKey, styles.termKeyAccent)}>⌃⌘G</span>
              </div>
              <div className={styles.termLine}><span className={styles.termComment}># Fix Grammar runs inline</span></div>
              <div className={styles.termLine}><span className={styles.termResult}>✓ pasted back, ~600ms</span></div>
            </div>
          </div>

          <div className={styles.term}>
            <div className={styles.termHead}>
              <div className={styles.termTraffic}><span /><span /><span /></div>
              <div className={styles.termTitle}>FINNISH → BUSINESS EMAIL</div>
            </div>
            <div className={styles.termBody}>
              <div className={styles.termLine}>
                <span className={styles.termPrompt}>›</span>{' '}
                <span className={clsx(styles.termKey, styles.termKeyAccent)}>⌃⌘C</span>{' '}
                <span className={styles.termComment}># trigger panel</span>
              </div>
              <div className={styles.termLine}>
                <span className={styles.termPrompt}>›</span>{' '}
                <span className={styles.termKey}>T</span>{' '}
                <span className={styles.termArrow2}>→</span>{' '}
                <span className={clsx(styles.termTag, styles.termTagT)}>Translate</span>
              </div>
              <div className={styles.termLine}>
                <span className={styles.termPrompt}>›</span>{' '}
                <span className={styles.termKey}>E</span>{' '}
                <span className={styles.termArrow2}>→</span> English
              </div>
              <div className={styles.termLine}>
                <span className={styles.termPrompt}>›</span>{' '}
                <span className={styles.termKey}>R</span>{' '}
                <span className={styles.termArrow2}>→</span>{' '}
                <span className={clsx(styles.termTag, styles.termTagR)}>Rewrite</span>
              </div>
              <div className={styles.termLine}>
                <span className={styles.termPrompt}>›</span>{' '}
                <span className={styles.termKey}>B</span>{' '}
                <span className={styles.termArrow2}>→</span> Business
              </div>
              <div className={styles.termLine}>
                <span className={styles.termPrompt}>›</span>{' '}
                <span className={styles.termKey}>F</span>{' '}
                <span className={styles.termArrow2}>→</span>{' '}
                <span className={clsx(styles.termTag, styles.termTagF)}>Format</span>
              </div>
              <div className={styles.termLine}>
                <span className={styles.termPrompt}>›</span>{' '}
                <span className={styles.termKey}>E</span>{' '}
                <span className={styles.termArrow2}>→</span> Email
              </div>
              <div className={styles.termLine}><span className={styles.termResult}>✓ ready to paste · 5 keystrokes</span></div>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}

function Prompts() {
  return (
    <section className={styles.sec} id="prompts">
      <div className={styles.wrap}>
        <div className={styles.secHead}>
          <div className={styles.secEyebrow}>Built-in catalogue</div>
          <h2 className={styles.h2}>
            Six prompt groups. <em>Forty-plus</em> recipes.
          </h2>
          <p className={styles.secLede}>
            Ships with a curated set out of the box. Add your own prompts and
            folders — each gets its own mnemonic and optional global shortcut.
          </p>
        </div>
        <div className={styles.promptGrid}>
          {PROMPTS.map((p) => (
            <Link
              key={p.key}
              to={`/docs/reference/built-in-prompts#${p.anchor}`}
              className={clsx(styles.promptTile, styles[`tile_${p.color}`])}>
              <span className={styles.promptKey}>{p.key}</span>
              <span className={styles.promptName}>{p.label}</span>
              <span className={styles.promptDetail}>{p.detail}</span>
            </Link>
          ))}
        </div>
      </div>
    </section>
  );
}

function Compare() {
  return (
    <section className={clsx(styles.sec, styles.secTight)} id="compare">
      <div className={styles.wrap}>
        <div className={styles.secHead}>
          <div className={styles.secEyebrow}>Vs. the alternatives</div>
          <h2 className={styles.h2}>
            The keyboard-first one. <em>Free</em> too.
          </h2>
          <p className={styles.secLede}>
            Most AI writing tools want a subscription, a browser tab, or both.
            ClipSlop is a one-time download with the AI provider of your choice.
          </p>
        </div>
        <div className={styles.compareWrap}>
          <div className={styles.compareScroll}>
            <table className={styles.compare}>
              <thead>
                <tr>
                  <th />
                  {COMPARE_COLS.map((col, i) => (
                    <th key={col} className={i === 0 ? styles.compareUs : undefined}>
                      {col}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {COMPARE_ROWS.map((row) => (
                  <tr key={row.label}>
                    <td>{row.label}</td>
                    {row.cells.map((cell, i) => (
                      <td key={i} className={i === 0 ? styles.compareUs : undefined}>
                        <span className={clsx(styles.cell, styles[`cell_${cell.kind}`])}>
                          {cell.text}
                        </span>
                      </td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <div className={styles.compareFoot}>
            Comparison reflects publicly listed features and pricing as of May 2026.
            We&rsquo;ll keep this honest — if anything is wrong,{' '}
            <a href="https://github.com/mekedron/ClipSlop/issues">open an issue</a>.
          </div>
        </div>
      </div>
    </section>
  );
}

function CTA() {
  const [copied, setCopied] = useState(false);
  const cmd = 'brew tap mekedron/tap && brew install --cask clipslop';

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(cmd);
    } catch (e) {
      const ta = document.createElement('textarea');
      ta.value = cmd;
      document.body.appendChild(ta);
      ta.select();
      document.execCommand('copy');
      ta.remove();
    }
    setCopied(true);
    setTimeout(() => setCopied(false), 1800);
  };

  return (
    <section className={clsx(styles.sec, styles.secTight)}>
      <div className={styles.wrap}>
        <div className={styles.cta}>
          <Sparkle className={styles.sparkle} style={{top: 30, left: '8%'}} />
          <Sparkle className={clsx(styles.sparkle, styles.sparkleS2)} style={{top: 60, right: '12%'}} />
          <Sparkle className={clsx(styles.sparkle, styles.sparkleS3)} style={{bottom: 40, left: '14%'}} />

          <h2 className={styles.ctaH}>
            Free. Open. <em>Yours</em>.
          </h2>
          <p className={styles.ctaLede}>
            No subscriptions. No accounts. No telemetry. The app is MIT-licensed;
            you only ever pay your AI provider — or use the free ChatGPT sign-in.
          </p>

          <div className={styles.install}>
            <code className={styles.installCode}>
              <span className={styles.installGrey}>$</span> {cmd}
            </code>
            <button
              type="button"
              onClick={copy}
              className={clsx(styles.copyBtn, copied && styles.copyBtnCopied)}>
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
                <rect x="9" y="9" width="13" height="13" rx="2" ry="2" />
                <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
              </svg>
              {copied ? 'Copied!' : 'Copy'}
            </button>
          </div>

          <div className={styles.ctaCtas}>
            <Link
              className={clsx(styles.btn, styles.btnPrimary)}
              href="https://github.com/mekedron/ClipSlop/releases/latest">
              Download for Mac
            </Link>
            <Link className={clsx(styles.btn, styles.btnGhost)} href="https://github.com/mekedron/ClipSlop">
              <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
                <path d="M12 .3a12 12 0 0 0-3.8 23.4c.6.1.8-.3.8-.6v-2c-3.3.7-4-1.6-4-1.6-.6-1.4-1.4-1.8-1.4-1.8-1-.7.1-.7.1-.7 1.2 0 1.9 1.2 1.9 1.2 1 1.8 2.8 1.3 3.5 1 .1-.8.4-1.3.7-1.6-2.7-.3-5.5-1.3-5.5-6 0-1.2.5-2.3 1.3-3.1-.2-.4-.6-1.6 0-3.2 0 0 1-.3 3.4 1.2a11.5 11.5 0 0 1 6 0c2.3-1.5 3.3-1.2 3.3-1.2.7 1.6.2 2.8.1 3.2.8.8 1.3 1.9 1.3 3.1 0 4.6-2.8 5.6-5.5 5.9.5.4.9 1.2.9 2.3v3.3c0 .3.1.7.8.6A12 12 0 0 0 12 .3z" />
              </svg>
              Star on GitHub
            </Link>
            <Link className={clsx(styles.btn, styles.btnGhost)} href="https://buymeacoffee.com/mekedron">
              Buy me a coffee ☕
            </Link>
          </div>
        </div>
      </div>
    </section>
  );
}

function Sparkle({className, style}) {
  return (
    <svg className={className} style={style} viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <path d="M12 0l2.4 9.6L24 12l-9.6 2.4L12 24l-2.4-9.6L0 12l9.6-2.4z" />
    </svg>
  );
}

function PageBg() {
  return (
    <div className={styles.pageBg} aria-hidden="true">
      <div className={clsx(styles.blob, styles.blob1)} />
      <div className={clsx(styles.blob, styles.blob2)} />
      <div className={clsx(styles.blob, styles.blob3)} />
    </div>
  );
}

export default function Home() {
  const {siteConfig} = useDocusaurusContext();
  return (
    <Layout
      title={`${siteConfig.title} — Select text. Press a hotkey. Grammar fixed.`}
      description="ClipSlop is a free, open-source AI writing tool for macOS. Fix grammar, translate, rewrite, format — all without leaving the app you're typing in. Works with ChatGPT, Claude, Ollama, and any OpenAI-compatible API.">
      <PageBg />
      <main className={styles.landing}>
        <Hero />
        <HowItWorks />
        <Terminals />
        <Prompts />
        <Compare />
        <CTA />
      </main>
    </Layout>
  );
}
