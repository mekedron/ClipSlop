/**
 * Live GitHub star count for the navbar item.
 *
 * The navbar markup is rendered as a static HTML item by Docusaurus
 * (so we don't have to swizzle), and this module hydrates the count
 * after page load. Cached in localStorage for an hour to stay polite
 * with GitHub's 60-req/hour unauthenticated rate limit.
 */

const REPO = 'mekedron/ClipSlop';
const CACHE_KEY = 'clipslop:gh-stars';
const CACHE_TTL_MS = 60 * 60 * 1000; // 1 hour
const SELECTOR = '[data-github-stars]';

function formatStars(n) {
  if (typeof n !== 'number' || !isFinite(n)) return '';
  if (n >= 10_000) return (n / 1000).toFixed(0) + 'k';
  if (n >= 1_000) return (n / 1000).toFixed(1) + 'k';
  return String(n);
}

function readCache() {
  try {
    const raw = localStorage.getItem(CACHE_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw);
    if (typeof parsed?.count !== 'number') return null;
    if (typeof parsed?.expiresAt !== 'number') return null;
    return parsed;
  } catch {
    return null;
  }
}

function writeCache(count) {
  try {
    localStorage.setItem(
      CACHE_KEY,
      JSON.stringify({count, expiresAt: Date.now() + CACHE_TTL_MS}),
    );
  } catch {
    // localStorage may throw in private mode / quota — non-fatal.
  }
}

function paint(count) {
  const text = formatStars(count);
  if (!text) return;
  document.querySelectorAll(SELECTOR).forEach((el) => {
    el.textContent = text;
    el.setAttribute('data-loaded', 'true');
  });
}

async function fetchCount() {
  const res = await fetch(`https://api.github.com/repos/${REPO}`, {
    headers: {Accept: 'application/vnd.github+json'},
  });
  if (!res.ok) throw new Error(`GitHub API ${res.status}`);
  const data = await res.json();
  return data.stargazers_count ?? 0;
}

let inflight = false;
async function hydrate() {
  if (typeof window === 'undefined') return;
  if (!document.querySelector(SELECTOR)) return;
  if (inflight) return;

  const cached = readCache();
  if (cached && cached.expiresAt > Date.now()) {
    paint(cached.count);
    return;
  }

  // Render the stale cache immediately so the badge doesn't flicker
  // even when the cache is expired, then refresh in the background.
  if (cached) paint(cached.count);

  inflight = true;
  try {
    const count = await fetchCount();
    writeCache(count);
    paint(count);
  } catch {
    // Network error / rate limit — keep whatever is on screen.
  } finally {
    inflight = false;
  }
}

export function onRouteDidUpdate() {
  hydrate();
}

if (typeof window !== 'undefined') {
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', hydrate, {once: true});
  } else {
    hydrate();
  }
}
